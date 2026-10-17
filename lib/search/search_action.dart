import 'package:flutter/foundation.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 顶栏中的搜索入口。
///
/// 宽窗口是一枚搜索框样式的胶囊:放大镜、提示文字与快捷键提示,
/// 一眼就知道能搜、怎么搜;窄窗口退回图标按钮。点击行为与
/// [openSearch] 一致:打开覆盖层,不 push `/search` 页壳。
class SearchAction extends StatelessWidget {
  const SearchAction({
    super.key,
    this.focusNode,
    this.expanded = false,
    this.overArtwork = false,
  });

  final FocusNode? focusNode;

  /// 显示为带提示文字和快捷键的胶囊。
  final bool expanded;

  /// 顶栏叠在海报画面上:胶囊改用半透明深色底与浅色描边。
  final bool overArtwork;

  static const pillKey = Key('app-shell-search');

  /// 平台对应的搜索快捷键提示。
  static String shortcutLabel([TargetPlatform? platform]) {
    final target = platform ?? defaultTargetPlatform;
    return target == TargetPlatform.macOS || target == TargetPlatform.iOS
        ? '⌘ F'
        : 'Ctrl F';
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    if (auth == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.isLoggedIn) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        if (!expanded) {
          return AppIconButton(
            key: pillKey,
            focusNode: focusNode,
            tooltip: l10n.search,
            onPressed: () => openSearch(context),
            padding: EdgeInsets.zero,
            constraints: kTitleBarIconConstraints,
            size: 18,
            icon: const Icon(AppIcons.search, fill: AppIcons.filled),
          );
        }
        return _SearchPill(
          focusNode: focusNode,
          overArtwork: overArtwork,
          label: l10n.searchHint,
          tooltip: l10n.search,
          onPressed: () => openSearch(context),
        );
      },
    );
  }
}

class _SearchPill extends StatefulWidget {
  const _SearchPill({
    required this.focusNode,
    required this.overArtwork,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final FocusNode? focusNode;
  final bool overArtwork;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  static const double width = 248;
  static const double height = 36;

  @override
  State<_SearchPill> createState() => _SearchPillState();
}

class _SearchPillState extends State<_SearchPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final over = widget.overArtwork;
    final Color fill;
    final Color border;
    final Color ink;
    if (over) {
      fill = const Color(0xff000000).withValues(alpha: _hovered ? 0.44 : 0.30);
      border = const Color(0xffffffff).withValues(alpha: _hovered ? 0.3 : 0.18);
      ink = const Color(0xffffffff).withValues(alpha: 0.88);
    } else if (light) {
      fill = _hovered ? scheme.surfaceContainer : scheme.surfaceContainerLowest;
      border = _hovered
          ? scheme.outline.withValues(alpha: 0.5)
          : scheme.outlineVariant;
      ink = scheme.onSurfaceVariant;
    } else {
      fill = _hovered
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerHigh.withValues(alpha: 0.72);
      border = scheme.outlineVariant.withValues(alpha: _hovered ? 1 : 0.6);
      ink = scheme.onSurfaceVariant;
    }
    final keyStyle = theme.textTheme.labelSmall?.copyWith(
      color: ink,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    final radius = BorderRadius.circular(_SearchPill.height / 2);
    return AppTooltip(
      message: widget.tooltip,
      child: Semantics(
        label: widget.tooltip,
        child: AppSurfaceAction(
          key: SearchAction.pillKey,
          focusNode: widget.focusNode,
          borderRadius: radius,
          onTap: widget.onPressed,
          onHover: (value) => setState(() => _hovered = value),
          child: AnimatedContainer(
            duration: AppMotion.durationOf(context, AppMotion.fast),
            curve: AppMotion.standard,
            width: _SearchPill.width,
            height: _SearchPill.height,
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                Icon(AppIcons.search, size: 18, color: ink),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: (over ? const Color(0xffffffff) : ink).withValues(
                      alpha: 0.12,
                    ),
                  ),
                  child: Text(SearchAction.shortcutLabel(), style: keyStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开搜索覆盖层;已打开时聚焦输入,不重复入栈、不 push `/search`。
void openSearch(BuildContext context) {
  SearchOverlayController.maybeOf(context)?.open();
}

/// 关闭搜索覆盖层;未打开时为 no-op。
void closeSearch(BuildContext context) {
  SearchOverlayController.maybeOf(context)?.close();
}

/// AppShell 提供的搜索覆盖层控制:打开、关闭、是否已显示。
class SearchOverlayController extends InheritedWidget {
  const SearchOverlayController({
    super.key,
    required this.isOpen,
    required this.open,
    required this.close,
    required super.child,
  });

  final bool isOpen;
  final VoidCallback open;
  final VoidCallback close;

  static SearchOverlayController? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<SearchOverlayController>();
  }

  @override
  bool updateShouldNotify(SearchOverlayController oldWidget) {
    return isOpen != oldWidget.isOpen;
  }
}
