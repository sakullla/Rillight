import 'update_download.dart';
import 'update_service.dart';

enum UpdateOperatingSystem { windows, macos, linux, android, unsupported }

/// Values must come from the running ABI/system, not UI form factor or env vars.
class UpdateCapabilities {
  UpdateCapabilities({
    required this.system,
    required String? architecture,
    List<String> androidAbis = const [],
    this.supportsDeb = false,
  }) : architecture = normalizeUpdateArchitecture(architecture),
       androidAbis = List.unmodifiable(androidAbis);

  final UpdateOperatingSystem system;
  final String? architecture;

  /// System preference order; entries must also be compatible with this app.
  final List<String> androidAbis;
  final bool supportsDeb;
}

String? normalizeUpdateArchitecture(String? value) => switch (value) {
  'x64' || 'x86_64' || 'amd64' => 'x64',
  'arm64' || 'aarch64' || 'arm64-v8a' => 'arm64',
  'arm' || 'armv7' || 'armeabi-v7a' => 'arm',
  _ => null,
};

enum UpdateAssetIssue {
  unsupportedPlatform,
  unknownArchitecture,
  missing,
  ambiguous,
  unsafe,
}

class UpdateAssetSelection {
  const UpdateAssetSelection.available(this.asset) : issue = null;
  const UpdateAssetSelection.unavailable(this.issue) : asset = null;
  final ReleaseAsset? asset;
  final UpdateAssetIssue? issue;
}

/// Select exactly one published artifact. Never substitute a different ABI.
UpdateAssetSelection selectUpdateAsset(
  AppRelease release,
  UpdateCapabilities capabilities,
) {
  if (!release.isOfficial) {
    return const UpdateAssetSelection.unavailable(UpdateAssetIssue.unsafe);
  }
  final arch = capabilities.architecture;
  final tag = release.tag;
  final names = <String>[];
  switch (capabilities.system) {
    case UpdateOperatingSystem.windows:
      if (arch == 'x64') names.add('Rillight-windows-x64-$tag-setup.exe');
    case UpdateOperatingSystem.macos:
      if (arch == 'x64') names.add('Rillight-macos-$tag-x86_64-signed.dmg');
      if (arch == 'arm64') names.add('Rillight-macos-$tag-arm64-signed.dmg');
    case UpdateOperatingSystem.linux:
      if (!capabilities.supportsDeb) {
        return const UpdateAssetSelection.unavailable(
          UpdateAssetIssue.unsupportedPlatform,
        );
      }
      if (arch == 'x64') names.add('Rillight-linux-x64-$tag.deb');
    case UpdateOperatingSystem.android:
      if (arch != null) {
        for (final abi in capabilities.androidAbis) {
          if (normalizeUpdateArchitecture(abi) == arch &&
              const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi)) {
            names.add('Rillight-android-$abi-$tag.apk');
          }
        }
      }
    case UpdateOperatingSystem.unsupported:
      return const UpdateAssetSelection.unavailable(
        UpdateAssetIssue.unsupportedPlatform,
      );
  }
  if (arch == null) {
    return const UpdateAssetSelection.unavailable(
      UpdateAssetIssue.unknownArchitecture,
    );
  }
  final matches = release.assets
      .where((asset) => names.contains(asset.name))
      .toList();
  if (matches.isEmpty) {
    return const UpdateAssetSelection.unavailable(UpdateAssetIssue.missing);
  }
  if (matches.length != 1) {
    return const UpdateAssetSelection.unavailable(UpdateAssetIssue.ambiguous);
  }
  if (!release.ownsAsset(matches.single)) {
    return const UpdateAssetSelection.unavailable(UpdateAssetIssue.unsafe);
  }
  return UpdateAssetSelection.available(matches.single);
}

enum UpdateActionStatus { handedOff, permissionRequired, cancelled, failed }

enum UpdateActionFailure {
  unavailable,
  permissionDenied,
  incompatiblePackage,
  invalidFile,
  systemFailure,
}

/// handedOff means the system flow was started, never that installation finished.
class UpdateActionResult {
  const UpdateActionResult(this.status, {this.failure, this.localPath});
  final UpdateActionStatus status;
  final UpdateActionFailure? failure;

  /// Local package location for platform installation instructions, never a URL.
  final String? localPath;
}

abstract interface class UpdatePlatform {
  Future<UpdateCapabilities> capabilities();
  Future<UpdateActionResult> openRelease(AppRelease release);
  Future<UpdateActionResult> install(VerifiedUpdate update);

  /// Called only after a separate user gesture, not automatically from install.
  Future<UpdateActionResult> requestInstallPermission();
}
