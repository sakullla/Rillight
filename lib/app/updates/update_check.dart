import 'dart:async';

import '../l10n/app_localizations.dart';
import '../product.dart';
import '../ui/app_icons.dart';
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
      final theme = AppUiTheme.of(context);
      final scheme = theme.colorScheme;
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusBadgeIcon(
                  background: scheme.surfaceContainerHigh,
                  child: Icon(
                    AppIcons.info,
                    fill: AppIcons.filled,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.mobileVersion(kAppVersion),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        kProductName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppButton.icon(
              key: const Key('app-update-check-button'),
              variant: AppButtonVariant.tinted,
              icon: const Icon(
                AppIcons.refresh,
                fill: AppIcons.filled,
                size: 18,
              ),
              label: Text(l.updateCheck),
            ),
          ],
        ),
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final release = controller.release;
    final newer = release?.isNewerThan(controller.currentVersion) ?? false;
    final ignored = newer && controller.isReleaseIgnored(release);
    final checking = controller.checkPhase == UpdateCheckPhase.checking;
    final manualChecking = checking && controller.manualCheck;
    final isCurrent =
        controller.checkPhase == UpdateCheckPhase.current &&
        controller.manualCheck;
    final d = controller.download;
    final hasDownload = d.phase != UpdateDownloadPhase.idle;
    final sameDownload = hasDownload && d.release?.tag == release?.tag;
    final failure =
        controller.checkPhase == UpdateCheckPhase.failed &&
        controller.manualCheck;
    final message = manualChecking
        ? l.updateChecking
        : failure
        ? _checkFailure(l, controller.checkFailure)
        : newer
        ? l.updateAvailable(release!.version.toString())
        : isCurrent
        ? l.updateCurrent
        : l.mobileVersion(controller.currentVersion);
    final subtitle = newer
        ? l.updateVersionTransition(
            controller.currentVersion,
            release!.version.toString(),
          )
        : manualChecking || failure || isCurrent
        ? '$kProductName · ${l.mobileVersion(controller.currentVersion)}'
        : kProductName;
    final busyAction = controller.installing || controller.requestingPermission;
    final hasPrimaryActions =
        widget.showCheckButton ||
        (newer && controller.selection?.asset != null && !sameDownload) ||
        newer;

    final statusBorderColor = failure
        ? scheme.error.withValues(alpha: 0.42)
        : newer
        ? scheme.primary.withValues(alpha: 0.38)
        : scheme.outlineVariant.withValues(alpha: 0.45);

    final statusBody = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.showCheckButton) ...[
              _StatusBadgeIcon(
                background: failure
                    ? scheme.error.withValues(alpha: 0.14)
                    : newer || isCurrent || manualChecking
                    ? scheme.primary.withValues(alpha: 0.15)
                    : scheme.surfaceContainerHigh,
                child: manualChecking
                    ? CupertinoActivityIndicator(
                        radius: 8,
                        color: scheme.primary,
                      )
                    : Icon(
                        failure
                            ? AppIcons.error
                            : newer
                            ? AppIcons.download
                            : isCurrent
                            ? AppIcons.checkCircle
                            : AppIcons.info,
                        fill: AppIcons.filled,
                        size: 18,
                        color: failure
                            ? scheme.error
                            : newer || isCurrent
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        message,
                        key: const Key('app-update-status'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: failure ? scheme.error : scheme.onSurface,
                        ),
                      ),
                      if (newer)
                        _StatusPill(
                          label: l.updateNewBadge,
                          background: scheme.primaryContainer,
                          foreground: scheme.onPrimaryContainer,
                        )
                      else if (isCurrent)
                        _StatusPill(
                          label: l.updateCurrentBadge,
                          background: scheme.secondaryContainer,
                          foreground: scheme.onSecondaryContainer,
                        ),
                      if (ignored)
                        _StatusPill(
                          key: const Key('app-update-ignored-badge'),
                          label: l.updateIgnoredBadge(
                            release!.version.toString(),
                          ),
                          background: scheme.surfaceContainerHighest,
                          foreground: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (hasPrimaryActions) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.showCheckButton)
                AppButton.icon(
                  key: const Key('app-update-check-button'),
                  variant: newer
                      ? AppButtonVariant.outlined
                      : AppButtonVariant.tinted,
                  onPressed: manualChecking ? null : () => controller.check(),
                  icon: const Icon(
                    AppIcons.refresh,
                    fill: AppIcons.filled,
                    size: 18,
                  ),
                  label: Text(l.updateCheck),
                ),
              if (newer && controller.selection?.asset != null && !sameDownload)
                AppButton.icon(
                  key: const Key('app-update-download'),
                  variant: AppButtonVariant.filled,
                  onPressed: d.busy || busyAction
                      ? null
                      : controller.startDownload,
                  icon: const Icon(
                    AppIcons.download,
                    fill: AppIcons.filled,
                    size: 18,
                  ),
                  label: Text(l.updateDownload),
                ),
              if (newer)
                AppButton.icon(
                  key: const Key('app-update-open'),
                  variant: AppButtonVariant.outlined,
                  onPressed: controller.openingRelease
                      ? null
                      : () => controller.openRelease(),
                  icon: const Icon(
                    AppIcons.openInNew,
                    fill: AppIcons.filled,
                    size: 18,
                  ),
                  label: Text(l.updateOpenRelease),
                ),
              if (newer && widget.showCheckButton)
                AppButton.icon(
                  key: const Key('app-update-ignore-version'),
                  variant: AppButtonVariant.plain,
                  onPressed: () => unawaited(
                    ignored
                        ? controller.unignoreRelease()
                        : controller.ignoreRelease(release),
                  ),
                  icon: Icon(
                    ignored ? AppIcons.refresh : AppIcons.block,
                    fill: AppIcons.filled,
                    size: 18,
                  ),
                  label: Text(
                    ignored ? l.updateUnignoreVersion : l.updateIgnoreVersion,
                  ),
                ),
            ],
          ),
        ],
        if (newer && controller.selection?.asset == null) ...[
          const SizedBox(height: 8),
          _UpdateNoticeBox(
            icon: AppIcons.info,
            child: Text(
              l.updateNoPackage,
              key: const Key('app-update-no-package'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
        if (newer && release!.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          if (widget.expandNotes)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        AppIcons.episodes,
                        fill: AppIcons.filled,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l.updateNotes,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(release.notes, style: theme.textTheme.bodyMedium),
                ],
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: AppDisclosure(
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                leading: Icon(
                  AppIcons.episodes,
                  fill: AppIcons.filled,
                  size: 16,
                  color: scheme.primary,
                ),
                title: Text(
                  l.updateNotes,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      release.notes,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (controller.releaseAction?.status == UpdateActionStatus.failed) ...[
          const SizedBox(height: 8),
          _UpdateNoticeBox(
            icon: AppIcons.error,
            isError: true,
            child: Text(
              l.updateOpenFailed,
              key: const Key('app-update-open-failed'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ],
    );

    return FocusTraversalGroup(
      child: Column(
        key: const Key('app-update-check'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showCheckButton)
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(color: statusBorderColor),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(padding: const EdgeInsets.all(14), child: statusBody),
                  AppDivider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  AppSwitchTile(
                    key: const Key('app-update-auto-reminder'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    title: Text(
                      l.updateAutoReminderTitle,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(l.updateAutoReminderSubtitle),
                    value: controller.autoReminderEnabled,
                    onChanged: (value) =>
                        unawaited(controller.setAutoReminderEnabled(value)),
                  ),
                ],
              ),
            )
          else
            statusBody,
          if (hasDownload) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: d.phase == UpdateDownloadPhase.failed
                      ? scheme.error.withValues(alpha: 0.42)
                      : d.phase == UpdateDownloadPhase.ready
                      ? scheme.primary.withValues(alpha: 0.38)
                      : scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _StatusBadgeIcon(
                        background: d.phase == UpdateDownloadPhase.failed
                            ? scheme.error.withValues(alpha: 0.14)
                            : d.phase == UpdateDownloadPhase.ready
                            ? scheme.primary.withValues(alpha: 0.16)
                            : scheme.surfaceContainerHigh,
                        child:
                            d.busy &&
                                (d.phase != UpdateDownloadPhase.downloading ||
                                    d.fraction == null)
                            ? CupertinoActivityIndicator(
                                radius: 8,
                                color: scheme.primary,
                              )
                            : Icon(
                                d.phase == UpdateDownloadPhase.failed
                                    ? AppIcons.error
                                    : d.phase == UpdateDownloadPhase.ready
                                    ? AppIcons.checkCircle
                                    : AppIcons.download,
                                fill: AppIcons.filled,
                                size: 18,
                                color: d.phase == UpdateDownloadPhase.failed
                                    ? scheme.error
                                    : d.phase == UpdateDownloadPhase.ready ||
                                          d.busy
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.updatePackageVersion(
                                d.release!.version.toString(),
                              ),
                              key: const Key('app-update-package-version'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              switch (d.phase) {
                                UpdateDownloadPhase.downloading =>
                                  d.fraction == null
                                      ? l.updateDownloadingUnknown(
                                          _bytes(d.received),
                                        )
                                      : l.updateDownloading(
                                          _bytes(d.received),
                                          _bytes(d.total!),
                                          (d.fraction! * 100).floor(),
                                        ),
                                UpdateDownloadPhase.verifying =>
                                  l.updateVerifying,
                                UpdateDownloadPhase.ready => l.updateReady,
                                UpdateDownloadPhase.cancelled =>
                                  l.updateCancelled,
                                UpdateDownloadPhase.failed => _downloadFailure(
                                  l,
                                  d,
                                ),
                                UpdateDownloadPhase.idle => '',
                              },
                              key: const Key('app-update-download-status'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: d.phase == UpdateDownloadPhase.failed
                                    ? scheme.error
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (d.busy &&
                      d.phase == UpdateDownloadPhase.downloading &&
                      d.fraction != null) ...[
                    const SizedBox(height: 10),
                    AppProgressBar(value: d.fraction!, height: 6),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (d.busy)
                        AppButton.icon(
                          key: const Key('app-update-cancel'),
                          variant: AppButtonVariant.outlined,
                          onPressed: controller.cancelDownload,
                          icon: const Icon(
                            AppIcons.close,
                            fill: AppIcons.filled,
                            size: 18,
                          ),
                          label: Text(l.updateCancelDownload),
                        ),
                      if (d.phase == UpdateDownloadPhase.failed ||
                          d.phase == UpdateDownloadPhase.cancelled)
                        AppButton.icon(
                          key: const Key('app-update-retry'),
                          variant: AppButtonVariant.tinted,
                          onPressed: busyAction
                              ? null
                              : controller.retryDownload,
                          icon: const Icon(
                            AppIcons.replay,
                            fill: AppIcons.filled,
                            size: 18,
                          ),
                          label: Text(l.retry),
                        ),
                      if (d.phase == UpdateDownloadPhase.ready)
                        AppButton.icon(
                          key: const Key('app-update-install'),
                          variant: AppButtonVariant.filled,
                          onPressed: busyAction
                              ? null
                              : () => _install(controller),
                          icon: const Icon(
                            AppIcons.bolt,
                            fill: AppIcons.filled,
                            size: 18,
                          ),
                          label: Text(
                            controller.installing
                                ? l.updateInstalling
                                : l.updateInstall,
                          ),
                        ),
                      if (d.release?.tag != release?.tag)
                        AppButton.icon(
                          key: const Key('app-update-download-release'),
                          variant: AppButtonVariant.outlined,
                          onPressed: controller.openingRelease
                              ? null
                              : () => controller.openRelease(
                                  candidate: d.release,
                                ),
                          icon: const Icon(
                            AppIcons.openInNew,
                            fill: AppIcons.filled,
                            size: 18,
                          ),
                          label: Text(l.updateOpenRelease),
                        ),
                    ],
                  ),
                  if (d.phase == UpdateDownloadPhase.ready) ...[
                    const SizedBox(height: 10),
                    _UpdateNoticeBox(
                      icon: AppIcons.info,
                      child: Text(
                        _installGuide(l, controller.capabilities?.system),
                        key: const Key('app-update-install-guide'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (_playbackBlocked) ...[
                    const SizedBox(height: 8),
                    _UpdateNoticeBox(
                      icon: AppIcons.error,
                      isError: true,
                      child: Text(
                        l.updateFinishPlayback,
                        key: const Key('app-update-playback-blocked'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ],
                  if (controller.installAction != null) ...[
                    const SizedBox(height: 8),
                    _UpdateNoticeBox(
                      icon:
                          controller.installAction!.status ==
                              UpdateActionStatus.failed
                          ? AppIcons.error
                          : AppIcons.shield,
                      isError:
                          controller.installAction!.status ==
                          UpdateActionStatus.failed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _actionMessage(l, controller.installAction!),
                            key: const Key('app-update-install-result'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color:
                                  controller.installAction!.status ==
                                      UpdateActionStatus.failed
                                  ? scheme.error
                                  : scheme.onSurface,
                            ),
                          ),
                          if (controller.installAction!.localPath
                              case final path?) ...[
                            const SizedBox(height: 4),
                            Text(
                              l.updateLocalPackage(path),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (controller.installAction!.status ==
                              UpdateActionStatus.permissionRequired) ...[
                            const SizedBox(height: 8),
                            AppButton.icon(
                              key: const Key('app-update-permission'),
                              variant: AppButtonVariant.tinted,
                              onPressed: busyAction
                                  ? null
                                  : controller.requestInstallPermission,
                              icon: const Icon(
                                AppIcons.shield,
                                fill: AppIcons.filled,
                                size: 18,
                              ),
                              label: Text(l.updateAllowSource),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (controller.permissionAction != null) ...[
                    const SizedBox(height: 8),
                    _UpdateNoticeBox(
                      icon:
                          controller.permissionAction!.status ==
                              UpdateActionStatus.failed
                          ? AppIcons.error
                          : AppIcons.info,
                      isError:
                          controller.permissionAction!.status ==
                          UpdateActionStatus.failed,
                      child: Text(
                        controller.permissionAction!.status ==
                                UpdateActionStatus.handedOff
                            ? l.updatePermissionOpened
                            : _actionMessage(l, controller.permissionAction!),
                        key: const Key('app-update-permission-result'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
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

class _StatusBadgeIcon extends StatelessWidget {
  const _StatusBadgeIcon({required this.background, required this.child});
  final Color background;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadii.sm),
    ),
    child: child,
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });
  final String label;
  final Color background;
  final Color foreground;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: AppUiTheme.of(context).textTheme.labelSmall
          ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
    ),
  );
}

class _UpdateNoticeBox extends StatelessWidget {
  const _UpdateNoticeBox({
    required this.icon,
    required this.child,
    this.isError = false,
  });
  final IconData icon;
  final Widget child;
  final bool isError;
  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isError
            ? scheme.error.withValues(alpha: 0.08)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: isError
              ? scheme.error.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              icon,
              fill: AppIcons.filled,
              size: 16,
              color: isError ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
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
