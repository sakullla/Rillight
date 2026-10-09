import 'package:flutter/material.dart';

import 'theme/tokens.dart';

export 'theme/tokens.dart';

/// 应用唯一视觉权威:冷蓝灰表面 + 清晰文字,克制高光仅用于播放/焦点/进度。
///
/// 所有页面与组件应从 [AppTheme.dark] / [AppTheme.light] 与 token 类
/// ([AppSpacing] / [AppRadii] / [AppMotion] / [AppBreakpoints]) 取视觉值,
/// 不得散落硬编码颜色。
abstract final class AppTheme {
  /// 一套主题的全部取色。浅色/深色共用同一套组件样式,只换色调。
  @visibleForTesting
  static const Tones darkTones = Tones._(
    base: Color(0xFF151A28),
    surfaceLowest: Color(0xFF171D2C),
    surfaceLow: Color(0xFF1D2536),
    surface: Color(0xFF242D40),
    surfaceHigh: Color(0xFF2B354A),
    surfaceHighest: Color(0xFF354158),
    surfaceBright: Color(0xFF414D65),
    onSurface: Color(0xFFF3F5FF),
    onSurfaceVariant: Color(0xFFB9C3D9),
    outline: Color(0xFF78849F),
    outlineVariant: Color(0xFF39445B),
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
    onInverseSurface: Color(0xFF242D40),
    inversePrimary: Color(0xFF5757A8),
    scrim: Colors.black,
  );

  /// 浅色调:清透分层表面 + 深蓝灰文字;正文/控件对比度不低于 4.5:1。
  @visibleForTesting
  static const Tones lightTones = Tones._(
    base: Color(0xFFF6F7FC),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFEEF0F8),
    surfaceHigh: Color(0xFFE7EAF5),
    surfaceHighest: Color(0xFFDDE2F0),
    surfaceBright: Color(0xFFD6DDED),
    onSurface: Color(0xFF22283C),
    onSurfaceVariant: Color(0xFF566079),
    outline: Color(0xFF788299),
    outlineVariant: Color(0xFFD6DCEC),
    accent: Color(0xFF5757A8),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE3E1FF),
    onAccentContainer: Color(0xFF343264),
    secondary: Color(0xFF8E4E6D),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF9DEEA),
    onSecondaryContainer: Color(0xFF63334B),
    tertiary: Color(0xFF306D69),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD2EFEA),
    onTertiaryContainer: Color(0xFF214D49),
    error: Color(0xFFB03A32),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF5D4D0),
    onErrorContainer: Color(0xFF4A120E),
    inverseSurface: Color(0xFF2B354A),
    onInverseSurface: Color(0xFFF3F5FF),
    inversePrimary: Color(0xFFB8B8FF),
    scrim: Colors.black,
  );

  /// 电视深色调:中性石墨底,影像为主角,大屏长时间观看不偏紫不刺眼。
  /// 焦点用反相实底(近白底 + 深字),不依赖品牌色。
  @visibleForTesting
  static const Tones tvDarkTones = Tones._(
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
    scrim: Colors.black,
  );

  /// 电视浅色调:暖灰白底,与深色调同一分层与反相焦点。
  @visibleForTesting
  static const Tones tvLightTones = Tones._(
    base: Color(0xFFF3F4F6),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFEBEDF0),
    surfaceHigh: Color(0xFFE3E5E9),
    surfaceHighest: Color(0xFFD9DCE1),
    surfaceBright: Color(0xFFD0D4DA),
    onSurface: Color(0xFF1A1C20),
    onSurfaceVariant: Color(0xFF555B66),
    outline: Color(0xFF7A808B),
    outlineVariant: Color(0xFFD5D8DE),
    accent: Color(0xFF5757A8),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE3E1FF),
    onAccentContainer: Color(0xFF343264),
    secondary: Color(0xFF8E4E6D),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF9DEEA),
    onSecondaryContainer: Color(0xFF63334B),
    tertiary: Color(0xFF306D69),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD2EFEA),
    onTertiaryContainer: Color(0xFF214D49),
    error: Color(0xFFB03A32),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF5D4D0),
    onErrorContainer: Color(0xFF4A120E),
    inverseSurface: Color(0xFF1A1C20),
    onInverseSurface: Color(0xFFF7F8FA),
    inversePrimary: Color(0xFFB8B8FF),
    scrim: Colors.black,
  );

  /// 冷蓝灰深色主题(默认)。
  static final ThemeData _dark = _theme(darkTones);
  static final ThemeData _tvDark = _theme(tvDarkTones);
  static final ThemeData _tvLight = _theme(tvLightTones);

  /// Android TV 深色/浅色。字号由 TvStageTheme 按 960×540 画布再换算。
  static ThemeData tvDark() => _tvDark;
  static ThemeData tvLight() => _tvLight;
  static final ThemeData _light = _theme(lightTones);
  static final ThemeData _phoneLight = _phone(_light);
  static final ThemeData _phoneDark = _phone(_dark);

  static ThemeData dark() => _dark;

  /// 浅色主题:同一分层结构,只换浅色调。
  static ThemeData light() => _light;

  /// Phone reading sizes and touch targets, with the same cool surface palette.
  static ThemeData phoneLight() => _phoneLight;
  static ThemeData phoneDark() => _phoneDark;

  static ThemeData _phone(ThemeData base) => base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 16,
        height: 1.4,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.4),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(minTileHeight: 56),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(height: 72),
  );

  static ThemeData _theme(Tones t) {
    final scheme = ColorScheme(
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
      shadow: Colors.black,
      scrim: t.scrim,
      inverseSurface: t.inverseSurface,
      onInverseSurface: t.onInverseSurface,
      inversePrimary: t.inversePrimary,
      surfaceTint: Colors.transparent,
    );

    const titleLarge = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: 0,
    );
    const bodyMedium = TextStyle(fontSize: 14, height: 1.45, letterSpacing: 0);
    const labelMedium = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    );

    const baseTextTheme = TextTheme(
      displayLarge: TextStyle(
        fontSize: 44,
        fontWeight: FontWeight.w700,
        height: 1.12,
        letterSpacing: 0,
      ),
      displayMedium: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        height: 1.18,
        letterSpacing: 0,
      ),
      displaySmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        height: 1.22,
        letterSpacing: 0,
      ),
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        height: 1.22,
        letterSpacing: 0,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.28,
        letterSpacing: 0,
      ),
      headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.3,
        letterSpacing: 0,
      ),
      titleLarge: titleLarge,
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: 0,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, letterSpacing: 0),
      bodyMedium: bodyMedium,
      bodySmall: TextStyle(fontSize: 13, height: 1.4, letterSpacing: 0),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: labelMedium,
      labelSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
    );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.md),
    );
    final textTheme = baseTextTheme.apply(
      bodyColor: t.onSurface,
      displayColor: t.onSurface,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans SC',
        'Noto Sans CJK SC',
      ],
    );

    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: t.base,
      canvasColor: t.base,
      dividerColor: t.outlineVariant,
      splashFactory: InkSparkle.splashFactory,
      highlightColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: t.base,
        foregroundColor: t.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: t.surfaceLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.surfaceHigh,
          disabledForegroundColor: t.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
          shape: buttonShape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.surfaceHigh,
          disabledForegroundColor: t.onSurfaceVariant,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.onSurface,
          side: BorderSide(color: t.outline),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.onSurface,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          textStyle: textTheme.labelLarge,
          shape: buttonShape,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: t.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: t.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.error, width: 1.5),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.accent,
        inactiveTrackColor: t.surfaceHighest,
        thumbColor: t.accent,
        overlayColor: t.accent.withValues(alpha: 0.16),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        showValueIndicator: ShowValueIndicator.never,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surfaceLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: t.outlineVariant),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: t.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surfaceHighest,
        contentTextStyle: textTheme.bodyMedium,
        actionTextColor: t.onSurface,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.surfaceHighest,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        // 桌面默认 minHeight 24 + 竖向 4 点内边距会裁切雅黑体;顶栏靠右
        // 时「取消置顶」最后一个字看起来缺笔。
        textStyle: textTheme.labelMedium?.copyWith(
          color: t.onSurface,
          fontWeight: FontWeight.w400,
          height: 1.35,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.symmetric(horizontal: 12),
        constraints: const BoxConstraints(minHeight: 32),
        preferBelow: true,
        waitDuration: const Duration(milliseconds: 400),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: t.onSurface,
          disabledForegroundColor: t.onSurfaceVariant,
        ),
      ),
      // 弹出菜单的唯一样式来源;页面内 PopupMenuButton 不再覆盖
      // color/shape/surfaceTintColor。
      popupMenuTheme: PopupMenuThemeData(
        color: t.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.base,
        indicatorColor: t.accentContainer,
        selectedIconTheme: IconThemeData(color: t.onAccentContainer),
        unselectedIconTheme: IconThemeData(color: t.onSurfaceVariant),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: t.onSurface,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: t.onSurfaceVariant,
        ),
      ),
      // 手机底部导航:透明底 + 胶囊选中指示器;动效时长档走
      // AppMobileNav.pillDuration(NavigationBar.animationDuration 引用)。
      // 桌面 NavigationRail 样式见上方 navigationRailTheme,互不影响。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.base.withValues(alpha: AppMobileNav.backgroundAlpha),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: t.accentContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? t.onAccentContainer
                : t.onSurfaceVariant,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.surfaceHighest,
        circularTrackColor: t.surfaceHighest,
      ),
    );
  }
}

/// [AppTheme] 的一套完整取色(表面分层/文字/高光/出错)。
///
/// 组件样式统一在 [AppTheme._theme] 中按色调生成;浅色与深色的正文
/// 与控件对比度都不低于 WCAG AA(4.5:1)。
@visibleForTesting
class Tones {
  const Tones._({
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
