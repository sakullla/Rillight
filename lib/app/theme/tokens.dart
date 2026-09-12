import 'package:flutter/widgets.dart';

/// 4pt 栅格间距 token。统一全应用留白节奏。
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 48;
}

/// 圆角 token。
abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
}

/// 动效 token:统一时长与 easeOut 系曲线。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  /// 标准入场/状态过渡曲线。
  static const Curve standard = Curves.easeOutCubic;

  /// 强调型入场曲线(大面积位移、浮层展开)。
  static const Curve emphasized = Curves.easeOutQuart;

  /// 退场曲线,保持轻快收敛。
  static const Curve exit = Curves.easeInCubic;

  /// 将 [duration] 对 [MediaQuery.disableAnimationsOf] 求值。
  ///
  /// 系统要求减少动态效果时返回 [Duration.zero],循环动效应停止。
  static Duration durationOf(
    BuildContext context, [
    Duration duration = normal,
  ]) {
    return MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
  }
}

/// 响应式断点(逻辑像素宽度)。
///
/// 宽度 < [compact] 为紧凑布局;[compact] 至 [large] 为中等布局;
/// > [large] 为宽松布局。
abstract final class AppBreakpoints {
  static const double compact = 960;
  static const double large = 1440;
}
