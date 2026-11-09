# Download Beast

Download Beast is a Windows desktop application for direct HTTP and HTTPS downloads. This branch contains the whole-project rebuild implementation. A passing test suite does not by itself establish release readiness; see the current CI run and Windows smoke-test evidence before distributing a build.

## Supported release

- Windows 10 version 22H2, build 19045 or later; Windows 11 is also intended to be supported.
- Minimum application window: 900 × 600 logical pixels.
- Flutter stable 3.47.5 and Dart 3.13.4. `pubspec.lock` is tracked; use locked dependency resolution.
- First distribution format: portable ZIP. Signed installers and automatic updates are deferred.

## Download behavior

Paste a direct HTTP/HTTPS file URL, optionally enter an expected SHA-256, choose a destination, and start the task. The expected hash is compared with the downloaded bytes; it does not establish authenticity unless its value came from a trusted source. A mismatch is a terminal integrity failure, and the staged file is discarded. An existing destination is preserved unless you explicitly approve replacement.

The queue defaults to three simultaneous downloads and allows a persistent setting from one to five. Eligible files of at least 16 MiB use three parallel ranges only when the server proves byte-range support and supplies a strong ETag. Otherwise the app uses one stream. Pausing or restarting a segmented transfer discards its partial segments and starts again from zero. Retry is always manual. Progress shows received bytes and transfer rate; ETA is not provided.

Timeouts are fixed: 15 seconds to connect, 30 seconds to receive response headers, and 30 seconds without body data. A timed-out attempt fails safely and can be retried manually.

Completed files can be opened or revealed in Explorer. Before opening a file with a potentially executable extension or a valid PE header, the app asks for confirmation. This warning is a precaution, not malware detection or a security scan.

### Status and recovery

The task lifecycle is `queued → downloading`; an active task may become `paused`, `failed`, `cancelled`, `completed`, or `integrityFailed`. Paused tasks return to the queue when resumed. Failed or integrity-failed tasks return to the queue only after the user selects Retry. Completed and cancelled tasks are terminal. On application restart, a task recorded as downloading becomes `interrupted` and offers a fresh attempt. A segmented task paused or interrupted begins again at zero; a single-stream task can resume only when its strong ETag and byte range are still valid.

## History and privacy

History and locally retained source URLs remain until manually deleted; there is no automatic age-based deletion. Removing a history record also removes its associated locally retained URL from application history. Downloaded files remain on disk unless you separately select file deletion. Clear-all follows the same rule.

The app may retain full URLs locally for retry and recovery. Ordinary UI summaries and diagnostics redact URL credentials and sensitive query values. Use the explicit copy action to copy a full source URL. Optional YouTube title lookup requires a confirmation dialog and sends only the canonical URL for the selected video to YouTube's metadata endpoint. Direct YouTube media extraction is unsupported. The application does not claim secure erasure or encryption at rest.

## Portable Windows package

Download the `Download-Beast-Windows` artifact from a successful Windows build workflow. Keep the executable beside its DLLs and `data` directory. Verify the ZIP with its adjacent `.sha256` sidecar before extracting. Extract the ZIP to a writable folder and launch `Download Beast.exe`.

The package contains a build manifest with commit and Flutter/Dart versions, plus third-party license notices. CI artifact upload is not a public release publication. Windows 10/11 interactive smoke checks must be recorded separately; CI build success alone is not a launch or filesystem-safety claim.

## Development

Install Flutter stable 3.47.5, Dart 3.13.4 and Visual Studio 2022 with the Desktop development with C++ workload. Windows builds also require CMake and MSBuild from Visual Studio. From a clean checkout:

```powershell
flutter --version
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

The Windows runner is checked in. If creating a fresh platform scaffold in a separate checkout, use `flutter create --platforms=windows --project-name download_beast .` and review generated files before use. Do not run dependency resolution without the tracked lockfile enforcement for release validation.

## Architecture and testing

- `lib/main.dart`: presentation and composition root.
- `lib/download_job.dart`, `download_scheduler.dart`: task lifecycle and concurrency.
- `lib/segmented_download_*.dart`: range planning, probe and segmented transfer.
- `lib/download_history.dart`: SQLite storage, migration and history queries.
- `lib/download_integrity.dart`, `file_identity.dart`: hashing, URL redaction and executable-file checks.
- `lib/windows_file_ops.dart` and `windows/runner`: Windows filesystem identity, safe replacement, opening and Explorer integration.

Automated tests use local HTTP servers and temporary SQLite/filesystem data for core behavior. Windows-specific picker, Explorer, replacement, restart and portable-package smoke checks must be run on Windows; Linux test success is not a substitute. The app closes active work and waits for queued persistence before closing its database.

## Troubleshooting

- **Connection/header/body timeout:** the attempt is failed with the timeout phase. The partial stage is removed when possible; if cleanup fails, the error includes the path. Retry manually after checking the connection or destination.
- **HTTP or protocol error:** inspect the status and user-safe error text, then retry manually if appropriate. No automatic retry loop runs.
- **Integrity failure:** the staged bytes did not match the supplied SHA-256. They are not installed as the completed destination. Confirm the expected hash from a trusted source before retrying.
- **Destination replacement error or locked file:** the original is preserved. The error reports the staged path and, when present, the backup path. Close other programs holding the file before retrying.
- **Interrupted item:** the application closed while a transfer was active. Start a fresh attempt; segmented bytes are discarded. A paused single-stream item may retain a stage, but resume still requires a matching strong validator and valid server range response.
- **Completed file unavailable:** the destination may have been moved or deleted outside the app. Use Reveal or retry to create a new file.
- **History storage warning:** the current download can continue, but the record may not be saved. Check that the app support folder is writable and relaunch before relying on history recovery.

## Validation and CI

From the repository root, the required local checks are locked dependency resolution, `flutter analyze`, `flutter test`, and `flutter build windows --release`. CI runs analysis and tests on Ubuntu, then builds Windows only if those checks pass. Its packaging step verifies the executable, DLLs, Flutter `data`, third-party notices, manifest commit/toolchain versions, and external ZIP SHA-256 before uploading an artifact. Artifact upload is not a public release. The workflow does not sign packages or publish GitHub releases.

The implementation is maintained as one assignment with internal subsystem checkpoints. For a failing blocker, a repair cycle records diagnostics, identifies one cause, makes a scoped correction, and reruns the affected check plus required regression checks. Stop after three unsuccessful cycles for the same blocker. Do not suppress tests or weaken acceptance criteria to obtain a green result.

## Current verification status

The original 65-test baseline was recorded at the approved starting commit. It documents the old implementation only. The rebuild's analysis, tests, Windows release build, package checksum and interactive Windows 10/11 smoke checks are reported only after those checks have actually run for this branch. Historical milestone statements and user-reported smoke checks from earlier project versions are not evidence for this rebuild.
