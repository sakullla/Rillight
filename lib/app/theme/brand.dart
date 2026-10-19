import 'package:flutter/widgets.dart';

/// 灯川品牌基色。所有调色板与共享控件从这里取品牌色，
/// 不在页面里直接写品牌十六进制。
abstract final class AppBrand {
  /// 深色主题的樱花粉主强调。
  static const Color pink = Color(0xFFFF7FA8);

  /// 浅色主题的深樱粉主强调；在 surfaceBright 上仍保持 4.5:1。
  static const Color pinkDeep = Color(0xFFB21F54);

  /// 深色主题的天青辅助。
  static const Color cyan = Color(0xFF6FD6F2);

  /// 浅色主题的深天青辅助。
  static const Color cyanDeep = Color(0xFF0A6178);

  /// 深色主题的月光紫第三色。
  static const Color lavender = Color(0xFFC8B8FF);

  /// 浅色主题的深紫第三色。
  static const Color lavenderDeep = Color(0xFF5B4BC4);

  static const Color onPink = Color(0xFF3A1124);
  static const Color onCyan = Color(0xFF062A33);
  static const Color onLavender = Color(0xFF221448);

  /// 页面最底层的近黑紫。
  static const Color ink = Color(0xFF0D0A12);

  /// 浅色主题的奶白粉纸。
  static const Color paper = Color(0xFFFAF2F7);

  /// 评分星：深色用亮金，浅色压深以通过 4.5:1。
  static const Color ratingStarDark = Color(0xFFFFC107);
  static const Color ratingStarLight = Color(0xFF825400);

  static Color ratingStar(Brightness brightness) =>
      brightness == Brightness.dark ? ratingStarDark : ratingStarLight;

  /// 没有封面时，手机媒体库磁贴轮换的品牌家族渐变。
  static const List<List<Color>> libraryGradients = [
    [Color(0xFF5A2346), Color(0xFF1C0D17)],
    [Color(0xFF3F2F6B), Color(0xFF141022)],
    [Color(0xFF14504A), Color(0xFF0A1C1A)],
    [Color(0xFF5C2A3A), Color(0xFF1C0F16)],
    [Color(0xFF2F3F6B), Color(0xFF101522)],
    [Color(0xFF3A2A5A), Color(0xFF14101E)],
    [Color(0xFF1E3D5A), Color(0xFF0C1520)],
    [Color(0xFF3A3F4A), Color(0xFF14161A)],
  ];
}

/// 品牌渐变。主播放按钮用粉到月光紫；氛围层用粉/青单层四段渐变。
abstract final class AppBrandGradient {
  static const LinearGradient primaryDark = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppBrand.pink, AppBrand.lavender],
  );

  static const LinearGradient primaryLight = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppBrand.pinkDeep, AppBrand.lavenderDeep],
  );

  static LinearGradient primaryFor(Brightness brightness) =>
      brightness == Brightness.dark ? primaryDark : primaryLight;

  /// 首页头图与详情头部的单层氛围渐变。
  ///
  /// 第一个 stop 是剧照 mood 色，第三个 stop 是固定品牌天青；
  /// 色相一致性只比较第一个 stop，青色是品牌光，不随剧照变。
  static LinearGradient ambientFor(
    Brightness brightness,
    Color mood, {
    double alpha = 0.18,
  }) {
    final cyan = brightness == Brightness.dark
        ? AppBrand.cyan
        : AppBrand.cyanDeep;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0, 0.55, 0.78, 1],
      colors: [
        mood.withValues(alpha: alpha),
        AppInk.transparent,
        cyan.withValues(alpha: alpha / 2),
        AppInk.transparent,
      ],
    );
  }
}

/// 中性黑/白/透明。所有遮罩与浮层底色从这里取，避免散落十六进制。
abstract final class AppInk {
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color transparent = Color(0x00000000);

  static Color scrim(double alpha) => black.withValues(alpha: alpha);
}
