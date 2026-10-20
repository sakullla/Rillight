import 'package:flutter/widgets.dart';

import 'brand.dart';

/// 一套主题的全部取色。
///
/// 六套公开 Tones 指向同一套品牌基色（静夜蓝）；桌面/手机/TV 的差异由
/// 字号、密度与焦点表达，不再各自换 hue。表面阶梯是低饱和中性色：
/// 深色为冷石墨，浅色为白底；品牌色相只出现在 accent 与它的容器上。
abstract final class AppPalette {
  static const Tones _brandDark = Tones(
    base: AppBrand.ink,
    surfaceLowest: Color(0xFF111418),
    surfaceLow: Color(0xFF161A1F),
    surface: Color(0xFF1B2026),
    surfaceHigh: Color(0xFF232930),
    surfaceHighest: Color(0xFF2C333B),
    surfaceBright: Color(0xFF363E47),
    onSurface: Color(0xFFF1F4F8),
    onSurfaceVariant: Color(0xFFB7C0CC),
    outline: Color(0xFF8A94A1),
    outlineVariant: Color(0xFF2A3138),
    accent: AppBrand.accent,
    onAccent: AppBrand.onAccent,
    accentContainer: Color(0xFF1D3357),
    onAccentContainer: Color(0xFFD8E5FF),
    secondary: Color(0xFFA9BEDD),
    onSecondary: Color(0xFF12233A),
    secondaryContainer: Color(0xFF26364B),
    onSecondaryContainer: Color(0xFFDCE7F7),
    tertiary: Color(0xFFC2C9D3),
    onTertiary: Color(0xFF1A1F25),
    tertiaryContainer: Color(0xFF2E353E),
    onTertiaryContainer: Color(0xFFE3E8EE),
    error: Color(0xFFF49A90),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5C2320),
    onErrorContainer: Color(0xFFFFD2CD),
    inverseSurface: Color(0xFFF1F4F8),
    onInverseSurface: Color(0xFF14171B),
    inversePrimary: Color(0xFF2F5FB8),
    scrim: AppInk.black,
  );

  static const Tones _brandLight = Tones(
    base: AppBrand.paper,
    surfaceLowest: AppInk.white,
    surfaceLow: AppInk.white,
    surface: Color(0xFFF0F2F5),
    surfaceHigh: Color(0xFFE9ECF0),
    surfaceHighest: Color(0xFFE3E7EC),
    surfaceBright: Color(0xFFDCE1E7),
    onSurface: Color(0xFF121417),
    onSurfaceVariant: Color(0xFF474F59),
    outline: Color(0xFF69717B),
    outlineVariant: Color(0xFFDDE1E6),
    accent: AppBrand.accentDeep,
    onAccent: AppInk.white,
    accentContainer: Color(0xFFDCE7FF),
    onAccentContainer: Color(0xFF0E2A5C),
    secondary: Color(0xFF3A5370),
    onSecondary: AppInk.white,
    secondaryContainer: Color(0xFFDDE5EF),
    onSecondaryContainer: Color(0xFF1A2A3D),
    tertiary: Color(0xFF4D5561),
    onTertiary: AppInk.white,
    tertiaryContainer: Color(0xFFE4E7EB),
    onTertiaryContainer: Color(0xFF22272E),
    error: Color(0xFFB42318),
    onError: AppInk.white,
    errorContainer: Color(0xFFF8D7D4),
    onErrorContainer: Color(0xFF5C1612),
    inverseSurface: Color(0xFF16191D),
    onInverseSurface: Color(0xFFF2F4F7),
    inversePrimary: Color(0xFFA9C4FF),
    scrim: AppInk.black,
  );

  /// 桌面、手机、TV 共享同一套品牌色相。
  static const Tones darkTones = _brandDark;
  static const Tones lightTones = _brandLight;
  static const Tones phoneDarkTones = _brandDark;
  static const Tones phoneLightTones = _brandLight;
  static const Tones tvDarkTones = _brandDark;
  static const Tones tvLightTones = _brandLight;
}

/// AppPalette 的一套完整取色（表面分层/文字/高光/出错）。
///
/// 组件样式在 AppUiThemeData 中按色调生成。浅色额外使用白底、细边和
/// 浮层阴影；正文与控件对比度都不低于 WCAG AA（4.5:1）。
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

  /// 页面底色(最深层)。
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

  /// 品牌强调：主操作、进度、选中与焦点。
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;

  /// 同色系低饱和辅助：少数辅助语义标签。
  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;

  /// 中性第三色：少量标签。
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
