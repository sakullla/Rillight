import 'package:flutter/widgets.dart';

abstract final class AppPalette {
  /// 一套主题的全部取色。深色组件保持平面;浅色另加细边、白底输入和浮层阴影。
  ///
  /// 桌面深色走"影院墨黑":基色压到近黑的冷调墨蓝,表面阶梯只留轻微蓝紫,
  /// 让海报和 hero 画面成为页面里唯一的色彩主角。浅色纸色主题保持阅读感。
  static const Tones darkTones = Tones(
    base: Color(0xFF0F131B),
    surfaceLowest: Color(0xFF121722),
    surfaceLow: Color(0xFF171C29),
    surface: Color(0xFF1D2333),
    surfaceHigh: Color(0xFF242B3E),
    surfaceHighest: Color(0xFF2C354B),
    surfaceBright: Color(0xFF39445E),
    onSurface: Color(0xFFF3F5FF),
    onSurfaceVariant: Color(0xFFB4BFD4),
    outline: Color(0xFF76829C),
    outlineVariant: Color(0xFF323C50),
    accent: Color(0xFFB8B8FF),
    onAccent: Color(0xFF242052),
    accentContainer: Color(0xFF37355F),
    onAccentContainer: Color(0xFFE4DFFF),
    secondary: Color(0xFFEDB7CD),
    onSecondary: Color(0xFF462437),
    secondaryContainer: Color(0xFF4E3447),
    onSecondaryContainer: Color(0xFFFFDBEA),
    tertiary: Color(0xFF9EDBD5),
    onTertiary: Color(0xFF143C3B),
    tertiaryContainer: Color(0xFF284C4C),
    onTertiaryContainer: Color(0xFFC1F2EC),
    error: Color(0xFFE8786F),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5C2320),
    onErrorContainer: Color(0xFFFFD2CD),
    inverseSurface: Color(0xFFF3F5FF),
    onInverseSurface: Color(0xFF1D2333),
    inversePrimary: Color(0xFF5757A8),
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
    outlineVariant: Color(0xFFCDD4DF),
    accent: Color(0xFF3A42B0),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE4E6F8),
    onAccentContainer: Color(0xFF1E2468),
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

  /// 手机深色调:近黑底带轻微蓝紫,抬高的表面再带樱粉。
  /// 强调色是樱粉,次强调是蓝紫;错误仍是红色。海报遮罩保持纯黑。
  static const Tones phoneDarkTones = Tones(
    base: Color(0xFF140C18),
    surfaceLowest: Color(0xFF1A1220),
    surfaceLow: Color(0xFF221830),
    surface: Color(0xFF2A1E38),
    surfaceHigh: Color(0xFF342848),
    surfaceHighest: Color(0xFF523044),
    surfaceBright: Color(0xFF5C3C54),
    onSurface: Color(0xFFF7F2F6),
    onSurfaceVariant: Color(0xFFD0BCC8),
    outline: Color(0xFF8E7C88),
    outlineVariant: Color(0xFF3C3048),
    accent: Color(0xFFF2A8C8),
    onAccent: Color(0xFF3A1224),
    accentContainer: Color(0xFF5E2846),
    onAccentContainer: Color(0xFFFFD8E8),
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
    base: Color(0xFF0E1014),
    surfaceLowest: Color(0xFF121419),
    surfaceLow: Color(0xFF171A20),
    surface: Color(0xFF1D2027),
    surfaceHigh: Color(0xFF24282F),
    surfaceHighest: Color(0xFF2D3139),
    surfaceBright: Color(0xFF383D46),
    onSurface: Color(0xFFF2F3F5),
    onSurfaceVariant: Color(0xFFA9AFBA),
    outline: Color(0xFF6E7480),
    outlineVariant: Color(0xFF2E323A),
    accent: Color(0xFFB8B8FF),
    onAccent: Color(0xFF242052),
    accentContainer: Color(0xFF37355F),
    onAccentContainer: Color(0xFFE4DFFF),
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
    inversePrimary: Color(0xFF5757A8),
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
    accent: Color(0xFF3A42B0),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE4E6F8),
    onAccentContainer: Color(0xFF1E2468),
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
