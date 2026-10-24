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

## Milestone checklist

- [x] **Core download engine:** HTTP/HTTPS downloads, URL validation, save-location selection, progress, cancellation, and status handling
- [x] **Automated tests:** successful download and content verification, HTTP 404 handling, cancellation cleanup, and widget validation
- [x] **Continuous integration:** GitHub Actions analysis and tests pass on the verified cancellation-fix branch
- [x] **Windows release build:** release compilation and artifact upload succeeded
- [x] **Windows executable packaging in CI:** workflow renames the executable to `Download Beast.exe` and uploads the release folder
- [x] **Manual Windows verification:** user confirmed the app launches, dashboard displays correctly, and download/cancellation tests are good
- [x] **Merge verified changes into `main`:** merged via [PR #2](https://github.com/JasonScottCManalo12/Download-Beast/pull/2); merge commit `fcfaff0fd3f7bdb7f3220af36f44bfa0ea13a58a`
- [x] **Persistent download history (Milestone 8, operational):** SQLite-backed records for URLs, destinations, statuses, progress, errors, and timestamps; restore recent history on startup and mark stale active records interrupted
- [x] **Milestone 8 usability fixes:** readable source links with copy/open actions, full destination paths, and recognizable file-type labels; unknown extensions remain explicitly unknown
- [x] **YouTube video identification:** recognize common YouTube video URLs, display the video ID, and resolve the public video title when available; video extraction is not supported yet, so YouTube pages must not be saved as if they were media files
- [ ] **Pause/resume:** use HTTP Range support when the server allows it
- [ ] **Advanced downloads:** bounded segmented downloading, retry scheduling, bandwidth limits, and checksum verification
- [ ] **Release polish:** installer/signing, accessibility, and additional platform support

Latest CI run before this documentation update: [Run #22](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40116942870), passed analysis/tests and Windows release build. The merged commit triggers a fresh workflow on `main`. The user confirmed manual Windows launch/dashboard and download/cancellation tests are good.

## Not implemented yet

- Milestone 8 is operational on branch `feature/sqlite-download-history`. Regression tests cover database reopen persistence, status/progress updates, interrupted-download recovery, recent ordering, file-type labels, readable source links, and YouTube video URL identification. The user confirmed operational status; actual YouTube media extraction remains out of scope.
- YouTube title resolution is implemented as best-effort public oEmbed metadata lookup, with the video ID retained as the fallback when metadata is unavailable
- Pause and resume
- Segmented or multi-connection downloads
- Retry scheduling and bandwidth limits
- Checksum verification
- Browser extension integration
- Signed installer

This is an initial development build, not yet a production replacement for Internet Download Manager. Test downloads with files you are authorized to retrieve. Servers may block downloads, require authentication, or omit progress metadata.

## Windows build package

Download the `Download-Beast-Windows` artifact from a successful GitHub Actions run. Extract the package, then launch `Download Beast.exe` from the extracted folder. Keep the executable beside its supporting DLLs and `data` directory; do not move the executable out on its own.

Manual Windows verification is complete for the current build: the user confirmed the app opens and the download and cancellation tests are good.

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
