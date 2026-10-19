import 'package:flutter/widgets.dart';

import 'brand.dart';

/// 一套主题的全部取色。
///
/// 六套公开 Tones 指向同一套品牌基色；桌面/手机/TV 的差异由字号、
/// 密度与焦点表达，不再各自换 hue。浅色表面阶梯统一在粉色系，
/// 蓝色只进 secondaryContainer。
abstract final class AppPalette {
  static const Tones _brandDark = Tones(
    base: AppBrand.ink,
    surfaceLowest: Color(0xFF141019),
    surfaceLow: Color(0xFF1A1421),
    surface: Color(0xFF211A2A),
    surfaceHigh: Color(0xFF2A2234),
    surfaceHighest: Color(0xFF382A3E),
    surfaceBright: Color(0xFF46384D),
    onSurface: Color(0xFFF7F2F6),
    onSurfaceVariant: Color(0xFFCDBFCB),
    outline: Color(0xFF9A8C9A),
    outlineVariant: Color(0xFF342B3B),
    accent: AppBrand.pink,
    onAccent: AppBrand.onPink,
    accentContainer: Color(0xFF4F2440),
    onAccentContainer: Color(0xFFFFD9E8),
    secondary: AppBrand.cyan,
    onSecondary: AppBrand.onCyan,
    secondaryContainer: Color(0xFF123A47),
    onSecondaryContainer: Color(0xFFC9F2FF),
    tertiary: AppBrand.lavender,
    onTertiary: AppBrand.onLavender,
    tertiaryContainer: Color(0xFF3C3464),
    onTertiaryContainer: Color(0xFFE8E4FF),
    error: Color(0xFFF49A90),
    onError: Color(0xFF2A0A08),
    errorContainer: Color(0xFF5C2320),
    onErrorContainer: Color(0xFFFFD2CD),
    inverseSurface: Color(0xFFF7F2F6),
    onInverseSurface: Color(0xFF160E18),
    inversePrimary: Color(0xFFA33D6C),
    scrim: AppInk.black,
  );

  static const Tones _brandLight = Tones(
    base: AppBrand.paper,
    surfaceLowest: AppInk.white,
    surfaceLow: AppInk.white,
    surface: Color(0xFFF5EAF0),
    surfaceHigh: Color(0xFFEFE3EA),
    surfaceHighest: Color(0xFFF5DFE9),
    surfaceBright: Color(0xFFEAD3DE),
    onSurface: Color(0xFF141216),
    onSurfaceVariant: Color(0xFF53464F),
    outline: Color(0xFF6E6570),
    outlineVariant: Color(0xFFEADCE3),
    accent: AppBrand.pinkDeep,
    onAccent: AppInk.white,
    accentContainer: Color(0xFFFADDE9),
    onAccentContainer: Color(0xFF5C1E3A),
    secondary: AppBrand.cyanDeep,
    onSecondary: AppInk.white,
    secondaryContainer: Color(0xFFD6F0F7),
    onSecondaryContainer: Color(0xFF083344),
    tertiary: AppBrand.lavenderDeep,
    onTertiary: AppInk.white,
    tertiaryContainer: Color(0xFFECE8FF),
    onTertiaryContainer: Color(0xFF24185C),
    error: Color(0xFFB42318),
    onError: AppInk.white,
    errorContainer: Color(0xFFF8D7D4),
    onErrorContainer: Color(0xFF5C1612),
    inverseSurface: Color(0xFF161218),
    onInverseSurface: Color(0xFFF7F2F5),
    inversePrimary: Color(0xFFF2A8C8),
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

  /// 樱花粉主强调：主操作、进度、选中。
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;

  /// 天青辅助：链接、缓冲、次级高亮。
  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;

  /// 月光紫第三色：少量标签。
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
