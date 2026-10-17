import '../l10n/app_localizations.dart';
import '../product.dart';
import '../ui/ui.dart';
import 'update_controller.dart';
import 'update_download.dart';
import 'update_platform_contract.dart';
import 'update_reminder_host.dart';
import 'update_scope.dart';
import 'update_service.dart';

/// Shared by desktop settings, phone About, TV settings and the startup reminder.
class UpdateCheck extends StatefulWidget {
  const UpdateCheck({
    super.key,
    this.controller,
    this.check,
    this.openRelease,
    this.showCheckButton = true,
    this.expandNotes = false,
  });
  final UpdateController? controller;
  // Preserve the injectable widget API without creating real transports.
  final Future<AppRelease> Function()? check;
  final Future<bool> Function(Uri)? openRelease;
  final bool showCheckButton;
  final bool expandNotes;
  @override
  State<UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<UpdateCheck> {
  UpdateController? _legacy;
  bool _playbackBlocked = false;
  @override
  void initState() {
    super.initState();
    if (widget.check != null) {
      _legacy = UpdateController(
        platform: _CallbackPlatform(widget.openRelease),
        service: _CallbackService(widget.check!),
      );
    }
  }

  @override
  void dispose() {
    _legacy?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        widget.controller ?? _legacy ?? UpdateScope.maybeOf(context);
    if (controller == null) {
      final l = AppLocalizations.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.mobileVersion(kAppVersion)),
          AppButton(
            key: const Key('app-update-check-button'),
            child: Text(l.updateCheck),
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _contents(context, controller),
    );
  }

  Future<void> _install(UpdateController controller) async {
    if (UpdateActivityScope.playbackOccupiedOf(context)) {
      setState(() => _playbackBlocked = true);
      return;
    }
    setState(() => _playbackBlocked = false);
    await controller.install();
  }

  Widget _contents(BuildContext context, UpdateController controller) {
    final l = AppLocalizations.of(context);
    final release = controller.release;
    final newer = release?.isNewerThan(controller.currentVersion) ?? false;
    final checking = controller.checkPhase == UpdateCheckPhase.checking;
    final d = controller.download;
    final hasDownload = d.phase != UpdateDownloadPhase.idle;
    final sameDownload = hasDownload && d.release?.tag == release?.tag;
    final failure =
        controller.checkPhase == UpdateCheckPhase.failed &&
        controller.manualCheck;
    final message = checking && controller.manualCheck
        ? l.updateChecking
        : failure
        ? _checkFailure(l, controller.checkFailure)
        : newer
        ? l.updateAvailable(release!.version.toString())
        : controller.checkPhase == UpdateCheckPhase.current &&
              controller.manualCheck
        ? l.updateCurrent
        : l.mobileVersion(controller.currentVersion);
    final busyAction = controller.installing || controller.requestingPermission;
    return FocusTraversalGroup(
      child: Column(
        key: const Key('app-update-check'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, key: const Key('app-update-status')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.showCheckButton)
                AppButton(
                  key: const Key('app-update-check-button'),
                  onPressed: checking && controller.manualCheck
                      ? null
                      : () => controller.check(),
                  child: Text(l.updateCheck),
                ),
              if (newer && controller.selection?.asset != null && !sameDownload)
                AppButton(
                  key: const Key('app-update-download'),
                  variant: AppButtonVariant.filled,
                  onPressed: d.busy || busyAction
                      ? null
                      : controller.startDownload,
                  child: Text(l.updateDownload),
                ),
              if (newer)
                AppButton(
                  key: const Key('app-update-open'),
                  onPressed: controller.openingRelease
                      ? null
                      : () => controller.openRelease(),
                  child: Text(l.updateOpenRelease),
                ),
            ],
          ),
          if (checking && controller.manualCheck)
            const Padding(
              padding: EdgeInsets.all(8),
              child: CupertinoActivityIndicator(),
            ),
          if (newer && controller.selection?.asset == null) ...[
            const SizedBox(height: 8),
            Text(l.updateNoPackage, key: const Key('app-update-no-package')),
          ],
          if (newer && release!.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            if (widget.expandNotes)
              Text(release.notes)
            else
              AppDisclosure(
                title: Text(l.updateNotes),
                children: [Text(release.notes)],
              ),
          ],
          if (controller.releaseAction?.status ==
              UpdateActionStatus.failed) ...[
            const SizedBox(height: 8),
            Text(l.updateOpenFailed, key: const Key('app-update-open-failed')),
          ],
          if (hasDownload) ...[
            const SizedBox(height: 16),
            Text(
              l.updatePackageVersion(d.release!.version.toString()),
              key: const Key('app-update-package-version'),
            ),
            const SizedBox(height: 8),
            Text(switch (d.phase) {
              UpdateDownloadPhase.downloading =>
                d.fraction == null
                    ? l.updateDownloadingUnknown(_bytes(d.received))
                    : l.updateDownloading(
                        _bytes(d.received),
                        _bytes(d.total!),
                        (d.fraction! * 100).floor(),
                      ),
              UpdateDownloadPhase.verifying => l.updateVerifying,
              UpdateDownloadPhase.ready => l.updateReady,
              UpdateDownloadPhase.cancelled => l.updateCancelled,
              UpdateDownloadPhase.failed => _downloadFailure(l, d),
              UpdateDownloadPhase.idle => '',
            }, key: const Key('app-update-download-status')),
            if (d.busy) ...[
              const SizedBox(height: 8),
              if (d.phase == UpdateDownloadPhase.downloading &&
                  d.fraction != null)
                AppProgressBar(value: d.fraction!)
              else
                const Align(
                  alignment: Alignment.centerLeft,
                  child: CupertinoActivityIndicator(),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (d.busy)
                  AppButton(
                    key: const Key('app-update-cancel'),
                    onPressed: controller.cancelDownload,
                    child: Text(l.updateCancelDownload),
                  ),
                if (d.phase == UpdateDownloadPhase.failed ||
                    d.phase == UpdateDownloadPhase.cancelled)
                  AppButton(
                    key: const Key('app-update-retry'),
                    onPressed: busyAction ? null : controller.retryDownload,
                    child: Text(l.retry),
                  ),
                if (d.phase == UpdateDownloadPhase.ready)
                  AppButton(
                    key: const Key('app-update-install'),
                    variant: AppButtonVariant.filled,
                    onPressed: busyAction ? null : () => _install(controller),
                    child: Text(
                      controller.installing
                          ? l.updateInstalling
                          : l.updateInstall,
                    ),
                  ),
                if (d.release?.tag != release?.tag)
                  AppButton(
                    key: const Key('app-update-download-release'),
                    onPressed: controller.openingRelease
                        ? null
                        : () => controller.openRelease(candidate: d.release),
                    child: Text(l.updateOpenRelease),
                  ),
              ],
            ),
            if (d.phase == UpdateDownloadPhase.ready) ...[
              const SizedBox(height: 8),
              Text(
                _installGuide(l, controller.capabilities?.system),
                key: const Key('app-update-install-guide'),
              ),
            ],
            if (_playbackBlocked)
              Text(
                l.updateFinishPlayback,
                key: const Key('app-update-playback-blocked'),
              ),
            if (controller.installAction != null) ...[
              const SizedBox(height: 8),
              Text(
                _actionMessage(l, controller.installAction!),
                key: const Key('app-update-install-result'),
              ),
              if (controller.installAction!.localPath case final path?)
                Text(l.updateLocalPackage(path)),
              if (controller.installAction!.status ==
                  UpdateActionStatus.permissionRequired)
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppButton(
                    key: const Key('app-update-permission'),
                    onPressed: busyAction
                        ? null
                        : controller.requestInstallPermission,
                    child: Text(l.updateAllowSource),
                  ),
                ),
            ],
            if (controller.permissionAction != null)
              Text(
                controller.permissionAction!.status ==
                        UpdateActionStatus.handedOff
                    ? l.updatePermissionOpened
                    : _actionMessage(l, controller.permissionAction!),
                key: const Key('app-update-permission-result'),
              ),
          ],
        ],
      ),
    );
  }

  static String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  static String _checkFailure(
    AppLocalizations l,
    UpdateCheckFailure? failure,
  ) => switch (failure) {
    UpdateCheckFailure.timeout => l.updateTimeout,
    UpdateCheckFailure.rateLimited => l.updateRateLimited,
    UpdateCheckFailure.noRelease => l.updateNoRelease,
    UpdateCheckFailure.invalidResponse => l.updateInvalidResponse,
    _ => l.updateCheckFailed,
  };
  static String _downloadFailure(
    AppLocalizations l,
    UpdateDownloadState download,
  ) {
    if (download.failedPhase == UpdateDownloadPhase.verifying &&
        (download.failure == UpdateDownloadFailure.network ||
            download.failure == UpdateDownloadFailure.timeout)) {
      return l.updateVerificationUnavailable;
    }
    return switch (download.failure) {
      UpdateDownloadFailure.checksum => l.updateChecksumFailed,
      UpdateDownloadFailure.disk => l.updateDiskFailed,
      UpdateDownloadFailure.timeout => l.updateDownloadTimeout,
      UpdateDownloadFailure.unsafeAsset => l.updateUnsafePackage,
      _ => l.updateDownloadFailed,
    };
  }

  static String _installGuide(
    AppLocalizations l,
    UpdateOperatingSystem? system,
  ) => switch (system) {
    UpdateOperatingSystem.windows => l.updateWindowsGuide,
    UpdateOperatingSystem.macos => l.updateMacGuide,
    UpdateOperatingSystem.linux => l.updateLinuxGuide,
    _ => l.updateAndroidGuide,
  };
  static String _actionMessage(AppLocalizations l, UpdateActionResult result) =>
      switch (result.status) {
        UpdateActionStatus.handedOff => l.updateHandedOff,
        UpdateActionStatus.permissionRequired => l.updatePermissionRequired,
        UpdateActionStatus.cancelled => l.updateInstallCancelled,
        UpdateActionStatus.failed => switch (result.failure) {
          UpdateActionFailure.permissionDenied => l.updatePermissionDenied,
          UpdateActionFailure.incompatiblePackage => l.updateIncompatible,
          UpdateActionFailure.invalidFile => l.updateChecksumFailed,
          _ => l.updateInstallFailed,
        },
      };
}

class _CallbackService extends UpdateService {
  _CallbackService(this.callback);
  final Future<AppRelease> Function() callback;
  @override
  Future<AppRelease> check() => callback();
}

class _CallbackPlatform implements UpdatePlatform {
  _CallbackPlatform(this.open);
  final Future<bool> Function(Uri)? open;
  @override
  Future<UpdateCapabilities> capabilities() async => UpdateCapabilities(
    system: UpdateOperatingSystem.unsupported,
    architecture: null,
  );
  @override
  Future<UpdateActionResult> openRelease(AppRelease release) async =>
      UpdateActionResult(
        await open?.call(release.url) == true
            ? UpdateActionStatus.handedOff
            : UpdateActionStatus.failed,
      );
  @override
  Future<UpdateActionResult> install(VerifiedUpdate update) async =>
      const UpdateActionResult(UpdateActionStatus.failed);
  @override
  Future<UpdateActionResult> requestInstallPermission() async =>
      const UpdateActionResult(UpdateActionStatus.failed);
}
