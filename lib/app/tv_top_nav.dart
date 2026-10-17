import '../auth/tv_server_selection_page.dart';
import '../auth/auth_scope.dart';
import '../home/catalog_scope.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 顶部导航:品牌字标 + 四个胶囊标签 + 用户名片。
///
/// 方向键左右在菜单间移动;**下键**进入当前菜单对应的面板([onEnter]);
/// 确认键只切换面板不移动焦点([onSelect])。面板顶部再按上键经方向遍历
/// 回到本栏。内容向下滚动后由 TvShell 把整条栏收起,滚动内容永远不会
/// 和导航叠在一起;焦点回到栏上时栏重新出现、面板回到顶部。
class TvTopNavBar extends StatelessWidget {
  const TvTopNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    required this.onEnter,
    this.homeNode,
    this.onServerEntered,
    this.username,
    this.overImage = false,
  });

  /// 当前面板下标。
  final int index;
  final VoidCallback? onServerEntered;

  /// 确认/点按:只切换面板,焦点留在导航栏。
  final ValueChanged<int> onSelect;

  /// 下键:切换面板并把焦点送进面板内容。
  final ValueChanged<int> onEnter;

  /// 首页菜单项的焦点节点(返回键回落目标)。
  final FocusNode? homeNode;

  /// 右侧用户名,未登录为 null。
  final String? username;

  /// 栏下是 hero 影像:不画页面底色渐变,文字由 hero 顶部遮罩托底。
  final bool overImage;

  /// 960 画布下导航栏占用的高度;面板内容从这里以下开始。
  static const double reserveHeight = 64;

  /// 按当前视口换算后的占用高度。
  static double reserveOf(BuildContext context) =>
      reserveHeight * TvDesign.scaleOf(context);

  static const _icons = [
    AppIcons.home,
    AppIcons.aggregation,
    AppIcons.search,
    AppIcons.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final labels = [l.home, l.aggregation, l.search, l.settings];
    final size = MediaQuery.sizeOf(context);
    final horizontal = tvSafeGutter(size.width);
    final band = theme.scaffoldBackgroundColor;
    final bar = SafeArea(
      bottom: false,
      child: SizedBox(
        height: reserveHeight * s,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 非交互文本不拦截命中:hero/内容区在栏下出血时仍可点按。
              IgnorePointer(child: _Brand(name: l.appName)),
              SizedBox(width: 28 * s),
              for (var i = 0; i < labels.length; i++) ...[
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
                    variant: TvActionVariant.ghost,
                    leading: Icon(
                      _icons[i],
                      fill: i == index ? AppIcons.filled : AppIcons.outline,
                    ),
                    onPressed: () => onSelect(i),
                    child: Text(labels[i]),
                  ),
                ),
                SizedBox(width: 6 * s),
              ],
              const Spacer(),
              if (username case final name? when name.isNotEmpty)
                SizedBox(
                  width: 190 * s,
                  child: TvAction(
                    key: const Key('tv-nav-user'),
                    leading: const Icon(AppIcons.server),
                    onPressed: () => showTvServerSelection(
                      context,
                      auth: AuthScope.of(context),
                      onEntered: () async {
                        CatalogScope.maybeOf(context)?.reload();
                        onServerEntered?.call();
                      },
                      onLineChanged: () async {
                        CatalogScope.maybeOf(context)?.reload();
                      },
                    ),
                    child: Text(
                      AuthScope.of(context).session?.server.displayName ?? name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (overImage) return bar;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            band,
            band.withValues(alpha: .92),
            band.withValues(alpha: 0),
          ],
          stops: const [0, .7, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: 12 * s),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurface),
          child: bar,
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22 * s,
          height: 22 * s,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6 * s),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            ),
          ),
          child: Icon(
            AppIcons.play,
            fill: AppIcons.filled,
            size: 16 * s,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        SizedBox(width: 8 * s),
        Text(
          name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

/// 导航收起/展开的动画参数。
abstract final class TvNavMotion {
  static const Duration duration = AppMotion.normal;
}
