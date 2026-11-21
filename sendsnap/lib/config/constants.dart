import 'package:flutter/material.dart';

class AppColors {
  // Style A: Clean Comic / Marker Sketch Palette (Sumi Ink & Vibrant Markers on Warm Paper)
  static const Color primary = Color(0xFF2B50EC);        // Cobalt Marker Blue
  static const Color primaryDark = Color(0xFF1D39B8);    // Deep Cobalt Ink
  static const Color primaryLight = Color(0xFF5B7BFF);   // Soft Periwinkle Marker
  static const Color secondary = Color(0xFF00B8D9);      // Cyan Marker Highlight
  static const Color accent = Color(0xFFFFB800);         // Warm Marker Yellow

  static const Color receivePrimary = Color(0xFF159960); // Marker Emerald Green
  static const Color receiveSecondary = Color(0xFF22C55E);// Mint Marker

  static const Color background = Color(0xFFFAF6EE);     // Warm Sketchbook Paper
  static const Color surface = Color(0xFFFFFDF8);        // Crisp Sketch Card Paper
  static const Color ink = Color(0xFF1A1917);            // Sumi Charcoal Ink Outline
  static const Color chalkInk = Color(0xFFEAE3D5);       // Dark-Mode Chalk Ink Outline

  static const Color textPrimary = Color(0xFF1A1917);    // Sumi Charcoal Ink
  static const Color textSecondary = Color(0xFF5C5852);  // Graphite Pencil Grey
  static const Color textMuted = Color(0xFF8C857B);      // Muted Warm Grey

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color textPrimaryOf(BuildContext context) =>
      isDark(context) ? const Color(0xFFF3F5F8) : textPrimary;

  static Color textSecondaryOf(BuildContext context) =>
      isDark(context) ? const Color(0xFFA8B0C2) : textSecondary;

  static Color backgroundOf(BuildContext context) =>
      isDark(context) ? const Color(0xFF14161C) : background;

  static Color surfaceOf(BuildContext context) =>
      isDark(context) ? const Color(0xFF1E232E) : surface;

  static Color subtleFillOf(BuildContext context) =>
      isDark(context)
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.04);

  static Color subtleBorderOf(BuildContext context) =>
      isDark(context)
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.08);

  static Color inkOf(BuildContext context) =>
      isDark(context) ? chalkInk : ink;

  static const Color success = Color(0xFF159960);        // Marker Emerald
  static const Color error = Color(0xFFE04F3E);          // Vermilion Marker Red
  static const Color warning = Color(0xFFE68A00);        // Ochre Marker Orange

  // Marker Fill Gradients (Flat-feel vibrant marker washes)
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF2B50EC), Color(0xFF3B66FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient sendGradient = LinearGradient(
    colors: [Color(0xFF2B50EC), Color(0xFF3E68FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient receiveGradient = LinearGradient(
    colors: [Color(0xFF159960), Color(0xFF1DB574)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient glassHighlight = LinearGradient(
    colors: [Color(0xFFFFFDF8), Color(0xFFF4EFE4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class AppSpacing {
  static const double xs = 4.0;
  static const double s = 8.0;
  static const double m = 16.0;
  static const double l = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
}

class AppConstants {
  static const String websiteUrl = 'https://youssef0356.github.io/sendsnap_website/';
  static const String githubUrl = 'https://github.com/Youssef0356/SendSnap';
  static const String feedbackEmail = 'nejiyoussef081@gmail.com';
  static const String pagelitPackageName = 'com.the356company.pagelit';
  static const String pagelitPlayStoreUrl = 'https://play.google.com/store/apps/details?id=com.the356company.pagelit';
}
