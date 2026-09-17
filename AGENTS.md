# Repository Guidelines

## Project Structure & Module Organization

Rillight is a Flutter desktop Emby client for Windows, macOS, and Linux, with a Simplified Chinese interface.

- `lib/main.dart` is the entry point; `lib/app/` contains app setup, routing, theme, shared widgets, and localization.
- Feature modules live in `lib/auth/`, `lib/home/`, `lib/library/`, `lib/search/`, and `lib/player/`. Emby API integration lives in `lib/emby/`; image rendering lives in `lib/media_image/`.
- `test/` contains unit and widget tests grouped by feature; catalog tests live in `test/catalog/`.
- `windows/`, `macos/`, and `linux/` contain native runners and platform resources, including app icons. No shared asset directory is declared in `pubspec.yaml`.

## Build, Test, and Development Commands

Use Flutter 3.47.4 with desktop support enabled (Dart constraint `^3.11.5`).

- `flutter pub get` — install dependencies.
- `flutter run -d windows` — launch locally; use `macos` or `linux` on the corresponding host.
- `flutter build windows` — create a release build; substitute the host desktop target as appropriate.
- `flutter analyze` — run static analysis and configured lints.
- `dart format lib test` — format Dart source and tests.
- `flutter test` — run the full `test/` suite.
- `flutter test --tags integration` — run widget tests that pump `RillightApp` or a full feature page (still included in `flutter test`).
- `flutter gen-l10n` — regenerate localization after editing `lib/app/l10n/app_zh.arb`.

Playback uses the owned `packages/rillight_player` libmpv adapter and independent player processes on all desktop platforms. Release packages bundle pinned native media libraries. Linux packages require a clean ELF/RUNPATH check and Ubuntu 24.04 install/desktop-launch regression (`tool/linux_release_checks.py`); do not create ABI-spoofing libmpv symlinks. Windows native playback validation uses `tool/player_smoke.ps1` with isolated synthetic credentials/settings/cache. macOS requires 12+ with the pinned Flutter SDK. See the package README for source builds, library hashes and licensing.

Linux actual-window validation uses `linux/packaging/playback_smoke.sh`: H.264/HEVC/AV1/VP9 must produce changing colored frames, in addition to passing control checks. The recorded Docker run uses Xvfb/software Mesa and a virtual audio sink; its substantial 1080p/4K drops do not establish hardware performance or physical audio output.

## Coding Style & Naming Conventions

Follow `flutter_lints` from `analysis_options.yaml` and Dart formatter output, using two-space indentation. Use `snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members; prefix private identifiers with `_`. Keep UI, controllers, and API/storage responsibilities in their existing modules. Edit ARB localization sources rather than generated localization Dart files.

## Testing Guidelines

Tests use `flutter_test`. Existing feature cases live in `*_cases.dart`, loaded by generated `test/suites/*_test.dart` entrypoints to reduce compilation and process startup. Run one module with `flutter test test/player/playback_resolver_cases.dart`, then the full suite. New ordinary `*_test.dart` files are still discovered automatically. After adding or renaming a `*_cases.dart` module, run `python tool/test_execution/generate_suites.py`; collection fails on an unregistered module, and CI checks generated entrypoints. Keep pure HTTP tests separate from suites registering `testWidgets`, which installs Flutter's HTTP mock.

Add regression coverage for changed behavior, especially authentication, catalog loading, and playback resolution. Put `tags: ['integration']` on each widget test that pumps `RillightApp` or a full feature page; imported libraries do not propagate library-level tags. Pure controller tests and small standalone widgets stay in the full suite without that tag. `flutter test --tags integration` runs the full-page subset, also included in default `flutter test`. CI requires the tests to pass; no numeric coverage threshold is configured. See `tool/test_execution/classification.md` for the original case-to-tag mapping.

Report native build, package launch, actual video/audio output and GPU stability evidence separately. The smoke's `*-core.png` files verify libmpv subtitle composition; they do not capture Flutter's displayed texture or prove absence of flicker. Distinguish Docker/Xvfb checks from hardware desktop validation, and configured CI from executed results. Current validation scope is recorded in `integration_test/README.md`.

## Release Procedure

PR/main CI runs formatting, analysis, tests, Linux package regression and macOS build/bundle checks. Desktop releases are packaged and published by `.github/workflows/release.yml` when a semantic-version tag matching `v*` is pushed.

Before tagging a release:

1. Update the synchronized application version in `pubspec.yaml`, `lib/app/product.dart`, and `windows/installer/rillight.iss`.
2. Run `flutter pub get`, `dart format lib test`, `flutter analyze`, and `flutter test`.
3. Commit the release change, push `main`, then create and push an annotated tag:

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
