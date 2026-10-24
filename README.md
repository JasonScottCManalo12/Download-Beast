# Download Beast

Download Beast is an early Flutter desktop download-manager project. The first target is Windows; Linux and Android may follow after the core download experience is tested.

## Current implementation

- Flutter and Dart application shell
- URL input with HTTP/HTTPS validation
- Save-location picker
- HTTP/HTTPS file download using Dart's `HttpClient`
- Live byte count and progress indicator when the server provides a content length
- Cancel active downloads
- Per-download completed, failed, and cancelled states
- Automated local-HTTP tests for successful downloads, HTTP 404 handling, and cancellation cleanup
- Widget tests for the dashboard and rejection of non-HTTP URLs
- GitHub Actions workflow for analysis, tests, and Windows release builds
- Windows release package names the main executable `Download Beast.exe` and includes the supporting runtime files

## Not implemented yet

- Persistent download history / SQLite
- Pause and resume
- Segmented or multi-connection downloads
- Retry scheduling and bandwidth limits
- Checksum verification
- Browser extension integration
- Signed installer

This is an initial development build, not yet a production replacement for Internet Download Manager. Test downloads with files you are authorized to retrieve. Servers may block downloads, require authentication, or omit progress metadata.

## Windows build package

Download the `Download-Beast-Windows` artifact from a successful GitHub Actions run. Extract the package, then launch `Download Beast.exe` from the extracted folder. Keep the executable beside its supporting DLLs and `data` directory; do not move the executable out on its own.

The package has not been manually smoke-tested on a separate Windows PC yet.

## Development

Requires Flutter stable with Windows desktop support and Visual Studio's C++ desktop build tools. The Windows runner scaffold is generated in CI; run the first command below once after cloning to generate it locally.

```powershell
flutter create --platforms=windows .
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

The GitHub Actions workflow generates the Windows runner scaffolding during CI, then analyzes, tests, builds the release app, renames the main executable, and uploads the release folder as an artifact.

## Roadmap

1. Add automated download behavior tests and validate the initial Windows flow (CI tests cover local HTTP success, 404 errors, and cancellation).
2. Package the Windows release with the main executable named `Download Beast.exe` (CI packaging change added; awaiting a green run).
3. Manually smoke-test the Windows executable on a real Windows PC.
4. Add persistent history and safe restart recovery.
5. Add robust pause/resume using HTTP range support when available.
6. Add bounded segmented downloading, retries, and checksum validation.
7. Improve packaging, accessibility, and cross-platform support.
