import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_display_form.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_page.dart' show kPlayerChromeBarExtent;

/// 播放器弹幕面板:开关、状态、手动搜索、常用/高级显示参数。
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
    return Positioned(
      right: AppSpacing.xl,
      bottom: 112,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 400, maxHeight: maxHeight),
        child: Material(
          key: DanmakuKeys.panel,
          color: scheme.surfaceContainerHigh,
          elevation: 8,
          shadowColor: scheme.shadow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.xl),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.danmaku,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Switch.adaptive(
                        key: DanmakuKeys.toggle,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        value: danmaku.danmakuOn,
                        onChanged: (_) => unawaited(danmaku.toggleDanmaku()),
                      ),
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  Text(
                    danmakuStatusText(l10n, danmaku),
                    key: DanmakuKeys.status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: unreachable
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (!configured) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n.danmakuOfficialSetupHint,
                      key: DanmakuKeys.setupHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  FilledButton.tonal(
                    key: DanmakuKeys.search,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        widget.onSearch();
                      });
                    },
                    child: Text(l10n.danmakuSearch),
                  ),
                  if (configured) ...[
                    const SizedBox(height: AppSpacing.xs),
                    DanmakuDisplayForm(
                      value: danmaku.display,
                      onChanged: (next) => unawaited(danmaku.setDisplay(next)),
                      layout: DanmakuFormLayout.playerBasic,
                    ),
                    InkWell(
                      key: DanmakuKeys.advancedToggle,
                      onTap: () {
                        setState(() => _advancedExpanded = !_advancedExpanded);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xxs,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.danmakuAdvanced,
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                            Icon(
                              _advancedExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_advancedExpanded)
                      DanmakuDisplayForm(
                        value: danmaku.display,
                        onChanged: (next) =>
                            unawaited(danmaku.setDisplay(next)),
                        layout: DanmakuFormLayout.playerAdvanced,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
