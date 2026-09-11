import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const Color background = Color(0xFF0B0B0D);
  static const Color surface = Color(0xFF141416);
  static const Color surfaceHigh = Color(0xFF1C1C20);
  static const Color onSurface = Color(0xFFF4F1EA);
  static const Color accent = Color(0xFFE0A15A);

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: Color(0xFF1A1208),
      secondary: Color(0xFFC9A06A),
      onSecondary: Color(0xFF1A1208),
      error: Color(0xFFE07070),
      onError: Color(0xFF1A0A0A),
      surface: surface,
      onSurface: onSurface,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      popupMenuTheme: const PopupMenuThemeData(color: surfaceHigh),
      dividerColor: const Color(0x22FFFFFF),
    );
  }
}
