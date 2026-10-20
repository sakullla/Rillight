import 'package:cupertino_ui/cupertino_ui.dart';

import '../theme/brand.dart';
import '../theme/palette.dart';

/// Shared theme for desktop, phone and television interaction trees.
class AppUiThemeData {
  AppUiThemeData({
    required this.colorScheme,
    this.tv = false,
    this.phone = false,
    AppTextTheme? textTheme,
    Color? scaffoldBackgroundColor,
  }) : textTheme = textTheme ?? AppTextTheme.standard(colorScheme.onSurface),
       scaffoldBackgroundColor =
           scaffoldBackgroundColor ?? colorScheme.surfaceDim;

  factory AppUiThemeData.fromTones(Tones tones, {bool phone = false}) =>
      AppUiThemeData(
        colorScheme: AppColorScheme.fromTones(tones),
        phone: phone,
        textTheme: AppTextTheme.standard(tones.onSurface, phone: phone),
      );

  final bool tv;

  /// 手机交互树的主题(影院黑/纸白取色与手机字阶)。
  final bool phone;
  final AppColorScheme colorScheme;
  final AppTextTheme textTheme;
  final Color scaffoldBackgroundColor;
  Brightness get brightness => colorScheme.brightness;
  Color get dividerColor => colorScheme.outlineVariant;
  Color get canvasColor => scaffoldBackgroundColor;
  Color get disabledColor => colorScheme.onSurfaceVariant.withValues(alpha: .5);

  AppUiThemeData copyWith({
    bool? tv,
    bool? phone,
    AppColorScheme? colorScheme,
    AppTextTheme? textTheme,
    Color? scaffoldBackgroundColor,
  }) => AppUiThemeData(
    tv: tv ?? this.tv,
    phone: phone ?? this.phone,
    colorScheme: colorScheme ?? this.colorScheme,
    textTheme: textTheme ?? this.textTheme,
    scaffoldBackgroundColor:
        scaffoldBackgroundColor ?? this.scaffoldBackgroundColor,
  );

  CupertinoThemeData get cupertino => CupertinoThemeData(
    brightness: brightness,
    primaryColor: colorScheme.primary,
    primaryContrastingColor: colorScheme.onPrimary,
    scaffoldBackgroundColor: scaffoldBackgroundColor,
    // 手机导航栏与页面同色、略透明，滚动内容从下面隐约透出。
    barBackgroundColor: phone
        ? scaffoldBackgroundColor.withValues(alpha: .94)
        : colorScheme.surfaceContainerLow,
    textTheme: CupertinoTextThemeData(
      primaryColor: colorScheme.primary,
      textStyle: textTheme.bodyMedium!,
      actionTextStyle: textTheme.labelLarge!.copyWith(
        color: colorScheme.primary,
      ),
      navTitleTextStyle: textTheme.titleMedium!.copyWith(inherit: false),
      navLargeTitleTextStyle: textTheme.displaySmall!.copyWith(inherit: false),
      navActionTextStyle: textTheme.labelLarge!.copyWith(
        inherit: false,
        color: colorScheme.primary,
      ),
      tabLabelTextStyle: textTheme.labelSmall!,
    ),
  );
}

class AppUiTheme extends StatelessWidget {
  static const darkTones = AppPalette.darkTones;
  static const lightTones = AppPalette.lightTones;
  static const tvDarkTones = AppPalette.tvDarkTones;
  static const tvLightTones = AppPalette.tvLightTones;
  static (Color page, Color symbol) windowChromeColors(Brightness brightness) {
    final tones = brightness == Brightness.dark ? darkTones : lightTones;
    return (tones.base, tones.onSurface);
  }

  const AppUiTheme({super.key, required this.data, required this.child});
  final AppUiThemeData data;
  final Widget child;

  static final AppUiThemeData _dark = AppUiThemeData.fromTones(
    AppPalette.darkTones,
  );
  static final AppUiThemeData _light = AppUiThemeData.fromTones(
    AppPalette.lightTones,
  );
  static AppUiThemeData dark() => _dark;
  static AppUiThemeData light() => _light;
  static final AppUiThemeData _phoneDark = AppUiThemeData.fromTones(
    AppPalette.phoneDarkTones,
    phone: true,
  );
  static final AppUiThemeData _phoneLight = AppUiThemeData.fromTones(
    AppPalette.phoneLightTones,
    phone: true,
  );
  static AppUiThemeData phoneDark() => _phoneDark;
  static AppUiThemeData phoneLight() => _phoneLight;
  static AppUiThemeData tvDark() =>
      AppUiThemeData.fromTones(AppPalette.tvDarkTones);
  static AppUiThemeData tvLight() =>
      AppUiThemeData.fromTones(AppPalette.tvLightTones);

  static AppUiThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UiThemeScope>()?.data;
  static AppUiThemeData of(BuildContext context) =>
      maybeOf(context) ??
      (CupertinoTheme.brightnessOf(context) == Brightness.light
          ? light()
          : dark());

  @override
  Widget build(BuildContext context) => _UiThemeScope(
    data: data,
    child: CupertinoTheme(
      data: data.cupertino,
      child: DefaultTextStyle(
        style: data.textTheme.bodyMedium!,
        child: IconTheme(
          data: IconThemeData(color: data.colorScheme.onSurface),
          child: child,
        ),
      ),
    ),
  );
}

class _UiThemeScope extends InheritedWidget {
  const _UiThemeScope({required this.data, required super.child});
  final AppUiThemeData data;
  @override
  bool updateShouldNotify(_UiThemeScope oldWidget) => data != oldWidget.data;
}

/// Application colors independent of any design-system implementation.
class AppColorScheme {
  const AppColorScheme({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
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
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.surfaceDim,
    required this.surfaceBright,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.outline,
    required this.outlineVariant,
    required this.scrim,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.inversePrimary,
    required this.shadow,
    required this.surfaceTint,
  });
  final Brightness brightness;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
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
  final Color surface;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color surfaceDim;
  final Color surfaceBright;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color outline;
  final Color outlineVariant;
  final Color scrim;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color inversePrimary;
  final Color shadow;
  final Color surfaceTint;
  factory AppColorScheme.fromTones(Tones t) => AppColorScheme(
    brightness: t.brightness,
    primary: t.accent,
    onPrimary: t.onAccent,
    primaryContainer: t.accentContainer,
    onPrimaryContainer: t.onAccentContainer,
    secondary: t.secondary,
    onSecondary: t.onSecondary,
    secondaryContainer: t.secondaryContainer,
    onSecondaryContainer: t.onSecondaryContainer,
    tertiary: t.tertiary,
    onTertiary: t.onTertiary,
    tertiaryContainer: t.tertiaryContainer,
    onTertiaryContainer: t.onTertiaryContainer,
    error: t.error,
    onError: t.onError,
    errorContainer: t.errorContainer,
    onErrorContainer: t.onErrorContainer,
    surface: t.surfaceLow,
    onSurface: t.onSurface,
    onSurfaceVariant: t.onSurfaceVariant,
    surfaceDim: t.base,
    surfaceBright: t.surfaceBright,
    surfaceContainerLowest: t.surfaceLowest,
    surfaceContainerLow: t.surfaceLow,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surfaceHigh,
    surfaceContainerHighest: t.surfaceHighest,
    outline: t.outline,
    outlineVariant: t.outlineVariant,
    scrim: t.scrim,
    inverseSurface: t.inverseSurface,
    onInverseSurface: t.onInverseSurface,
    inversePrimary: t.inversePrimary,
    shadow: t.scrim,
    surfaceTint: AppInk.transparent,
  );
  AppColorScheme copyWith({
    Brightness? brightness,
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? secondary,
    Color? onSecondary,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? error,
    Color? onError,
    Color? errorContainer,
    Color? onErrorContainer,
    Color? surface,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? outline,
    Color? outlineVariant,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? shadow,
    Color? surfaceTint,
  }) => AppColorScheme(
    brightness: brightness ?? this.brightness,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    primaryContainer: primaryContainer ?? this.primaryContainer,
    onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
    secondary: secondary ?? this.secondary,
    onSecondary: onSecondary ?? this.onSecondary,
    secondaryContainer: secondaryContainer ?? this.secondaryContainer,
    onSecondaryContainer: onSecondaryContainer ?? this.onSecondaryContainer,
    tertiary: tertiary ?? this.tertiary,
    onTertiary: onTertiary ?? this.onTertiary,
    tertiaryContainer: tertiaryContainer ?? this.tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer ?? this.onTertiaryContainer,
    error: error ?? this.error,
    onError: onError ?? this.onError,
    errorContainer: errorContainer ?? this.errorContainer,
    onErrorContainer: onErrorContainer ?? this.onErrorContainer,
    surface: surface ?? this.surface,
    onSurface: onSurface ?? this.onSurface,
    onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
    surfaceDim: surfaceDim ?? this.surfaceDim,
    surfaceBright: surfaceBright ?? this.surfaceBright,
    surfaceContainerLowest:
        surfaceContainerLowest ?? this.surfaceContainerLowest,
    surfaceContainerLow: surfaceContainerLow ?? this.surfaceContainerLow,
    surfaceContainer: surfaceContainer ?? this.surfaceContainer,
    surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
    surfaceContainerHighest:
        surfaceContainerHighest ?? this.surfaceContainerHighest,
    outline: outline ?? this.outline,
    outlineVariant: outlineVariant ?? this.outlineVariant,
    scrim: scrim ?? this.scrim,
    inverseSurface: inverseSurface ?? this.inverseSurface,
    onInverseSurface: onInverseSurface ?? this.onInverseSurface,
    inversePrimary: inversePrimary ?? this.inversePrimary,
    shadow: shadow ?? this.shadow,
    surfaceTint: surfaceTint ?? this.surfaceTint,
  );

  /// Blend only the 7 fields artwork is allowed to tint. Actions, containers,
  /// selection and text switch instantly so tinted buttons never lag a poster.
  static AppColorScheme lerpSurfaces(
    AppColorScheme a,
    AppColorScheme b,
    double t,
  ) => a.copyWith(
    surface: Color.lerp(a.surface, b.surface, t)!,
    surfaceContainerLowest: Color.lerp(
      a.surfaceContainerLowest,
      b.surfaceContainerLowest,
      t,
    )!,
    surfaceContainerLow: Color.lerp(
      a.surfaceContainerLow,
      b.surfaceContainerLow,
      t,
    )!,
    surfaceContainer: Color.lerp(a.surfaceContainer, b.surfaceContainer, t)!,
    surfaceContainerHigh: Color.lerp(
      a.surfaceContainerHigh,
      b.surfaceContainerHigh,
      t,
    )!,
    surfaceContainerHighest: Color.lerp(
      a.surfaceContainerHighest,
      b.surfaceContainerHighest,
      t,
    )!,
    surfaceBright: Color.lerp(a.surfaceBright, b.surfaceBright, t)!,
  );
}

class AppTextTheme {
  const AppTextTheme({
    this.displayLarge,
    this.displayMedium,
    this.displaySmall,
    this.headlineLarge,
    this.headlineMedium,
    this.headlineSmall,
    this.titleLarge,
    this.titleMedium,
    this.titleSmall,
    this.bodyLarge,
    this.bodyMedium,
    this.bodySmall,
    this.labelLarge,
    this.labelMedium,
    this.labelSmall,
  });
  final TextStyle? displayLarge;
  final TextStyle? displayMedium;
  final TextStyle? displaySmall;
  final TextStyle? headlineLarge;
  final TextStyle? headlineMedium;
  final TextStyle? headlineSmall;
  final TextStyle? titleLarge;
  final TextStyle? titleMedium;
  final TextStyle? titleSmall;
  final TextStyle? bodyLarge;
  final TextStyle? bodyMedium;
  final TextStyle? bodySmall;
  final TextStyle? labelLarge;
  final TextStyle? labelMedium;
  final TextStyle? labelSmall;

  /// 字阶靠字号和颜色分层,粗体只留给标题。
  ///
  /// 微软雅黑只有常规与粗体两档:w600 及以上落到粗体,w500 及以下落到常规。
  /// 因此卡片标题、按钮、标签用 w500(Windows 上是常规、Android/macOS 上是中黑),
  /// 只有页面与分区标题、实底主按钮用 w600/w700。大字号收紧字距,让标题更挺括。
  factory AppTextTheme.standard(Color color, {bool phone = false}) {
    TextStyle style(
      double size,
      FontWeight weight,
      double height, [
      double letterSpacing = 0,
    ]) => TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      fontFamily: "Segoe UI",
      fontFamilyFallback: const [
        "Microsoft YaHei UI",
        "PingFang SC",
        "Noto Sans SC",
        "Noto Sans CJK SC",
      ],
    );
    return AppTextTheme(
      displayLarge: style(44, FontWeight.w700, 1.1, -0.8),
      displayMedium: style(36, FontWeight.w700, 1.14, -0.6),
      displaySmall: style(28, FontWeight.w600, 1.2, -0.3),
      headlineLarge: style(28, FontWeight.w600, 1.2, -0.3),
      headlineMedium: style(22, FontWeight.w600, 1.27, -0.2),
      headlineSmall: style(20, FontWeight.w600, 1.3, -0.1),
      titleLarge: style(phone ? 22 : 20, FontWeight.w600, 1.28, -0.2),
      // titleMedium 是各页的分区标题,保持粗体;卡片标题用 titleSmall。
      titleMedium: style(phone ? 17 : 16, FontWeight.w600, 1.34),
      titleSmall: style(phone ? 15 : 14, FontWeight.w500, 1.34),
      bodyLarge: style(phone ? 16 : 16, FontWeight.w400, 1.5),
      bodyMedium: style(phone ? 15 : 14, FontWeight.w400, 1.45),
      bodySmall: style(13, FontWeight.w400, 1.4),
      labelLarge: style(14, FontWeight.w500, 1.2),
      labelMedium: style(13, FontWeight.w500, 1.2),
      labelSmall: style(12, FontWeight.w500, 1.2, 0.1),
    );
  }
  AppTextTheme copyWith({
    TextStyle? displayLarge,
    TextStyle? displayMedium,
    TextStyle? displaySmall,
    TextStyle? headlineLarge,
    TextStyle? headlineMedium,
    TextStyle? headlineSmall,
    TextStyle? titleLarge,
    TextStyle? titleMedium,
    TextStyle? titleSmall,
    TextStyle? bodyLarge,
    TextStyle? bodyMedium,
    TextStyle? bodySmall,
    TextStyle? labelLarge,
    TextStyle? labelMedium,
    TextStyle? labelSmall,
  }) => AppTextTheme(
    displayLarge: displayLarge ?? this.displayLarge,
    displayMedium: displayMedium ?? this.displayMedium,
    displaySmall: displaySmall ?? this.displaySmall,
    headlineLarge: headlineLarge ?? this.headlineLarge,
    headlineMedium: headlineMedium ?? this.headlineMedium,
    headlineSmall: headlineSmall ?? this.headlineSmall,
    titleLarge: titleLarge ?? this.titleLarge,
    titleMedium: titleMedium ?? this.titleMedium,
    titleSmall: titleSmall ?? this.titleSmall,
    bodyLarge: bodyLarge ?? this.bodyLarge,
    bodyMedium: bodyMedium ?? this.bodyMedium,
    bodySmall: bodySmall ?? this.bodySmall,
    labelLarge: labelLarge ?? this.labelLarge,
    labelMedium: labelMedium ?? this.labelMedium,
    labelSmall: labelSmall ?? this.labelSmall,
  );
  AppTextTheme apply({
    Color? bodyColor,
    Color? displayColor,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double fontSizeFactor = 1,
    double fontSizeDelta = 0,
  }) => AppTextTheme(
    displayLarge: displayLarge?.apply(
      color: displayColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    displayMedium: displayMedium?.apply(
      color: displayColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    displaySmall: displaySmall?.apply(
      color: displayColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    headlineLarge: headlineLarge?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    headlineMedium: headlineMedium?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    headlineSmall: headlineSmall?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    titleLarge: titleLarge?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    titleMedium: titleMedium?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    titleSmall: titleSmall?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    bodyLarge: bodyLarge?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    bodyMedium: bodyMedium?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    bodySmall: bodySmall?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    labelLarge: labelLarge?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    labelMedium: labelMedium?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
    labelSmall: labelSmall?.apply(
      color: bodyColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSizeFactor: fontSizeFactor,
      fontSizeDelta: fontSizeDelta,
    ),
  );
}
