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
- Windows build, static analysis, and test workflow in GitHub Actions

## Not implemented yet

- Persistent download history / SQLite
- Pause and resume
- Segmented or multi-connection downloads
- Retry scheduling and bandwidth limits
- Checksum verification
- Browser extension integration
- Signed installer and release packaging

This is an initial development build, not yet a production replacement for Internet Download Manager. Test downloads with files you are authorized to retrieve. Servers may block downloads, require authentication, or omit progress metadata.

## Development

Requires Flutter stable with Windows desktop support and Visual Studio's C++ desktop build tools. The Windows runner scaffold is generated in CI; run the first command below once after cloning to generate it locally.

```powershell
flutter create --platforms=windows .
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

The GitHub Actions workflow generates the Windows runner scaffolding during CI, then analyzes, tests, and builds the release app.

## Roadmap

1. Add automated download behavior tests and validate the initial Windows flow (in progress; CI tests cover local HTTP success, 404 errors, and cancellation).
2. Manually smoke-test the Windows executable on a real Windows PC.
3. Add persistent history and safe restart recovery.
4. Add robust pause/resume using HTTP range support when available.
5. Add bounded segmented downloading, retries, and checksum validation.
6. Improve packaging, accessibility, and cross-platform support.
