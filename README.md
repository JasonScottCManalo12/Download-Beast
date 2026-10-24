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
- Windows build, static analysis, and widget-test workflow in GitHub Actions

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

Requires Flutter stable with Windows desktop support and Visual Studio's C++ desktop build tools.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

The GitHub Actions workflow generates the Windows runner scaffolding during CI, then analyzes, tests, and builds the release app.

## Roadmap

1. Verify the initial Windows build and download flow.
2. Add persistent history and safe restart recovery.
3. Add robust pause/resume using HTTP range support when available.
4. Add bounded segmented downloading, retries, and checksum validation.
5. Improve packaging, accessibility, and cross-platform support.
