import "dart:io";

import "package:flutter/material.dart";

const themePalettes = <String, Color>{
  "violet": Color(0xFF8B5CF6),
  "ocean": Color(0xFF0EA5E9),
  "rose": Color(0xFFF43F5E),
  "emerald": Color(0xFF10B981),
  "amber": Color(0xFFF59E0B),
  "slate": Color(0xFF64748B),
  "blue": Color(0xFF2563EB),
  "teal": Color(0xFF0D9488),
  "coral": Color(0xFFF97316),
  "magenta": Color(0xFFD946EF),
  "lime": Color(0xFF84CC16),
};

const touchTarget = 48.0;
const cardRadius = 18.0;

Color accentColor(String name) => themePalettes[name] ?? themePalettes["violet"]!;

ThemeData buildTheme(String accent, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: accentColor(accent), brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.comfortable,
    fontFamily: Platform.isWindows ? "Segoe UI" : null,
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

ThemeMode themeModeFor(String value) => switch (value) {
  "dark" => ThemeMode.dark,
  "light" => ThemeMode.light,
  _ => ThemeMode.system,
};
