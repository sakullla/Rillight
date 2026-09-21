import 'package:flutter/material.dart';

import 'theme/tokens.dart';

export 'theme/tokens.dart';

/// 应用唯一视觉权威:近黑表面、暖白文字,克制高光仅用于播放/焦点/进度。
///
/// 所有页面与组件应从 [AppTheme.dark] 与 token 类
/// ([AppSpacing] / [AppRadii] / [AppMotion] / [AppBreakpoints]) 取视觉值,
/// 不得散落硬编码颜色。
abstract final class AppTheme {
  // ---- 基础色板(近黑分层 + 暖白文字) ----
  static const Color _base = Color(0xFF0A0A0C);
  static const Color _surfaceLowest = Color(0xFF0F0F12);
  static const Color _surfaceLow = Color(0xFF141418);
  static const Color _surface = Color(0xFF1A1A1F);
  static const Color _surfaceHigh = Color(0xFF202027);
  static const Color _surfaceHighest = Color(0xFF292931);
  static const Color _surfaceBright = Color(0xFF33333C);

  static const Color _onSurface = Color(0xFFF5F2EC);
  static const Color _onSurfaceVariant = Color(0xFFB3AFA6);
  static const Color _outline = Color(0xFF3D3D45);
  static const Color _outlineVariant = Color(0xFF26262C);

  /// 克制高光,只用于播放/焦点/进度,不涂导航与主按钮。
  static const Color _accent = Color(0xFFD8CFC4);
  static const Color _onAccent = Color(0xFF161410);
  static const Color _accentContainer = Color(0xFF2E2B27);
  static const Color _onAccentContainer = Color(0xFFE8E2D8);

  static const Color _secondary = Color(0xFFA8A29A);
  static const Color _tertiary = Color(0xFF8FA3BF);
  static const Color _error = Color(0xFFE8786F);

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _accent,
      onPrimary: _onAccent,
      primaryContainer: _accentContainer,
      onPrimaryContainer: _onAccentContainer,
      secondary: _secondary,
      onSecondary: _onAccent,
      secondaryContainer: Color(0xFF2C2A27),
      onSecondaryContainer: Color(0xFFD8D2C8),
      tertiary: _tertiary,
      onTertiary: Color(0xFF121A26),
      tertiaryContainer: Color(0xFF2C3A4E),
      onTertiaryContainer: Color(0xFFD4E0F2),
      error: _error,
      onError: Color(0xFF2A0A08),
      errorContainer: Color(0xFF5C2320),
      onErrorContainer: Color(0xFFFFD2CD),
      surface: _surfaceLow,
      onSurface: _onSurface,
      onSurfaceVariant: _onSurfaceVariant,
      surfaceDim: _base,
      surfaceBright: _surfaceBright,
      surfaceContainerLowest: _surfaceLowest,
      surfaceContainerLow: _surfaceLow,
      surfaceContainer: _surface,
      surfaceContainerHigh: _surfaceHigh,
      surfaceContainerHighest: _surfaceHighest,
      outline: _outline,
      outlineVariant: _outlineVariant,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: _onSurface,
      onInverseSurface: _surfaceLow,
      inversePrimary: Color(0xFF6F675C),
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
      bodyColor: _onSurface,
      displayColor: _onSurface,
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
      brightness: Brightness.dark,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: _base,
      canvasColor: _base,
      dividerColor: _outlineVariant,
      splashFactory: InkSparkle.splashFactory,
      highlightColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: _base,
        foregroundColor: _onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: _surfaceLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _onSurface,
          foregroundColor: _base,
          disabledBackgroundColor: _surfaceHigh,
          disabledForegroundColor: _onSurfaceVariant,
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
          backgroundColor: _onSurface,
          foregroundColor: _base,
          disabledBackgroundColor: _surfaceHigh,
          disabledForegroundColor: _onSurfaceVariant,
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
          foregroundColor: _onSurface,
          side: const BorderSide(color: _outline),
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
          foregroundColor: _onSurface,
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
        fillColor: _surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        hintStyle: bodyMedium.copyWith(color: _onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: _outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: _accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: _error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: _error, width: 1.5),
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: _accent,
        inactiveTrackColor: _surfaceHighest,
        thumbColor: _accent,
        overlayColor: Color(0x29D8CFC4),
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        showValueIndicator: ShowValueIndicator.never,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
        titleTextStyle: titleLarge,
        contentTextStyle: bodyMedium.copyWith(color: _onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _surfaceHighest,
        contentTextStyle: textTheme.bodyMedium,
        actionTextColor: _onSurface,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: _surfaceHighest,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        // 桌面默认 minHeight 24 + 竖向 4 点内边距会裁切雅黑体;顶栏靠右
        // 时「取消置顶」最后一个字看起来缺笔。
        textStyle: labelMedium.copyWith(
          color: _onSurface,
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
          foregroundColor: _onSurface,
          disabledForegroundColor: _onSurfaceVariant,
        ),
      ),
      // 弹出菜单的唯一样式来源;页面内 PopupMenuButton 不再覆盖
      // color/shape/surfaceTintColor。
      popupMenuTheme: PopupMenuThemeData(
        color: _surfaceHigh.withValues(alpha: 0.94),
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(
            color: Colors.white.withValues(alpha: AppGlass.edgeLight),
          ),
        ),
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _base,
        indicatorColor: _surfaceHigh,
        selectedIconTheme: const IconThemeData(color: _onSurface),
        unselectedIconTheme: const IconThemeData(color: _onSurfaceVariant),
        selectedLabelTextStyle: labelMedium.copyWith(color: _onSurface),
        unselectedLabelTextStyle: labelMedium.copyWith(
          color: _onSurfaceVariant,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: _accent,
        linearTrackColor: _surfaceHighest,
        circularTrackColor: _surfaceHighest,
      ),
    );
  }
}
