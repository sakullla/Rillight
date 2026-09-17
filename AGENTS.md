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
- `flutter test` — run the full `test/` suite (local Windows wall-clock target ≤15s).
- `flutter test --tags integration` — run widget tests that pump `RillightApp` or a full feature page (local Windows wall-clock target ≤10s; still included in `flutter test`).
- `flutter gen-l10n` — regenerate localization after editing `lib/app/l10n/app_zh.arb`.

Playback uses the owned `packages/rillight_player` libmpv adapter and independent player processes on all desktop platforms. Release packages bundle pinned native media libraries. Linux packages require a clean ELF/RUNPATH check and Ubuntu 24.04 install/desktop-launch regression (`tool/linux_release_checks.py`); do not create ABI-spoofing libmpv symlinks. Windows native playback validation uses `tool/player_smoke.ps1` with isolated synthetic credentials/settings/cache. macOS requires 12+ with the pinned Flutter SDK. See the package README for source builds, library hashes and licensing.

Linux actual-window validation uses `linux/packaging/playback_smoke.sh`: H.264/HEVC/AV1/VP9 must produce changing colored frames, in addition to passing control checks. The recorded Docker run uses Xvfb/software Mesa and a virtual audio sink; its substantial 1080p/4K drops do not establish hardware performance or physical audio output.

## Coding Style & Naming Conventions

Follow `flutter_lints` from `analysis_options.yaml` and Dart formatter output, using two-space indentation. Use `snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members; prefix private identifiers with `_`. Keep UI, controllers, and API/storage responsibilities in their existing modules. Edit ARB localization sources rather than generated localization Dart files.

## Testing Guidelines

Tests use `flutter_test`, with descriptive `test` and `testWidgets` cases in `*_test.dart` files. Add regression coverage for changed behavior, especially authentication, catalog loading, and playback resolution. Run targeted tests with `flutter test test/player/playback_resolver_test.dart`, then the full suite. Widget tests that pump `RillightApp` or a full feature page are tagged `integration` (`dart_test.yaml`); `flutter test --tags integration` runs that subset, and the default `flutter test` still includes it. Local Windows targets: full suite ≤15s, integration tags ≤10s. CI must stay green on `flutter test` but has no duration SLO. No numeric coverage threshold is configured.

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
