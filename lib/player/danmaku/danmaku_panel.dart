import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_display_form.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_page.dart' show kPlayerChromeBarExtent;

/// 播放器弹幕 HUD:开关、单行状态、搜索、常用/高级显示参数。
class DanmakuPanel extends StatefulWidget {
  const DanmakuPanel({
    super.key,
    required this.danmaku,
    required this.onClose,
    required this.onSearch,
  });

  final DanmakuController danmaku;
  final VoidCallback onClose;
  final VoidCallback onSearch;

  static const double panelWidth = 320;

  @override
  State<DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends State<DanmakuPanel> {
  bool _advancedExpanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.danmaku,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final danmaku = widget.danmaku;
    final configured = danmaku.isConfigured;
    final unreachable =
        danmaku.status == DanmakuStatus.unreachable ||
        danmaku.status == DanmakuStatus.customUnreachable;
    final maxHeight =
        MediaQuery.sizeOf(context).height -
        kPlayerChromeBarExtent -
        112 -
        AppSpacing.xl;
    final expandAdvanced = configured && _advancedExpanded;

    final chrome = _chrome(
      context,
      l10n: l10n,
      theme: theme,
      scheme: scheme,
      danmaku: danmaku,
      unreachable: unreachable,
      configured: configured,
    );

    return Positioned(
      right: AppSpacing.xl,
      bottom: 112,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: DanmakuPanel.panelWidth,
            maxHeight: maxHeight,
          ),
          child: LiquidGlass(
            kind: LiquidGlassKind.panel,
            width: DanmakuPanel.panelWidth,
            child: Material(
              key: DanmakuKeys.panel,
              type: MaterialType.transparency,
              child: expandAdvanced
                  ? SizedBox(
                      height: maxHeight,
                      width: DanmakuPanel.panelWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                            child: chrome,
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                              child: DanmakuDisplayForm(
                                value: danmaku.display,
                                onChanged: (next) =>
                                    unawaited(danmaku.setDisplay(next)),
                                layout: DanmakuFormLayout.playerAdvanced,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
                      child: chrome,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chrome(
    BuildContext context, {
    required AppLocalizations l10n,
    required ThemeData theme,
    required ColorScheme scheme,
    required DanmakuController danmaku,
    required bool unreachable,
    required bool configured,
  }) {
    final quiet = scheme.onSurface.withValues(alpha: 0.58);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.danmaku,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            Transform.scale(
              scale: 0.82,
              child: Switch.adaptive(
                key: DanmakuKeys.toggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                value: danmaku.danmakuOn,
                onChanged: (_) => unawaited(danmaku.toggleDanmaku()),
              ),
            ),
            _HudIconButton(
              buttonKey: DanmakuKeys.search,
              tooltip: l10n.danmakuSearch,
              icon: Icons.search_rounded,
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  widget.onSearch();
                });
              },
            ),
            _HudIconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: Icons.close_rounded,
              onPressed: widget.onClose,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: Text(
            danmakuStatusText(l10n, danmaku),
            key: DanmakuKeys.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: unreachable ? scheme.error : quiet,
              height: 1.25,
            ),
          ),
        ),
        if (!configured)
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: Text(
              l10n.danmakuOfficialSetupHint,
              key: DanmakuKeys.setupHint,
              style: theme.textTheme.bodySmall?.copyWith(color: quiet),
            ),
          ),
        if (configured) ...[
          DanmakuDisplayForm(
            value: danmaku.display,
            onChanged: (next) => unawaited(danmaku.setDisplay(next)),
            layout: DanmakuFormLayout.playerBasic,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 8),
            child: InkWell(
              key: DanmakuKeys.advancedToggle,
              onTap: () {
                setState(() => _advancedExpanded = !_advancedExpanded);
              },
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.danmakuAdvanced,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: quiet,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      _advancedExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: quiet,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _HudIconButton extends StatelessWidget {
  const _HudIconButton({
    this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key? buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        foregroundColor: scheme.onSurface.withValues(alpha: 0.82),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
    );
  }
}

/// 面板状态行:来源 + 匹配/加载文案。
String danmakuStatusText(AppLocalizations l10n, DanmakuController danmaku) {
  final source = danmaku.usesCustomSource
      ? l10n.danmakuCustom
      : l10n.danmakuOfficial;
  final String state;
  switch (danmaku.status) {
    case DanmakuStatus.active:
      if (danmaku.comments.isEmpty) {
        state = l10n.danmakuNoComments;
      } else {
        final loaded = l10n.danmakuLoadedCount(danmaku.comments.length);
        final title = danmaku.matchedTitle?.trim();
        state = title == null || title.isEmpty
            ? loaded
            : '$loaded · ${l10n.danmakuMatchedTo(title)}';
      }
    case DanmakuStatus.loading:
      state = l10n.danmakuMatching;
    case DanmakuStatus.noMatch:
      state = l10n.danmakuNoMatch;
    case DanmakuStatus.customUnreachable:
      state = l10n.danmakuCustomUnreachable;
    case DanmakuStatus.unreachable:
      state = danmaku.hasOfficialCredentials
          ? l10n.danmakuOfficialUnreachable
          : l10n.danmakuOfficialNeedsAuth;
    case DanmakuStatus.off:
    case DanmakuStatus.idle:
      state = '';
  }
  return state.isEmpty ? source : '$source · $state';
}
