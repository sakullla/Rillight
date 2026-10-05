import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';

/// Netflix 2025 式顶部横向导航:字标 + 图标胶囊菜单 + 用户名片。
///
/// 方向键左右在菜单间移动;**下键**进入当前菜单对应的面板([onEnter]);
/// 确认键只切换面板不移动焦点([onSelect])。面板顶部再按上键经方向遍历
/// 回到本栏。栏底渐变在深色主题压黑、浅色主题用 surface 渐隐,hero 内容
/// 可从栏下出血透出。
class TvTopNavBar extends StatelessWidget {
  const TvTopNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    required this.onEnter,
    this.homeNode,
    this.username,
  });

  /// 当前面板下标。
  final int index;

  /// 确认/点按:只切换面板,焦点留在导航栏。
  final ValueChanged<int> onSelect;

  /// 下键:切换面板并把焦点送进面板内容。
  final ValueChanged<int> onEnter;

  /// 首页菜单项的焦点节点(返回键回落目标)。
  final FocusNode? homeNode;

  /// 右侧用户名,未登录为 null。
  final String? username;

  /// 非首页面板的内容顶padding:避开叠在内容上的导航栏。
  static const double reserveHeight = 88;

  static const _icons = [
    Icons.home_rounded,
    Icons.video_library_rounded,
    Icons.search_rounded,
    Icons.settings_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labels = [l.home, l.aggregation, l.search, l.settings];
    final dark = scheme.brightness == Brightness.dark;
    final band = dark ? Colors.black : scheme.surface;
    final alpha = AppScrim.of(
      context,
      dark ? AppScrim.topBar : AppScrim.lightTopBar,
    );
    final horizontal = tvSafeGutter(MediaQuery.sizeOf(context).width);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            band.withValues(alpha: alpha),
            band.withValues(alpha: alpha * 0.45),
            band.withValues(alpha: 0),
          ],
          stops: AppScrim.topBarStops,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: horizontal,
            right: horizontal,
            top: 12,
            bottom: 24,
          ),
          child: Row(
            children: [
              // 非交互文本不拦截命中:hero/内容区在栏下出血时仍可点按。
              IgnorePointer(
                child: Text(
                  l.appName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              for (var i = 0; i < labels.length; i++)
                Focus(
                  skipTraversal: true,
                  canRequestFocus: false,
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      onEnter(i);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TvAction(
                    key: ValueKey('tv-nav-$i'),
                    autofocus: i == 0,
                    focusNode: i == 0 ? homeNode : null,
                    selected: i == index,
                    pill: true,
                    leading: Icon(_icons[i], size: 20),
                    onPressed: () => onSelect(i),
                    child: Text(labels[i]),
                  ),
                ),
              const Spacer(),
              if (username case final name? when name.isNotEmpty)
                IgnorePointer(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
