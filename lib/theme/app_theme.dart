// app_theme.dart
//
// The "drafting table" design system: the document is the hero on a calm canvas,
// one confident accent (Blueprint Cyan), precise type (Space Grotesk display +
// Inter body). Encodes the visual identity as light/dark ThemeData.
//
// Fonts: declare 'Inter' and 'Space Grotesk' in pubspec.yaml (bundle the .ttf
// files or wire google_fonts). If absent, Flutter falls back gracefully.

import 'package:flutter/material.dart';

/// Brand + surface tokens. Annotation/marker colors live in [markerPalette].
abstract final class AppColors {
  // Brand neutrals
  static const ink = Color(0xFF16243B); // brand / primary text
  static const ink2 = Color(0xFF33415A);
  static const muted = Color(0xFF6B7787);
  static const hairline = Color(0xFFE4E6EA);

  // Accent
  static const cyan = Color(0xFF0E9FB4); // the single accent
  static const cyanDark = Color(0xFF0B7E8F);
  static const cyanBright = Color(0xFF2BB7CC); // accent on dark

  // Reading surfaces
  static const paper = Color(0xFFFCFCFA);
  static const sepia = Color(0xFFF4ECD8);
  static const canvas = Color(0xFFECEEF1); // light app background

  // Dark theme
  static const slate = Color(0xFF0E1620);
  static const slateSurface = Color(0xFF16202C);
  static const slateSurface2 = Color(0xFF1E2A38);
  static const slateLine = Color(0xFF27343F);
  static const slateText = Color(0xFFE7ECF2);
  static const slateMuted = Color(0xFF8A98A8);
  static const slatePaper = Color(0xFF13202C); // night reading page

  static const danger = Color(0xFFE24B4A);

  /// Ink/marker colors offered in the instrument dock (ARGB ints).
  static const markerPalette = <int>[
    0xFF0E9FB4, // cyan
    0xFFE5604A, // coral (red pen)
    0xFFF6A623, // amber (highlighter)
    0xFF6C5CE0, // violet
    0xFF16243B, // ink
  ];
}

/// Page background per reading mode.
enum ReadingMode { paper, sepia, night }

extension ReadingModeSurface on ReadingMode {
  Color get pageColor => switch (this) {
        ReadingMode.paper => AppColors.paper,
        ReadingMode.sepia => AppColors.sepia,
        ReadingMode.night => AppColors.slatePaper,
      };

  Color get canvasColor => switch (this) {
        ReadingMode.paper => AppColors.canvas,
        ReadingMode.sepia => const Color(0xFFEDE4CE),
        ReadingMode.night => AppColors.slate,
      };

  /// Filter applied to the rendered page ONLY (overlays keep true colors).
  /// Sepia warms the page; night inverts luminance so white pages read dark.
  ColorFilter? get pageFilter => switch (this) {
        ReadingMode.paper => null,
        ReadingMode.sepia => const ColorFilter.matrix(_sepiaMatrix),
        ReadingMode.night => const ColorFilter.matrix(_invertMatrix),
      };

  String get label => switch (this) {
        ReadingMode.paper => 'Paper',
        ReadingMode.sepia => 'Sepia',
        ReadingMode.night => 'Night',
      };

  ReadingMode get next => switch (this) {
        ReadingMode.paper => ReadingMode.sepia,
        ReadingMode.sepia => ReadingMode.night,
        ReadingMode.night => ReadingMode.paper,
      };
}

const List<double> _sepiaMatrix = <double>[
  0.393, 0.769, 0.189, 0, 0, //
  0.349, 0.686, 0.168, 0, 0, //
  0.272, 0.534, 0.131, 0, 0, //
  0, 0, 0, 1, 0, //
];

const List<double> _invertMatrix = <double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
];

abstract final class AppTheme {
  static const String displayFont = 'Space Grotesk';
  static const String bodyFont = 'Inter';

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final scheme =
        ColorScheme.fromSeed(seedColor: AppColors.cyan, brightness: brightness)
            .copyWith(
      primary: isDark ? AppColors.cyanBright : AppColors.cyan,
      onPrimary: isDark ? const Color(0xFF06222A) : Colors.white,
      secondary: isDark ? AppColors.slateText : AppColors.ink,
      surface: isDark ? AppColors.slateSurface : Colors.white,
      onSurface: isDark ? AppColors.slateText : AppColors.ink,
      onSurfaceVariant: isDark ? AppColors.slateMuted : AppColors.muted,
      outlineVariant: isDark ? AppColors.slateLine : AppColors.hairline,
      error: AppColors.danger,
      onError: Colors.white,
    );

    final onSurface = scheme.onSurface;
    final base = Typography.material2021(platform: TargetPlatform.android);
    final tt = (isDark ? base.white : base.black)
        .apply(fontFamily: bodyFont, bodyColor: onSurface, displayColor: onSurface);

    TextStyle display(double size, {double spacing = -0.5, FontWeight w = FontWeight.w600}) =>
        TextStyle(fontFamily: displayFont, fontSize: size, fontWeight: w, letterSpacing: spacing, color: onSurface);

    final textTheme = tt.copyWith(
      displaySmall: display(36, spacing: -0.8, w: FontWeight.w700),
      headlineMedium: display(26, spacing: -0.5, w: FontWeight.w700),
      headlineSmall: display(22, spacing: -0.4),
      titleLarge: display(18, spacing: -0.2),
      titleMedium: TextStyle(fontFamily: bodyFont, fontSize: 15, fontWeight: FontWeight.w600, color: onSurface),
      bodyLarge: TextStyle(fontFamily: bodyFont, fontSize: 15, height: 1.5, color: onSurface),
      bodyMedium: TextStyle(fontFamily: bodyFont, fontSize: 13.5, height: 1.5, color: onSurface),
      labelLarge: const TextStyle(fontFamily: bodyFont, fontSize: 14, fontWeight: FontWeight.w600),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: bodyFont,
      textTheme: textTheme,
      scaffoldBackgroundColor: isDark ? AppColors.slate : AppColors.canvas,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: (isDark ? AppColors.slateSurface : Colors.white).withValues(alpha: 0.82),
        surfaceTintColor: Colors.transparent,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
            fontFamily: bodyFont, fontSize: 16, fontWeight: FontWeight.w600, color: onSurface),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? AppColors.slateLine : AppColors.hairline,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: isDark ? AppColors.slateMuted : AppColors.ink2),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: isDark ? AppColors.cyanBright : AppColors.ink,
          foregroundColor: isDark ? const Color(0xFF06222A) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: bodyFont, fontSize: 14.5, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? AppColors.slateSurface2 : AppColors.ink,
        contentTextStyle: TextStyle(
            fontFamily: bodyFont, fontSize: 13.5, color: isDark ? AppColors.slateText : Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }
}
