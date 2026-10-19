import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/media_server/models.dart';

/// 顶栏「浏览」入口:一次展开首页、聚合与全部媒体库。
///
/// 首页/聚合本身已有直接导航,所以在那些页面不显示本按钮。片库、货架、
/// 详情与人物页把它放在搜索左侧,两次操作内即可到达三个浏览目的地。
class BrowseMenuButton extends StatefulWidget {
  const BrowseMenuButton({
    super.key,
    required this.libraries,
    required this.currentLocation,
    required this.showLabel,
  });

  final List<MediaItem> libraries;

  /// 当前路由路径,用于判断库到库是否需要替换栈顶。
  final String currentLocation;

  /// 宽窗口显示「浏览」文字,窄窗口只留图标。
  final bool showLabel;

  static const buttonKey = Key('app-shell-browse');
  static const homeEntryKey = Key('app-shell-browse-home');
  static const aggregationEntryKey = Key('app-shell-browse-aggregation');
  static const dividerKey = Key('app-shell-browse-divider');

  static Key libraryEntryKey(String id) => Key('app-shell-browse-library-$id');

  /// 触发按钮的短标签。浏览入口只出现一个词,不随库数量变化。
  static const label = '浏览';

  @override
  State<BrowseMenuButton> createState() => _BrowseMenuButtonState();
}

class _BrowseMenuButtonState extends State<BrowseMenuButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'BrowseMenuButton');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  static IconData _iconFor(MediaItem library) =>
      switch (library.collectionTypeNormalized) {
        'movies' => AppIcons.movie,
        'tvshows' => AppIcons.series,
        'photos' => AppIcons.photoLibrary,
        'music' => AppIcons.music,
        'boxsets' => AppIcons.boxSet,
        _ => AppIcons.library,
      };

  Future<void> _openMenu() async {
    final box = context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final l10n = AppLocalizations.of(context);
    final libraries = widget.libraries;
    final picked = await showAppMenu<_BrowseChoice>(
      context: context,
      position: RelativeRect.fromLTRB(origin.dx, origin.dy, 0, 0),
      constraints: const BoxConstraints(maxWidth: 280),
      items: [
        AppMenuEntry(
          key: BrowseMenuButton.homeEntryKey,
          value: const _BrowseChoice(_BrowseAction.home),
          child: _label(context, AppIcons.home, l10n.home),
        ),
        AppMenuEntry(
          key: BrowseMenuButton.aggregationEntryKey,
          value: const _BrowseChoice(_BrowseAction.aggregation),
          child: _label(context, AppIcons.aggregation, l10n.aggregation),
        ),
        if (libraries.isNotEmpty)
          AppMenuEntry(
            key: BrowseMenuButton.dividerKey,
            value: const _BrowseChoice(_BrowseAction.divider),
            enabled: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                height: 1,
                child: ColoredBox(
                  color: AppUiTheme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
          ),
        for (final library in libraries)
          AppMenuEntry(
            key: BrowseMenuButton.libraryEntryKey(library.id),
            value: _BrowseChoice(_BrowseAction.library, libraryId: library.id),
            child: _label(
              context,
              _iconFor(library),
              library.name,
              iconColor: AppUiTheme.of(context).colorScheme.primary,
            ),
          ),
      ],
    );
    if (!mounted) return;
    // 菜单是浮层而不是页面:关闭后把键盘焦点交还触发按钮。
    _focus.requestFocus();
    if (picked == null) return;
    final router = GoRouter.of(context);
    switch (picked.action) {
      case _BrowseAction.home:
        router.go(AppRoutes.home);
      case _BrowseAction.aggregation:
        router.go(AppRoutes.aggregation);
      case _BrowseAction.library:
        _openLibrary(router, picked.libraryId!);
      case _BrowseAction.divider:
        break;
    }
  }

  /// 库到库替换栈顶,避免连续查看多个媒体库时越压越深;
  /// 从详情/人物进入则压栈,返回仍回详情。
  void _openLibrary(GoRouter router, String id) {
    final target = AppRoutes.library(id);
    final location = widget.currentLocation;
    if (location.startsWith('/library/') || location.startsWith('/shelf/')) {
      router.pushReplacement(target);
    } else {
      router.push(target);
    }
  }

  Widget _label(
    BuildContext context,
    IconData icon,
    String text, {
    Color? iconColor,
  }) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          fill: AppIcons.filled,
          color: iconColor ?? scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.start,
            style: AppUiTheme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final button = AppButton(
      focusNode: _focus,
      variant: AppButtonVariant.plain,
      onPressed: _openMenu,
      foregroundColor: scheme.onSurfaceVariant,
      minimumSize: const Size(44, kWindowChromeHeight),
      padding: EdgeInsets.symmetric(
        horizontal: widget.showLabel ? AppSpacing.xs : AppSpacing.xxs,
      ),
      style: AppButtonStyle(
        hoverColor: scheme.onSurface.withValues(alpha: 0.05),
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(AppIcons.more, size: 20),
          if (widget.showLabel) ...[
            const SizedBox(width: 6),
            const Text(BrowseMenuButton.label),
            const SizedBox(width: 2),
            Icon(
              AppIcons.chevronDown,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    if (widget.showLabel) return button;
    return AppTooltip(message: BrowseMenuButton.label, child: button);
  }
}

enum _BrowseAction { home, aggregation, divider, library }

class _BrowseChoice {
  const _BrowseChoice(this.action, {this.libraryId});

  final _BrowseAction action;
  final String? libraryId;
}
