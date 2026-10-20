import 'package:flutter/widgets.dart';

/// 灯川品牌基色（静夜蓝）。所有调色板与共享控件从这里取品牌色，
/// 不在页面里直接写品牌十六进制。
///
/// 品牌只有一个强调色：主操作、选中、焦点与进度都取它。辅助色与第三色
/// 是同色系低饱和与中性色，只写在 `AppPalette` 的 Tones 里，不提升为品牌常量。
abstract final class AppBrand {
  /// 深色主题的静夜蓝强调。
  static const Color accent = Color(0xFF82ADFF);

  /// 浅色主题的深静夜蓝强调；白字压在上面仍保持 4.5:1。
  static const Color accentDeep = Color(0xFF1E56C8);

  /// 深色强调色上的前景。
  static const Color onAccent = Color(0xFF0A1A33);

  /// 深色主题页面最底层的冷石墨。
  static const Color ink = Color(0xFF0B0D10);

  /// 浅色主题的冷白纸。
  static const Color paper = Color(0xFFF6F7F9);

  /// 评分星：深色用亮金，浅色压深以通过 4.5:1。
  static const Color ratingStarDark = Color(0xFFFFC107);
  static const Color ratingStarLight = Color(0xFF825400);

  static Color ratingStar(Brightness brightness) =>
      brightness == Brightness.dark ? ratingStarDark : ratingStarLight;
}

/// 第三方媒体服务器的官方标识色。只用于 Emby/Jellyfin/Plex 标记本身，
/// 不参与页面主题派生。
abstract final class AppServerBrand {
  static const Color emby = Color(0xFF52B54B);

  /// Jellyfin 官方标识使用紫 `#AA5CC3` 到青 `#00A4DC` 的渐变;这里的单色
  /// 标记取同一色带上的紫 `0xFF8862E0`,便于在深色底上保持统一明度。
  /// 它是单色化后的标记色,不是官方品牌色原值;改动前先同步
  /// `lib/library/provider_marks.dart` 与登录页的标记配色。
  static const Color jellyfin = Color(0xFF8862E0);
  static const Color plex = Color(0xFFE5A00D);

  /// Jellyfin 标记的紫→青渐变两端。
  static const Color jellyfinPurple = Color(0xFFAA5CC3);
  static const Color jellyfinBlue = Color(0xFF00A4DC);

  /// Plex 深底标记的底板色。
  static const Color plexSurface = Color(0xFF282A2D);
}

/// 服务状态的语义色。明暗主题各取一档，页面不再写原始十六进制。
abstract final class AppSemantic {
  static const Color successDark = Color(0xFF4ADE80);
  static const Color successLight = Color(0xFF16A34A);
  static const Color warningDark = Color(0xFFFBBF24);
  static const Color warningLight = Color(0xFFB45309);

  static Color success(Brightness brightness) =>
      brightness == Brightness.dark ? successDark : successLight;

  static Color warning(Brightness brightness) =>
      brightness == Brightness.dark ? warningDark : warningLight;
}

/// 品牌渐变。只剩首页头图与详情头部的单色相氛围层；
/// 主按钮等控件一律实色，不再有品牌渐变。
abstract final class AppBrandGradient {
  /// 氛围层渐变的 stop。[ambientFor] 的颜色数与它一一对应。
  static const List<double> ambientStops = [0, 0.45, 0.8];

  /// 首页头图与详情头部的单层氛围渐变。
  ///
  /// 只有 [mood] 一个色相：从 [alpha] 向同色相的透明溶出，
  /// 不再叠加固定的第二品牌色 stop。
  static LinearGradient ambientFor(Color mood, {double alpha = 0.18}) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: ambientStops,
      colors: [
        mood.withValues(alpha: alpha),
        mood.withValues(alpha: alpha * 0.4),
        mood.withValues(alpha: 0),
      ],
    );
  }
}

/// 中性黑/白/透明。所有遮罩与浮层底色从这里取，避免散落十六进制。
abstract final class AppInk {
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color transparent = Color(0x00000000);

  /// 中性灰:取色种子没有可识别色相时的兜底。
  static const Color gray = Color(0xFF808080);

  static Color scrim(double alpha) => black.withValues(alpha: alpha);
}
