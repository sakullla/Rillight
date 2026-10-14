import 'package:flutter/material.dart';

import 'theme/tokens.dart';
import 'theme/palette.dart';

export 'theme/tokens.dart';
export 'theme/palette.dart';

/// 应用唯一视觉权威。深色是冷蓝灰;浅色是日光画廊:中性纸色页面、
/// 白卡片、墨色文字,蓝紫只用于播放、焦点和主操作。
///
/// 所有页面与组件应从 [AppTheme.dark] / [AppTheme.light] 与 token 类
/// ([AppSpacing] / [AppRadii] / [AppMotion] / [AppBreakpoints]) 取视觉值,
/// 不得散落硬编码颜色。
abstract final class AppTheme {
  static const darkTones = AppPalette.darkTones;
  static const lightTones = AppPalette.lightTones;
  static const tvDarkTones = AppPalette.tvDarkTones;
  static const tvLightTones = AppPalette.tvLightTones;

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

  /// 浅色主题:纸色页面,白卡片带细边,主操作使用蓝紫。
  static ThemeData light() => _light;

  /// 桌面窗口边框用页面色,标题符号用正文色。
  static (Color page, Color symbol) windowChromeColors(Brightness brightness) {
    final tones = brightness == Brightness.dark ? darkTones : lightTones;
    return (tones.base, tones.onSurface);
  }

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
    filledButtonTheme: FilledButtonThemeData(
      style: _phoneTouchTarget(base.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _phoneTouchTarget(base.elevatedButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _phoneTouchTarget(base.outlinedButtonTheme.style),
    ),
  );

  /// Phone primary buttons stay a 48dp target even when the label is short.
  static ButtonStyle _phoneTouchTarget(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
  }

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
    final light = t.brightness == Brightness.light;
    final hairline = BorderSide(color: t.outlineVariant);

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
        color: light ? t.surfaceLowest : t.surfaceLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: light ? hairline : BorderSide.none,
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
        fillColor: light ? t.surfaceLowest : t.surface,
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
        backgroundColor: light ? t.surfaceLowest : t.surfaceLow,
        surfaceTintColor: Colors.transparent,
        elevation: light ? 16 : 0,
        shadowColor: light ? Colors.black.withValues(alpha: 0.14) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: hairline,
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: t.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: light ? t.inverseSurface : t.surfaceHighest,
        contentTextStyle: light
            ? textTheme.bodyMedium?.copyWith(color: t.onInverseSurface)
            : textTheme.bodyMedium,
        actionTextColor: light ? t.inversePrimary : t.onSurface,
        behavior: SnackBarBehavior.floating,
        elevation: light ? 2 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: light ? t.surfaceLowest : t.surfaceHighest,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: light ? Border.all(color: t.outlineVariant) : null,
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
          hoverColor: light ? t.onSurface.withValues(alpha: 0.06) : null,
        ),
      ),
      // 弹出菜单的唯一样式来源;页面内 PopupMenuButton 不再覆盖
      // color/shape/surfaceTintColor。浅色用白底细边和轻阴影,深色保持抬高表面。
      popupMenuTheme: PopupMenuThemeData(
        color: light ? t.surfaceLowest : t.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: light ? 12 : 6,
        shadowColor: Colors.black.withValues(alpha: light ? 0.12 : 0.36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          side: light ? hairline : BorderSide.none,
        ),
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      ),
      menuTheme: light
          ? MenuThemeData(
              style: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(t.surfaceLowest),
                surfaceTintColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                elevation: const WidgetStatePropertyAll(12),
                shadowColor: WidgetStatePropertyAll(
                  Colors.black.withValues(alpha: 0.12),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    side: hairline,
                  ),
                ),
              ),
            )
          : null,
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
