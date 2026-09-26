# Repository Guidelines

## Project Structure & Module Organization

Rillight is a Flutter Emby client for Windows, macOS, Linux, Android phones and Android TV, with a Simplified Chinese interface.

- `lib/main.dart` is the entry point; `lib/app/` contains app setup, routing, theme, shared widgets, and localization.
- Feature modules live in `lib/auth/`, `lib/home/`, `lib/library/`, `lib/search/`, and `lib/player/`. Emby API integration lives in `lib/emby/`; image rendering lives in `lib/media_image/`.
- `test/` contains unit and widget tests grouped by feature; catalog tests live in `test/catalog/`.
- `windows/`, `macos/`, and `linux/` contain native runners and platform resources, including app icons. No shared asset directory is declared in `pubspec.yaml`.

## Build, Test, and Development Commands

Use Flutter 3.47.4 with desktop support enabled (Dart constraint `^3.11.5`).

- `flutter pub get` — install dependencies.
- `flutter run -d macos` — launch the native macOS desktop window locally (macOS 12+).
- `flutter run -d windows` — launch locally; use `linux` on the corresponding host.
- `flutter build windows` — create a release build after supplying the verified Windows FFmpeg SDK; substitute the host desktop target as appropriate.
- `flutter build apk --debug` — build the ordinary Android phone/TV APK (API 24+) after supplying the three-ABI Android SDK through `RILLIGHT_CORE_SDK_ROOT`.
- `python tool/android_release_checks.py --all-targets` — isolated 360dp/412dp/TV device checks; see `integration_test/android/README.md` for prerequisites and evidence boundaries.
- `flutter analyze` — run static analysis and configured lints.
- `dart format lib test` — format Dart source and tests.
- `flutter test` — run the full `test/` suite.
- `flutter test --tags integration` — run widget tests that pump `RillightApp` or a full feature page (still included in `flutter test`).
- `flutter gen-l10n` — regenerate localization after editing `lib/app/l10n/app_zh.arb`.

Playback uses the owned `packages/rillight_player` FFmpeg core on desktop and Android. Release packages must verify pinned native source, SDK hashes, actual loaded libraries and dependency closure; no libmpv or Media3 runtime fallback is allowed. Linux packages require a clean ELF/RUNPATH check and Ubuntu 24.04 install/desktop-launch regression (`tool/linux_release_checks.py`). Windows playback validation uses `tool/player_smoke.ps1` with isolated synthetic credentials/settings/cache. macOS requires 12+ and a verified universal SDK/core artifact; record target-machine work in `packages/rillight_player/macos/TESTING_HANDOFF.md` without claiming playback passed until GUI frames, physical audio and actual decoder evidence exist. See the package README for build inputs and licensing.

Linux actual-window validation uses `linux/packaging/playback_smoke.sh`: H.264/HEVC/AV1/VP9 must produce changing colored frames, in addition to passing control checks. Docker/Xvfb with software Mesa and a virtual audio sink does not establish hardware performance or physical audio output.

Android uses the same owned core in-process. Phone/TV pages share controllers but have separate interaction trees. Keep the native view mounted while loading; recheck playback exit followed by gesture navigation and screen lock/wake when changing surface behavior. Device validation uses the disposable `.validation` package and synthetic credentials. Generated tracked files must be marked in `.gitattributes`; generated validation media/protobuf clients stay under ignored `build/`. Keep `android/.cxx/` ignored.

## Coding Style & Naming Conventions

Follow `flutter_lints` from `analysis_options.yaml` and Dart formatter output, using two-space indentation. Use `snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members; prefix private identifiers with `_`. Keep UI, controllers, and API/storage responsibilities in their existing modules. Edit ARB localization sources rather than generated localization Dart files.

## Testing Guidelines

Tests use `flutter_test`. Existing feature cases live in `*_cases.dart`, loaded by generated `test/suites/*_test.dart` entrypoints to reduce compilation and process startup. Run one module with `flutter test test/player/playback_resolver_cases.dart`, then the full suite. New ordinary `*_test.dart` files are still discovered automatically. After adding or renaming a `*_cases.dart` module, run `python tool/test_execution/generate_suites.py`; collection fails on an unregistered module, and CI checks generated entrypoints. Keep pure HTTP tests separate from suites registering `testWidgets`, which installs Flutter's HTTP mock.

Add regression coverage for changed behavior, especially authentication, catalog loading, and playback resolution. Put `tags: ['integration']` on each widget test that pumps `RillightApp` or a full feature page; imported libraries do not propagate library-level tags. Pure controller tests and small standalone widgets stay in the full suite without that tag. `flutter test --tags integration` runs the full-page subset, also included in default `flutter test`. CI requires the tests to pass; no numeric coverage threshold is configured. See `tool/test_execution/classification.md` for the original case-to-tag mapping.

Report native build, package launch, actual video/audio output and GPU stability evidence separately. A core first-frame event does not capture Flutter's displayed texture or prove absence of flicker; a virtual audio sink does not prove physical sound. Distinguish Docker/Xvfb and Android Studio emulator checks from hardware validation, and configured CI from executed results. Current evidence schema is in `tool/player_release_evidence.md`; historical baselines remain in `integration_test/README.md`.

## Release Procedure

PR/main CI runs formatting, analysis, tests, Android APK audit and Linux package regression. macOS package checks run when the pinned universal SDK/core inputs are configured; otherwise CI records an explicit unverified handoff. The tag release workflow requires all native SDK inputs and must fail closed if one is missing. Do not tag a candidate on the strength of CI configuration alone.

Before tagging a release:

1. Update the synchronized application version in `pubspec.yaml`, `lib/app/product.dart`, and `windows/installer/rillight.iss`.
2. Run `flutter pub get`, `dart format lib test`, `flutter analyze`, and `flutter test`.
3. Verify package hashes, installed output and hardware evidence with `python tool/player_core_release_checks.py --all-platforms --require-hardware`, and compare measured baseline/candidate runs with `python tool/player_performance_checks.py --compare-baseline --require-all-targets`. The macOS handoff exception is for local workflow closure, not a five-platform release claim.
4. Commit the release change, push `main`, then create and push an annotated tag:

   ```sh
   git add pubspec.yaml lib/app/product.dart windows/installer/rillight.iss
   git commit -m "chore: release v${VERSION}"
   git push origin main
   git tag -a "v${VERSION}" -m "Release v${VERSION}"
   git push origin "v${VERSION}"
   ```

The tag workflow builds and packages Windows, macOS, and Linux, creates `SHA256SUMS`, verifies all assets, and publishes the GitHub Release.


## Commit & Pull Request Guidelines

History commonly uses `feat:`, `fix:`, and `docs:` prefixes, with English or Chinese summaries. Follow that descriptive pattern. PRs should explain the change, link relevant issues, list validation commands and results, and include screenshots for visible UI changes. Identify affected desktop platforms and any manual playback checks.
