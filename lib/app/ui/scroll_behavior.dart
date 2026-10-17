import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 桌面/TV 滚动行为：刻意不绘制任何滚动条。
///
/// `CupertinoScrollBehavior` 会给每一个可滚动组件（横向与纵向）包一层
/// `Scrollbar`，桌面鼠标悬停时货架、页面边缘浮出滚动条，与卡片标题 tooltip
/// 重叠，观感突兀。桌面/TV 的横向列表用悬浮翻页钮与滚轮表达可滚动性，
/// 纵向页面用平滑滚轮，滚动条只是噪音。此行为同时允许鼠标左键拖拽横排。
class AppScrollBehavior extends ScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
