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
- `flutter run -d macos` — launch the native macOS desktop window locally (macOS 12+).
- `flutter run -d windows` — launch locally; use `linux` on the corresponding host.
- `flutter build windows` — create a release build; substitute the host desktop target as appropriate.
- `flutter analyze` — run static analysis and configured lints.
- `dart format lib test` — format Dart source and tests.
- `flutter test` — run the full `test/` suite.
- `flutter test --tags integration` — run widget tests that pump `RillightApp` or a full feature page (still included in `flutter test`).
- `flutter gen-l10n` — regenerate localization after editing `lib/app/l10n/app_zh.arb`.

Playback uses media_kit/libmpv. Linux requires system libmpv or a bundled copy.

## Coding Style & Naming Conventions

Follow `flutter_lints` from `analysis_options.yaml` and Dart formatter output, using two-space indentation. Use `snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members; prefix private identifiers with `_`. Keep UI, controllers, and API/storage responsibilities in their existing modules. Edit ARB localization sources rather than generated localization Dart files.

## Testing Guidelines

Tests use `flutter_test`, with descriptive `test` and `testWidgets` cases in `*_test.dart` files. Add regression coverage for changed behavior, especially authentication, catalog loading, and playback resolution. Run targeted tests with `flutter test test/player/playback_resolver_test.dart`, then the full suite. Widget tests that pump `RillightApp` or a full feature page are tagged `integration` (`dart_test.yaml`); `flutter test --tags integration` runs that subset, and the default `flutter test` still includes it. CI must stay green on `flutter test`. No numeric coverage threshold is configured.

## Release Procedure

CI only runs formatting, analysis, and tests. Desktop release builds are created by `.github/workflows/release.yml` when a semantic-version tag matching `v*` is pushed.

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
