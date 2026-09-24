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

  /// 页面左右边距:首页分栏、片库网格、详情章节对齐同一条竖线。
  static const double page = xl;
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

/// 海报/剧照之上的实色遮罩 token:渐变与底衬的 alpha、stop 与高度。
///
/// 由 `BackdropScrim`、`ScrimIconButton`、顶栏保护渐变、播放控制层渐变与
/// 搜索遮罩共同引用,不在页面内散落十六进制黑。系统要求减少动态效果时,
/// 非透明段的 alpha 经 [resolve] 抬到不低于 [reduced],透明端保持透明。
abstract final class AppScrim {
  /// 顶带起点:保护顶栏与返回钮,向下溶到透明。
  static const double top = 0.55;

  /// 顶栏自身渐变起点与中段(`_TopBar`),比顶带更轻。
  static const double topBar = 0.38;
  static const double topBarMid = 0.10;
  static const List<double> topBarStops = [0, 0.55, 1];

  /// 顶带默认高度 = 顶栏 56 + 溶入 36;有窗口铬时由调用方传入实际值。
  static const double topBandHeight = 92;

  /// 左侧文字带:三段横向渐变,自左向右溶到透明。
  static const double textStart = 0.72;
  static const double textMid = 0.30;
  static const List<double> textStops = [0, 0.45, 1];

  /// 文字带占宽比例,与 hero 文字块最大宽度(≤ 60% 视口)对齐。
  static const double textBandWidthFactor = 0.7;

  /// 底带:透明 → 页面底色 α[bottomMid] → 页面底色。
  static const double bottomMid = 0.6;
  static const List<double> bottomStops = [0.5, 0.8, 1];

  /// 圆形控件底衬(`ScrimIconButton`)。
  static const double control = 0.55;

  /// 控件禁用态图标 alpha。
  static const double controlDisabledIcon = 0.38;

  /// 播放控制层:底栏渐变终点(原 0xCC)、软段(原 0x8A)、
  /// 面板遮罩(原 0xD9)、结束卡遮罩(原 0x99)。
  static const double playerBar = 0.80;
  static const double playerBarSoft = 0.54;
  static const double playerPanel = 0.85;
  static const double playerBarrier = 0.60;

  /// 搜索覆盖层压暗遮罩。
  static const double barrier = 0.55;

  /// 减少动态效果时非透明段的最低 alpha。
  static const double reduced = 0.85;

  /// 按 [reduce] 解析 [alpha]:减少动效时不低于 [reduced],透明(0)保持透明。
  static double resolve(double alpha, {required bool reduce}) {
    if (!reduce || alpha <= 0) {
      return alpha;
    }
    return alpha < reduced ? reduced : alpha;
  }

  /// [resolve] 的 [BuildContext] 便捷形式。
  static double of(BuildContext context, double alpha) {
    return resolve(alpha, reduce: MediaQuery.disableAnimationsOf(context));
  }
}

/// 手机端专用 token(R8):海报卡阴影、按压反馈档位与导航栏模糊。
///
/// 仅 Android 手机布局引用;桌面/TV 组件不得依赖本段。
abstract final class AppMobileCard {
  /// 静止态投影:抬高海报卡,与页面底色分层。
  static const double shadowBlur = 16;
  static const double shadowSpread = 0;
  static const double shadowOffsetY = 6;
  static const double shadowAlpha = 0.42;

  /// 按压亮度增幅(BlendMode.plus 白色遮罩的 alpha)。
  static const double pressBrighten = 0.07;

  /// 按压缩放档位:海报卡等可点卡片用 [pressScale],主播放按钮等
  /// 强调控件用 [pressScaleStrong]。
  static const double pressScale = 0.96;
  static const double pressScaleStrong = 0.94;

  /// 按压回弹时长档,与 [AppMotion.fast] 对齐。
  static const Duration pressDuration = AppMotion.fast;
}

/// 手机端 hero 区渐变端点(R8):背图向页面底色/顶栏的溶入位置。
abstract final class AppMobileHero {
  /// 顶部不溶(0),向下溶到透明/底色。
  static const double topStart = 0;
  static const double topEnd = 0.40;

  /// 底部文字带上缘:文字带从 [bottomStart] 处开始抬升底色。
  static const double bottomStart = 0.45;
  static const double bottomEnd = 1;

  /// hero 渐变默认 stops,与 [AppScrim.textStops] 节奏一致。
  static const List<double> stops = [0, 0.45, 1];
}

/// 手机端控制层渐变(R8):顶栏与底栏向播放画面的溶入端点。
///
/// alpha 值与 [AppScrim.playerBar] 系对齐,页面不得再写死 black54/black87。
abstract final class AppMobileControls {
  /// 顶栏渐变:从 [AppScrim.topBar] 开始向下溶到透明。
  static const double topAlpha = AppScrim.topBar;
  static const double topMidAlpha = AppScrim.topBarMid;

  /// 底栏渐变:透明起,经软段到 [AppScrim.playerBar]。
  static const double bottomSoftAlpha = AppScrim.playerBarSoft;
  static const double bottomAlpha = AppScrim.playerBar;

  /// 底栏渐变起止位置(相对底栏高度)。
  static const double bottomStart = 0;
  static const double bottomEnd = 1;
}

/// 手机端底部导航 token(R3/R8):模糊开关与选中 pill 动效档位。
abstract final class AppMobileNav {
  /// 导航栏毛玻璃模糊开关;关闭时导航栏退回纯色底。
  static const bool blurEnabled = true;

  /// 模糊强度,复用 [AppGlass.barBlur]。
  static const double blur = AppGlass.barBlur;

  /// 选中 pill 指示器动效时长档,与 [AppMotion] 对齐;
  /// NavigationBar 通过 `animationDuration` 引用。
  static const Duration pillDuration = AppMotion.normal;

  /// 选中 pill 指示器圆角(胶囊)。
  static const double pillRadius = AppRadii.md;

  /// 导航栏底色 alpha(透明底,内容可从背后透出)。
  static const double backgroundAlpha = 0.0;

  /// 悬浮导航离窗口边缘的最小间距。贴底时为 0。
  static const double floatMargin = AppSpacing.md;

  /// 64dp 高的导航做成胶囊。贴底栏不加外圆角。
  static const double floatRadius = 32;

  /// Material 3 NavigationBar 的高度，加上上方溶入带。
  /// 悬浮时页面要留出这段，最后一行才能滚到栏的上面。
  static const double barHeight = 80;
  static const double fadeHeight = 36;
}

/// Liquid Glass 浮层材质:只用于顶栏/面板/控件,不铺在海报内容上。
abstract final class AppGlass {
  static const double barBlur = 26;
  static const double panelBlur = 32;
  static const double controlBlur = 22;
  static const double pillBlur = 18;

  static const double barTint = 0.40;
  static const double panelTint = 0.48;
  static const double controlTint = 0.36;
  static const double pillTint = 0.30;

  static const double reducedTint = 0.92;
  static const double edgeLight = 0.16;
  static const double specular = 0.14;
}
