import 'package:flutter/material.dart';

class AppColors {
  static const bg0 = Color(0xFF0A0E16);
  static const bg1 = Color(0xFF101624);
  static const surface = Color(0xFF151C2B);
  static const surfaceHigh = Color(0xFF1C2537);
  static const outline = Color(0xFF283349);
  static const amber = Color(0xFFFFB547);
  static const orange = Color(0xFFFF7A3D);
  static const teal = Color(0xFF3DDBC5);
  static const danger = Color(0xFFFF5A6E);
  static const success = Color(0xFF4ADE80);
  static const warning = Color(0xFFFACC15);
  static const text = Color(0xFFF2F5FA);
  static const textDim = Color(0xFF97A2B6);
  static const textFaint = Color(0xFF5F6B82);
  static const onAmber = Color(0xFF231503);

  static const List<Color> avatarPalette = [
    Color(0xFFFFB547),
    Color(0xFF3DDBC5),
    Color(0xFFA78BFA),
    Color(0xFFFF7AB6),
    Color(0xFF60A5FA),
    Color(0xFF4ADE80),
  ];

  static Color avatarFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return avatarPalette[h % avatarPalette.length];
  }
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.amber,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.amber,
    onPrimary: AppColors.onAmber,
    secondary: AppColors.teal,
    onSecondary: const Color(0xFF032621),
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
    outline: AppColors.outline,
  );
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
  );
  final radius = BorderRadius.circular(16);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg0,
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.amber, width: 1.6),
      ),
      hintStyle: const TextStyle(color: AppColors.textFaint),
      prefixIconColor: AppColors.textDim,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: TextStyle(
        color: AppColors.text,
        fontWeight: FontWeight.w600,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      showDragHandle: true,
    ),
    dividerColor: AppColors.outline,
  );
}
