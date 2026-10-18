import 'package:flutter/widgets.dart';

abstract final class AppPalette {
  /// 一套主题的全部取色。深色组件保持平面;浅色另加细边、白底输入和浮层阴影。
  ///
  /// 桌面深色走"影院墨黑":基色压到近黑的中性墨色,表面阶梯只留一丝冷调,
  /// 让海报和 hero 画面成为页面里唯一的色彩主角。强调色是带光感的蓝紫,
  /// 与粉色次强调组成和图标一致的品牌渐变。浅色纸色主题保持阅读感。
  static const Tones darkTones = Tones(
    base: Color(0xFF0B0D12),
    surfaceLowest: Color(0xFF101319),
    surfaceLow: Color(0xFF14171F),
    surface: Color(0xFF1A1E27),
    surfaceHigh: Color(0xFF21252F),
    surfaceHighest: Color(0xFF292E3A),
    surfaceBright: Color(0xFF363C4A),
    onSurface: Color(0xFFF2F4F8),
    onSurfaceVariant: Color(0xFFA9B0BF),
    outline: Color(0xFF6B7386),
    outlineVariant: Color(0xFF272C37),
    accent: Color(0xFFA99BFF),
    onAccent: Color(0xFF17123D),
    accentContainer: Color(0xFF2C2754),
    onAccentContainer: Color(0xFFE6E0FF),
    secondary: Color(0xFFF2A9CB),
    onSecondary: Color(0xFF471F35),
    secondaryContainer: Color(0xFF4A2A40),
    onSecondaryContainer: Color(0xFFFFD9E9),
    tertiary: Color(0xFF8FD9CF),
    onTertiary: Color(0xFF0F3B37),
    tertiaryContainer: Color(0xFF1F4744),
    onTertiaryContainer: Color(0xFFBDF3EC),
    error: Color(0xFFEE7A70),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5A211E),
    onErrorContainer: Color(0xFFFFD4CF),
    inverseSurface: Color(0xFFF2F4F8),
    onInverseSurface: Color(0xFF171A21),
    inversePrimary: Color(0xFF5546C4),
    scrim: Color(0xFF000000),
  );

  /// 浅色调:纸色页面、白色卡片、墨色文字。分层拉开,正文对比度不低于 4.5:1。
  static const Tones lightTones = Tones(
    base: Color(0xFFF3F5F8),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFE9EDF4),
    surfaceHigh: Color(0xFFDFE5EE),
    surfaceHighest: Color(0xFFD4DBE6),
    surfaceBright: Color(0xFFC7CFD9),
    onSurface: Color(0xFF151A24),
    onSurfaceVariant: Color(0xFF3B4454),
    outline: Color(0xFF5A6475),
    outlineVariant: Color(0xFFD3D8E1),
    accent: Color(0xFF4A3FD1),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE7E4FC),
    onAccentContainer: Color(0xFF221B6B),
    secondary: Color(0xFF8A4564),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF8E4EC),
    onSecondaryContainer: Color(0xFF5C2C42),
    tertiary: Color(0xFF1F6A64),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD7F1ED),
    onTertiaryContainer: Color(0xFF0E3E3A),
    error: Color(0xFFB42318),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF8D7D4),
    onErrorContainer: Color(0xFF5C1612),
    inverseSurface: Color(0xFF1C2433),
    onInverseSurface: Color(0xFFF4F6FA),
    inversePrimary: Color(0xFFC4C6FF),
    scrim: Color(0xFF000000),
  );

  /// 手机深色调:近黑底只带一丝蓝紫,表面阶梯克制,不再整页铺紫粉。
  /// 强调色是樱粉,次强调是蓝紫;错误仍是红色。海报遮罩保持纯黑。
  static const Tones phoneDarkTones = Tones(
    base: Color(0xFF0E0A12),
    surfaceLowest: Color(0xFF141019),
    surfaceLow: Color(0xFF1A1421),
    surface: Color(0xFF211A2A),
    surfaceHigh: Color(0xFF2A2234),
    surfaceHighest: Color(0xFF382A3E),
    surfaceBright: Color(0xFF46384D),
    onSurface: Color(0xFFF7F2F6),
    onSurfaceVariant: Color(0xFFCDBFCB),
    outline: Color(0xFF8C7E8A),
    outlineVariant: Color(0xFF342B3B),
    accent: Color(0xFFF4A3C6),
    onAccent: Color(0xFF3A1124),
    accentContainer: Color(0xFF4F2440),
    onAccentContainer: Color(0xFFFFD9E8),
    secondary: Color(0xFFB6AEFF),
    onSecondary: Color(0xFF1A1440),
    secondaryContainer: Color(0xFF322C5C),
    onSecondaryContainer: Color(0xFFE6E2FF),
    tertiary: Color(0xFFC8B8FF),
    onTertiary: Color(0xFF221448),
    tertiaryContainer: Color(0xFF3C3464),
    onTertiaryContainer: Color(0xFFE8E4FF),
    error: Color(0xFFF08A80),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5C2320),
    onErrorContainer: Color(0xFFFFD2CD),
    inverseSurface: Color(0xFFF7F2F6),
    onInverseSurface: Color(0xFF160E18),
    inversePrimary: Color(0xFFA33D6C),
    scrim: Color(0xFF000000),
  );

  /// 手机浅色调:近白的樱粉纸底、纯白卡片,抬高的表面只带一丝蓝紫。
  /// 底色只保留极淡的粉调,卡片与胶囊靠白底和细边分层,不再整页铺粉。
  /// 强调色是加深的樱粉,与浅色页面对比不低于 4.5:1;次强调是蓝紫。错误仍是红色。
  static const Tones phoneLightTones = Tones(
    base: Color(0xFFFAF1F6),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFF5EAF0),
    surfaceHigh: Color(0xFFECE8FA),
    surfaceHighest: Color(0xFFF3DFE9),
    surfaceBright: Color(0xFFE9D5DF),
    onSurface: Color(0xFF141216),
    onSurfaceVariant: Color(0xFF53464F),
    outline: Color(0xFF6E6570),
    outlineVariant: Color(0xFFEADCE3),
    accent: Color(0xFFB21F54),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFFADDE9),
    onAccentContainer: Color(0xFF5C1E3A),
    secondary: Color(0xFF5446C8),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFEAE6FF),
    onSecondaryContainer: Color(0xFF24185C),
    tertiary: Color(0xFF6A5AD4),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFECE8FF),
    onTertiaryContainer: Color(0xFF24185C),
    error: Color(0xFFB42318),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF8D7D4),
    onErrorContainer: Color(0xFF5C1612),
    inverseSurface: Color(0xFF161218),
    onInverseSurface: Color(0xFFF7F2F5),
    inversePrimary: Color(0xFFF2A8C8),
    scrim: Color(0xFF000000),
  );

  /// 电视深色调:中性石墨底,影像为主角,大屏长时间观看不偏紫不刺眼。
  /// 焦点用反相实底(近白底 + 深字),不依赖品牌色。
  static const Tones tvDarkTones = Tones(
    base: Color(0xFF0B0C0F),
    surfaceLowest: Color(0xFF111317),
    surfaceLow: Color(0xFF15171B),
    surface: Color(0xFF1B1D22),
    surfaceHigh: Color(0xFF22252B),
    surfaceHighest: Color(0xFF2B2E35),
    surfaceBright: Color(0xFF363A42),
    onSurface: Color(0xFFF2F3F5),
    onSurfaceVariant: Color(0xFFA9AEB8),
    outline: Color(0xFF6C717C),
    outlineVariant: Color(0xFF2A2D34),
    accent: Color(0xFFA99BFF),
    onAccent: Color(0xFF17123D),
    accentContainer: Color(0xFF2C2754),
    onAccentContainer: Color(0xFFE6E0FF),
    secondary: Color(0xFFEDB7CD),
    onSecondary: Color(0xFF462437),
    secondaryContainer: Color(0xFF4E3447),
    onSecondaryContainer: Color(0xFFFFDBEA),
    tertiary: Color(0xFF9EDBD5),
    onTertiary: Color(0xFF143C3B),
    tertiaryContainer: Color(0xFF284C4C),
    onTertiaryContainer: Color(0xFFC1F2EC),
    error: Color(0xFFF08A80),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5C2320),
    onErrorContainer: Color(0xFFFFD2CD),
    inverseSurface: Color(0xFFF2F3F5),
    onInverseSurface: Color(0xFF15171C),
    inversePrimary: Color(0xFF5546C4),
    scrim: Color(0xFF000000),
  );

  /// 电视浅色调:与桌面同一套纸色和蓝紫,表面再拉开一档,焦点仍是深底浅字。
  static const Tones tvLightTones = Tones(
    base: Color(0xFFF4F5F7),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFE8EAEE),
    surfaceHigh: Color(0xFFDEE1E6),
    surfaceHighest: Color(0xFFD3D7DE),
    surfaceBright: Color(0xFFC6CBD4),
    onSurface: Color(0xFF14171C),
    onSurfaceVariant: Color(0xFF3C424C),
    outline: Color(0xFF5C636E),
    outlineVariant: Color(0xFFD5D8DE),
    accent: Color(0xFF4A3FD1),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE7E4FC),
    onAccentContainer: Color(0xFF221B6B),
    secondary: Color(0xFF8A4564),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF8E4EC),
    onSecondaryContainer: Color(0xFF5C2C42),
    tertiary: Color(0xFF1F6A64),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD7F1ED),
    onTertiaryContainer: Color(0xFF0E3E3A),
    error: Color(0xFFB42318),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF8D7D4),
    onErrorContainer: Color(0xFF5C1612),
    inverseSurface: Color(0xFF14171C),
    onInverseSurface: Color(0xFFF7F8FA),
    inversePrimary: Color(0xFFC4C6FF),
    scrim: Color(0xFF000000),
  );
}

/// AppPalette 的一套完整取色(表面分层/文字/高光/出错)。
///
/// 组件样式在 AppUiThemeData 中按色调生成。浅色额外使用白底、细边和
/// 浮层阴影;正文与控件对比度都不低于 WCAG AA(4.5:1)。
class Tones {
  const Tones({
    required this.base,
    required this.surfaceLowest,
    required this.surfaceLow,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.surfaceBright,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.inversePrimary,
    required this.scrim,
  });

  /// 页面底色(最深层)。深色蓝灰,浅色近白。
  final Color base;
  final Color surfaceLowest;
  final Color surfaceLow;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceHighest;
  final Color surfaceBright;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;

  /// 品牌蓝紫用于主要操作、选中和播放进度。
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;
  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color tertiary;
  final Color onTertiary;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color inversePrimary;

  /// 叠在海报/画面上的遮罩底色;两种亮度下都保持黑色,画面颜色不变。
  final Color scrim;

  Brightness get brightness =>
      base.computeLuminance() < 0.5 ? Brightness.dark : Brightness.light;
}
