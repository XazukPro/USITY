import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData usityTheme(Brightness brightness) {
  final p = Palette(brightness);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: brightness,
      ).copyWith(
        primary: p.accentInk,
        onPrimary: p.bg,
        primaryContainer: p.accent,
        onPrimaryContainer: p.onFill,
        secondaryContainer: p.accentTint,
        onSecondaryContainer: p.accentInk,
        surface: p.surface,
        onSurface: p.ink,
        surfaceContainerLow: p.surface,
        surfaceContainerHighest: p.surfaceMuted,
        onSurfaceVariant: p.inkMuted,
        outline: p.borderStrong,
        outlineVariant: p.border,
        error: p.dangerInk,
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Onest',
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    textTheme: base.textTheme
        .copyWith(
          headlineMedium: TypeScale.titleLg,
          titleLarge: TypeScale.title,
          titleMedium: TypeScale.heading,
          bodyLarge: TypeScale.body,
          bodyMedium: TypeScale.callout,
          labelLarge: TypeScale.bodyStrong,
          labelMedium: TypeScale.caption,
        )
        .apply(bodyColor: p.ink, displayColor: p.ink),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onFill,
        minimumSize: const Size(Metrics.hitMin, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Metrics.radiusMd),
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(Metrics.space8),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.onFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Metrics.space5),
      ),
    ),
  );
}
