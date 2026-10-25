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
- [x] **Continuous integration:** GitHub Actions analysis, tests, and Windows release build/package upload pass on `main`
- [x] **Windows release build:** release compilation and artifact upload succeeded
- [x] **Windows executable packaging in CI:** workflow renames the executable to `Download Beast.exe` and uploads the release folder
- [x] **Manual Windows verification:** user confirmed the app launches, dashboard displays correctly, and download/cancellation tests are good
- [x] **Merge verified changes into `main`:** merged via [PR #2](https://github.com/JasonScottCManalo12/Download-Beast/pull/2); merge commit `fcfaff0fd3f7bdb7f3220af36f44bfa0ea13a58a`
- [x] **Persistent download history (Milestone 8, operational):** SQLite-backed records for URLs, destinations, statuses, progress, errors, and timestamps; restore recent history on startup and mark stale active records interrupted
- [x] **Milestone 8 usability fixes:** readable source links with copy/open actions, full destination paths, and recognizable file-type labels; unknown extensions remain explicitly unknown
- [x] **YouTube video identification:** recognize common YouTube video URLs, display the video ID, and resolve the public video title when available; video extraction is not supported yet, so YouTube pages must not be saved as if they were media files
- [x] **Milestone 9 — Pause/resume downloads:** safely validates HTTP Range/Content-Range and ETag behavior, preserves pause/resume state in SQLite history, and passes automated tests; [issue #5 closed](https://github.com/JasonScottCManalo12/Download-Beast/issues/5), [PR #6 merged](https://github.com/JasonScottCManalo12/Download-Beast/pull/6)
- [x] **Milestone 10 — Reliable retry and recovery:** explicit user-triggered retry, failed-history retry, safe restart from byte zero, and tests for transient 503, 404, and repeated failures; [issue #7](https://github.com/JasonScottCManalo12/Download-Beast/issues/7), [PR #8](https://github.com/JasonScottCManalo12/Download-Beast/pull/8)
- [x] **Milestone 11 — Windows release polish and usability:** merged and verified on `main`; [issue #9](https://github.com/JasonScottCManalo12/Download-Beast/issues/9), [PR #10](https://github.com/JasonScottCManalo12/Download-Beast/pull/10)
- [ ] **Milestone 12 — Download integrity and SHA-256 verification:** implementation and tests in progress on `feature/milestone-12-integrity-verification`; [issue #11](https://github.com/JasonScottCManalo12/Download-Beast/issues/11)
  - [x] Add SHA-256 verification utility and tests for matching, mismatch, malformed, and missing expected hashes
  - [x] Verify downloaded byte count against advertised content length and reject incomplete responses
  - [x] Add optional expected SHA-256 input with format validation and trusted-source guidance
  - [x] Persist expected/actual hash, status, and verification timestamp in SQLite schema version 3 migration
  - [x] Display integrity status and hash details in active download cards and history
  - [x] Add tests for verification outcomes, incomplete responses, and integrity metadata persistence
  - [ ] Verify analysis and tests in CI
  - [ ] Inspect Windows package and complete user-confirmed smoke tests
  - [ ] Verify post-merge CI

Latest verified CI on `main`: [Workflow #92](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40141268451), passed Flutter analysis, automated tests, Windows release build, and package upload after the Milestone 10 roadmap update. Milestone 11 work is currently on a feature branch and has not been merged.

## Not implemented yet

- Segmented or multi-connection downloads
- Automatic retry scheduling (not implemented; Milestone 10 uses explicit user-triggered attempts)
- Bandwidth limits
- Checksum verification
- Browser extension integration
- Signed installer

This is an initial development build, not yet a production replacement for Internet Download Manager. Test downloads with files you are authorized to retrieve. Servers may block downloads, require authentication, or omit progress metadata.

## Windows build package

Download the `Download-Beast-Windows` artifact from a successful GitHub Actions run. Extract the package, then launch `Download Beast.exe` from the extracted folder. Keep the executable beside its supporting DLLs and `data` directory; do not move the executable out on its own.

Manual Windows verification is user-confirmed complete for Milestones 9 and 10. For Milestone 10, all smoke-test checks were reported passed, including retry success, retry after app restart, non-retryable error messaging, file integrity, and pause/resume/cancellation checks.

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
