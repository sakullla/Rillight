# Official updates

`UpdateService` queries the official repository's latest stable Release using
its own client without media-server credentials. `UpdateController` owns the
candidate and cancellable download session; `UpdateDownloader` checks the same
Release's SHA256SUMS and rechecks the file before handoff. Downloads live in
`getTemporaryDirectory()/rillight-updates/session-*`; incomplete files never
become installable. `SystemUpdatePlatform` consumes these contracts. App startup,
playback avoidance and the shared settings UI are integrated separately.

Only user gestures may download, open a Release or start installation. The
platform adapter accepts the exact official candidate page, reports browser
failure for retry, and has no clipboard fallback. A `handedOff` result means the
system flow was started/returned, **never that the new version was installed**.
These APIs do not close the application, alter its identity, or delete settings.

## Platform behavior

- Windows: process ABI selects the x64 setup. ShellExecuteEx opens the verified
  executable without installer arguments. UAC remains controlled by the setup
  manifest; cancellation and access denial remain errors/cancellation. The call
  runs off the UI thread. The UI must explain any user-initiated app exit before
  installation and use the existing close guard.
- macOS: process ABI also describes an app running under Rosetta. The matching
  signed DMG is exported via NSSavePanel to a user-authorized location under the
  existing sandbox entitlement. Native code checks both source and exported
  contents, then NSWorkspace opens the image. Cancel leaves the downloaded file
  ready to retry. The UI should instruct the user to drag the app to Applications
  and confirm replacement; open failure retains the chosen local file path.
- Linux: `/usr/bin/dpkg --print-architecture` must succeed and match the process
  ABI before DEB is offered. `/usr/bin/xdg-open` receives a single absolute path
  argument, with no shell or privilege elevation. Failure retains that local
  path for instructions to open it using the distribution's package installer.
- Android phone/TV: system ABIs are intersected with the running process ABI.
  `UpdateInstaller` verifies SHA256, package name, increasing versionCode,
  minSdk and signing identity (including forward signing lineage on API 28+).
  FileProvider exposes only the update cache, uses `${applicationId}.updates`,
  and grants temporary content-URI read access to the system installer. API
  26+ returns `permissionRequired` before opening an installer if the source
  is not allowed. A separate user action opens the app-specific source settings;
  returning from settings does **not** auto-install. A new install action queries
  permission again, so denial stays observable. API 24/25 uses the system flow
  directly. The Activity result distinguishes cancellation and failure; replacement
  may terminate the old process, so the callback is not proof of installation.

Native Android wiring adds only update lifecycle/callback forwarding; existing
TextureView, PiP, playback and configuration callbacks are unchanged. A production
APK is incompatible with the disposable `.validation` application by design.

## Development checks and device handoff

Run `flutter test test/app/update_platform_test.dart` for OS-call fakes, exact
arguments, ABI/DEB capability failures, permission retry, browser failure,
cancellation, wrong-platform packages and tampered files. These tests neither
launch installers nor establish native installation evidence. Run controller and
download tests separately for session and integrity races.

On an Android build host, `android/gradlew :app:compileDebugKotlin
:app:processDebugMainManifest` checks Kotlin and manifest wiring without asserting
an installable APK. A full APK build additionally requires a verified core SDK
for every selected ABI. Validate a candidate with two disposable same-ID,
same-signature old/new builds (increasing versionCode); seed only synthetic
settings/accounts. Keep the real personal app untouched.

Target-device checks still required:

1. On Android phone and TV, test API 24/25 system install and API 26+ source
   permission deny/grant/return/retry. Test cancellation, no installer, tampered
   package, wrong ID/signature and non-increasing versionCode. Inspect merged
   manifest/provider authority for `.validation`; verify another cache directory
   cannot receive a provider URI. Test exit from playback followed by gesture
   navigation, lock/wake and PiP; retain separate actual-frame/audio evidence.
2. On Windows, use an isolated VM/test profile and signed old/new setups. Test
   UAC rejection, installer cancellation and normal interactive replacement.
3. On a macOS 12+ target, use the sandboxed app and matching signed DMG; test
   Save cancellation, authorized export/replacement, mounting, Gatekeeper and
   manual app replacement. Check both native arm64 and supported x64/Rosetta.
4. On Ubuntu 24.04, test DEB handling with and without a desktop package handler;
   also confirm a system without dpkg gets no in-app DEB download.
5. After each actual same-identity upgrade, relaunch and inspect target version,
   synthetic servers/accounts/settings/history. Browser opening on TV also needs
   its own installed-browser/no-browser check.

Current implementation work is on Windows. macOS compilation/sandbox execution,
Linux desktop package handling, all device installation/cancellation flows and
post-upgrade data retention remain unverified. The available Android TV is
offline. The existing `build/local-current-android-sdk/arm64-v8a` failed current
SDK verification (patch provenance, zlib, Unicode line breaking), and
`build/android-core-sdk/arm64-v8a` also has FFmpeg version/source/tag mismatches;
neither is accepted as a current APK-build input. Do not interpret Flutter fakes,
Kotlin compilation or configured CI as five-platform installation acceptance.

Development results (2026-10-17): the platform test's 10 cases passed; the combined
controller/download/platform run passed 46 cases. Targeted Dart analysis and
formatting passed. Gradle `:app:compileDebugKotlin :app:processDebugMainManifest`
passed for the normal debug configuration and with `-PrillightValidation=true`;
the latter's generated `processDebugMainManifest/AndroidManifest.xml` declares
`com.rillight.rillight.validation.updates`, `exported=false` and temporary URI
grants. No real installer was launched during these checks.
