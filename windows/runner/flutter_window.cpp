#include "flutter_window.h"

#include <optional>
#include <string>
#include <windows.h>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  file_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "download_beast/windows",
      &flutter::StandardMethodCodec::GetInstance());
  file_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        auto value = [args](const char* key) -> std::wstring {
          if (!args) return {};
          const auto found = args->find(flutter::EncodableValue(key));
          if (found == args->end()) return {};
          const auto* text = std::get_if<std::string>(&found->second);
          if (!text) return {};
          if (text->empty()) return {};
          const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
              text->data(), static_cast<int>(text->size()), nullptr, 0);
          if (size <= 0) return {};
          std::wstring converted(size, L'\0');
          MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
              static_cast<int>(text->size()), converted.data(), size);
          return converted;
        };
        if (call.method_name() == "fileIdentity") {
          const auto path = value("path");
          const DWORD attributes = GetFileAttributesW(path.c_str());
          if (attributes == INVALID_FILE_ATTRIBUTES) {
            result->Success(flutter::EncodableValue());
            return;
          }
          if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            result->Error("reparse_point", "Destination reparse points are not supported.");
            return;
          }
          HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
              OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
          BY_HANDLE_FILE_INFORMATION info{};
          if (file == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file, &info)) {
            if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
            result->Error("file_identity", "Could not inspect destination identity.");
            return;
          }
          CloseHandle(file);
          const unsigned long long index =
              (static_cast<unsigned long long>(info.nFileIndexHigh) << 32) |
              info.nFileIndexLow;
          const std::string identity = std::to_string(info.dwVolumeSerialNumber) + ":" + std::to_string(index);
          result->Success(flutter::EncodableValue(identity));
          return;
        }
        if (call.method_name() == "replaceFile") {
          const auto source = value("source");
          const auto destination = value("destination");
          const auto backup = value("backup");
          const bool exists = args && args->find(flutter::EncodableValue("exists")) != args->end() &&
              std::get_if<bool>(&args->at(flutter::EncodableValue("exists"))) &&
              *std::get_if<bool>(&args->at(flutter::EncodableValue("exists")));
          if (exists) {
            const DWORD attributes = GetFileAttributesW(destination.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES ||
                (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
              result->Error("destination_changed", "Destination is missing or is a reparse point.");
              return;
            }
            HANDLE current = CreateFileW(destination.c_str(), FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
            BY_HANDLE_FILE_INFORMATION info{};
            if (current == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(current, &info)) {
              if (current != INVALID_HANDLE_VALUE) CloseHandle(current);
              result->Error("destination_changed", "Could not re-check destination identity.");
              return;
            }
            CloseHandle(current);
            const unsigned long long index =
                (static_cast<unsigned long long>(info.nFileIndexHigh) << 32) |
                info.nFileIndexLow;
            const std::wstring identity = std::to_wstring(info.dwVolumeSerialNumber) + L":" + std::to_wstring(index);
            if (identity != value("expectedIdentity")) {
              result->Error("destination_changed", "Destination identity changed before replacement.");
              return;
            }
          }
          const BOOL ok = exists
              ? ReplaceFileW(destination.c_str(), source.c_str(), backup.c_str(), REPLACEFILE_WRITE_THROUGH, nullptr, nullptr)
              : MoveFileExW(source.c_str(), destination.c_str(), MOVEFILE_WRITE_THROUGH);
          if (!ok) {
            result->Error(std::to_string(GetLastError()), "Windows could not safely replace the destination.");
            return;
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "revealFile" || call.method_name() == "openFile") {
          const auto path = value("path");
          if (call.method_name() == "openFile") {
            const auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
            if (status <= 32) result->Error("open_failed", "Windows could not open the file.");
            else result->Success(flutter::EncodableValue(true));
          } else {
            std::wstring parameters = L"/select,\"" + path + L"\"";
            const auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", L"explorer.exe", parameters.c_str(), nullptr, SW_SHOWNORMAL));
            if (status <= 32) result->Error("reveal_failed", "Windows could not reveal the file.");
            else result->Success(flutter::EncodableValue(true));
          }
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_GETMINMAXINFO) {
    auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
    const UINT dpi = GetDpiForWindow(hwnd);
    RECT minimum{0, 0,
        static_cast<LONG>(900.0 * dpi / 96.0),
        static_cast<LONG>(600.0 * dpi / 96.0)};
    const DWORD style = static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE));
    const DWORD ex_style = static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE));
    AdjustWindowRectExForDpi(&minimum, style, FALSE, ex_style, dpi);
    limits->ptMinTrackSize.x = minimum.right - minimum.left;
    limits->ptMinTrackSize.y = minimum.bottom - minimum.top;
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
