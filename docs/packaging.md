---
summary: "Packaging and signing notes."
read_when:
  - Packaging/signing builds
  - Updating bundle layout
---

# Packaging & signing

## Scripts
- `Scripts/package_app.sh`: builds host arch with ad-hoc signing by default; set `ARCHES="arm64 x86_64"` for universal. Verifies slices. Stable-certificate packaging requires explicit `CODEXBAR_SIGNING=identity` plus `APP_IDENTITY`. Identity signing requires Apple's trusted timestamp by default; personal Apple Development builds can explicitly set `CODEXBAR_CODESIGN_TIMESTAMP=none` when a trusted timestamp is unavailable. Keep the default for Developer ID distribution builds.
- `Scripts/compile_and_run.sh`: uses host arch; pass `--release-universal` or `--release-arches="arm64 x86_64"` for release packaging.

## Bundle contents
- `CodexBarWidget.appex` is built by `WidgetExtension/CodexBarWidgetExtension.xcodeproj` as a real macOS app extension, then bundled with app-group entitlements.
- SwiftPM resource bundles (e.g. `KeyboardShortcuts_KeyboardShortcuts.bundle`) copied into `Contents/Resources` (required for `KeyboardShortcuts.Recorder`).

## Releases
- Full checklist in `docs/RELEASING.md`.
