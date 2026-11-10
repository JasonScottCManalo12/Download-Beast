# Windows Release Candidate Acceptance Record

**Project:** Download Beast  
**Acceptance scope:** Windows portable release candidate  
**Recorded:** 2026-11-11  
**Branch:** `experiment/whole-project-rebuild`  
**Validated commit:** `b8c1f936d7f0fab10e4ad70a3960af9646d25cbd`

## Acceptance evidence

| Check | Result | Evidence |
|---|---|---|
| CI analysis | PASS | Workflow #188, `Analyze and test` job completed successfully |
| Automated tests | PASS | Workflow #188, `Run tests` step completed successfully |
| Windows release build | PASS | Workflow #188, `Build and validate portable Windows ZIP` job completed successfully |
| Portable package assembly | PASS | Workflow #188 created the ZIP, manifest, and notices |
| Package/checksum verification | PASS | Workflow #188 independent verification step completed successfully |
| Artifact upload | PASS | Artifact `Download-Beast-Windows` uploaded successfully |
| Artifact provenance | PASS | Workflow run #188 references the validated commit above |
| Local checksum verification | PASS (user-confirmed) | User confirmed all smoke-test preparation and verification checks |
| Extraction and runtime smoke test | PASS (user-confirmed) | User confirmed all checks, including launch, dashboard, queue/history, settings, clean close, and relaunch |

## CI and artifact references

- Workflow run: [#188 — Download Beast CI](https://github.com/JasonScottCManalo12/Download-Beast/actions/runs/42867755621)
- Artifact: `Download-Beast-Windows`
- Artifact ID: `13787374695`
- Artifact size: 13,358,466 bytes
- Artifact container SHA-256: `7d73a3bb09d3bf7f9a1ed4284ae420a0413cdfbd5d0bab356399ce60fc8e3b69`
- Artifact created: 2026-11-10T17:48:44Z
- Artifact expiry: 2026-11-24T17:48:43Z

The artifact container digest above identifies the uploaded GitHub Actions artifact. It is not the SHA-256 of the portable ZIP contained inside it.

## Acceptance decision

**Accepted for the tested Windows portable release-candidate scope.**

This acceptance records successful CI/package validation and the user's confirmation of the local Windows smoke test. It does not claim broader compatibility testing on other Windows versions or hardware, security certification, code signing, installer validation, or production release approval.

## Deferred / not implied by this acceptance

- Linux, macOS, Android, and browser builds
- Signed installer and automatic updater
- Automatic retry scheduling (previously deferred)
- Merge to `main` or public production release

## Repository boundary

This record is documentation-only and belongs to `experiment/whole-project-rebuild`. No merge to `main` is authorized or implied.
