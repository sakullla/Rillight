# macOS Release sandbox proxy regression

Run on a macOS host with the pinned Flutter SDK and native dependencies:

```sh
flutter pub get
flutter build macos --release --target integration_test/macos_proxy_smoke.dart
python3 macos/proxy_smoke.py build/macos/Build/Products/Release/rillight.app \
  build/macos-proxy-sandbox-evidence
flutter build macos --release --target lib/main.dart
python3 macos/sign_bundle.py build/macos/Build/Products/Release/rillight.app
python3 macos/verify_bundle.py --signed build/macos/Build/Products/Release/rillight.app
```

Use a fresh evidence directory. The test launches the signed Flutter Release
executable and sends an HTTP request through the actual `PlaybackHttpProxy` to
a loopback fixture. It then copies the app and removes only `network.server`
from its signature; the same production listener must fail with an OS permission
error. Sandbox and client rights remain present in that negative control.
Timeouts, crashes, missing result markers and unrelated errors fail the check.
The negative app is temporary and never becomes a release artifact.

`sign_bundle.py` signs nested native code without application entitlements,
signs the outer app explicitly with the Release plist, verifies the signature,
then reads and compares the actual signed entitlement plist. The ordinary
`lib/main.dart` app is rebuilt and signed again before CI creates the DMG.

Flutter documents that listeners need `network.server` in the Release
entitlements as well as Debug/Profile:
https://docs.flutter.dev/platform-integration/macos/building#entitlements-and-the-app-sandbox

The Python signing-command/entitlement regressions and Dart static analysis
were run on the development Windows host. The signed macOS sandbox test and
new CI steps have not been executed there; no native macOS pass is claimed.
