import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FctvColors {
  static const background = Color(0xFF10182B);
  static const backgroundDeep = Color(0xFF0B1220);
  static const surface = Color(0xFF1D2029);
  static const surfaceElevated = Color(0xFF242833);
  static const surfaceMuted = Color(0xFF343B4D);
  static const accent = Color(0xFFFFAE01);
  static const live = Color(0xFFE53935);
  static const clock = Color(0xFFFF6F61);
  static const textSecondary = Color(0x99FFFFFF);
  static const textTertiary = Color(0x66FFFFFF);
  static const textMuted = Color(0xFF828A99);
  static const headerStart = Color(0xFF1E2748);
}

ThemeData buildFctvTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: FctvColors.background,
    colorScheme: const ColorScheme.dark(
      primary: FctvColors.accent,
      secondary: FctvColors.accent,
      surface: FctvColors.surface,
      error: FctvColors.live,
    ),
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: GoogleFonts.manropeTextTheme(base.textTheme).apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: GoogleFonts.sora(
        fontWeight: FontWeight.w800,
        fontSize: 20,
        letterSpacing: 1.2,
        color: Colors.white,
      ),
    ),
  );
}
