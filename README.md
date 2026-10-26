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
- [x] **Milestone 12 — Download integrity and SHA-256 verification:** merged to `main` via [PR #12](https://github.com/JasonScottCManalo12/Download-Beast/pull/12); [issue #11](https://github.com/JasonScottCManalo12/Download-Beast/issues/11)
- [ ] **Milestone 13 — Safe segmented downloads:** implementation, automated tests, Windows release build, and user-reported Windows smoke tests are complete on the feature branch. Awaiting PR review and successful PR-triggered CI before merge; [issue #13](https://github.com/JasonScottCManalo12/Download-Beast/issues/13), [PR #14](https://github.com/JasonScottCManalo12/Download-Beast/pull/14).
  - [x] Plan contiguous byte ranges and parse `Content-Range` and strong ETags
  - [x] Probe server range support and require a valid one-byte `206` response before segmented transfer
  - [x] Download with at most three workers, pin segments to the same strong ETag, validate every response/body length, and assemble in byte order
  - [x] Preserve destination data on segment failures and clean temporary segment files
  - [x] Keep single-connection fallback for unsupported/invalid range servers and existing partial/resumable downloads
  - [x] Run the existing SHA-256 integrity verification after assembly
  - [x] Add end-to-end coverage for an 8 MiB+ range-capable download and tests for malformed ranges, ignored ranges, truncated segments, changed ETags, pause/resume, and destination preservation
  - [x] Add segmented cancellation cleanup and interruption/restart history-recovery tests; both passed in [Workflow #182](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40293360284)
  - [x] Pass source analysis, automated tests, Windows release build, and artifact upload in [Workflow #182](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40293360284)
  - [x] Update workflow checkout steps to `actions/checkout@v5`
  - [x] User reports all 29 Windows smoke-test checklist items passed (manual result is user-reported)

Milestone 12 was merged in commit [`0ce549a`](https://github.com/JasonScottCManalo12/Download-Beast/commit/0ce549a556c9353b79578a6b6863e765cf0a9266). Branch CI, Windows package validation, and post-merge CI all passed. [Post-merge Workflow #134](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40259720559) completed successfully on `main`.

## Not implemented yet

- Milestone 13 segmented downloads are not yet merged into `main`; implementation is under review in [PR #14](https://github.com/JasonScottCManalo12/Download-Beast/pull/14)
- Automatic retry scheduling (not implemented; Milestone 10 uses explicit user-triggered attempts)
- Bandwidth limits
- Browser extension integration
- Signed installer

SHA-256 verification compares a downloaded file with a user-supplied expected hash; it cannot establish authenticity unless that expected hash comes from a trusted source. This is an initial development build, not yet a production replacement for Internet Download Manager. Test downloads with files you are authorized to retrieve. Servers may block downloads, require authentication, or omit progress metadata.

## Windows build package

The latest successful feature-branch package is available from [Workflow #182](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/40293360284). Artifact name: `Download-Beast-Windows`; size: 13,035,700 bytes; SHA-256: `0245c27cc246297aed34f9cbcef931035e5aa84cc1caec5658a78494b77ab05f`. It expires on 2026-11-09 at 08:40:30 UTC. The user reports all 29 Windows smoke-test checklist items passed.

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

## Branch review

`feature/fix-cancellation-test` is a stale branch 44 commits behind `main` with two unique commits that only adjust the historical cancellation test's timing/chunk handling. It was reviewed and intentionally left untouched; do not merge it wholesale. The current `main` is the baseline for new work. Other milestone feature branches correspond to already-merged milestones and are retained for now; no branches were deleted.
