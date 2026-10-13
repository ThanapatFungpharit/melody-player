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

/// Corner radii shared by every surface, smallest to largest.
abstract final class Radii {
  static const small = 6.0;
  static const medium = 10.0;
  static const large = 16.0;
  static const panel = 20.0;
}

Color accentColor(String name) =>
    themePalettes[name] ?? themePalettes["violet"]!;

/// Colors the Material scheme has no slot for.
class MelodyPalette extends ThemeExtension<MelodyPalette> {
  const MelodyPalette({
    required this.canvas,
    required this.hover,
    required this.favorite,
    required this.success,
  });

  /// The window background the sidebar, panels, and player bar sit on.
  final Color canvas;

  /// The wash behind a hovered row or card.
  final Color hover;
  final Color favorite;
  final Color success;

  static MelodyPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _light = MelodyPalette(
    canvas: Color(0xFFEDEDF0),
    hover: Color(0x0D18181B),
    favorite: Color(0xFFE11D48),
    success: Color(0xFF16A34A),
  );

  static const _dark = MelodyPalette(
    canvas: Color(0xFF09090B),
    hover: Color(0x12FFFFFF),
    favorite: Color(0xFFFB7185),
    success: Color(0xFF4ADE80),
  );

  @override
  MelodyPalette copyWith({
    Color? canvas,
    Color? hover,
    Color? favorite,
    Color? success,
  }) => MelodyPalette(
    canvas: canvas ?? this.canvas,
    hover: hover ?? this.hover,
    favorite: favorite ?? this.favorite,
    success: success ?? this.success,
  );

  @override
  MelodyPalette lerp(MelodyPalette? other, double t) => other == null
      ? this
      : MelodyPalette(
          canvas: Color.lerp(canvas, other.canvas, t)!,
          hover: Color.lerp(hover, other.hover, t)!,
          favorite: Color.lerp(favorite, other.favorite, t)!,
          success: Color.lerp(success, other.success, t)!,
        );
}

extension MelodyThemeContext on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  MelodyPalette get palette =>
      Theme.of(this).extension<MelodyPalette>() ??
      MelodyPalette.of(Theme.of(this).brightness);
}

/// Neutral surfaces carry the content; the accent marks only what is
/// active, playing, or primary.
ColorScheme _scheme(Color seed, Brightness brightness) {
  final seeded = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  if (brightness == Brightness.dark) {
    return seeded.copyWith(
      surface: const Color(0xFF131316),
      surfaceDim: const Color(0xFF0E0E10),
      surfaceBright: const Color(0xFF2F2F35),
      surfaceContainerLowest: const Color(0xFF0E0E10),
      surfaceContainerLow: const Color(0xFF18181B),
      surfaceContainer: const Color(0xFF1E1E22),
      surfaceContainerHigh: const Color(0xFF26262B),
      surfaceContainerHighest: const Color(0xFF303036),
      onSurface: const Color(0xFFF4F4F5),
      onSurfaceVariant: const Color(0xFFA1A1AA),
      outline: const Color(0xFF5B5B64),
      outlineVariant: const Color(0xFF2A2A30),
      inverseSurface: const Color(0xFFF4F4F5),
      onInverseSurface: const Color(0xFF18181B),
    );
  }
  return seeded.copyWith(
    surface: const Color(0xFFFFFFFF),
    surfaceDim: const Color(0xFFDCDCE0),
    surfaceBright: const Color(0xFFFFFFFF),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF6F6F7),
    surfaceContainer: const Color(0xFFF0F0F2),
    surfaceContainerHigh: const Color(0xFFE9E9EC),
    surfaceContainerHighest: const Color(0xFFE1E1E5),
    onSurface: const Color(0xFF18181B),
    onSurfaceVariant: const Color(0xFF61616A),
    outline: const Color(0xFFA1A1AA),
    outlineVariant: const Color(0xFFE4E4E7),
    inverseSurface: const Color(0xFF18181B),
    onInverseSurface: const Color(0xFFF4F4F5),
  );
}

TextTheme _text(TextTheme base, ColorScheme scheme) {
  TextStyle style(
    TextStyle? from,
    double size,
    FontWeight weight, {
    double spacing = 0,
    double? height,
    Color? color,
  }) => from!.copyWith(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
    color: color ?? scheme.onSurface,
  );
  return base.copyWith(
    displaySmall: style(
      base.displaySmall,
      40,
      FontWeight.w800,
      spacing: -1.2,
      height: 1.1,
    ),
    headlineMedium: style(
      base.headlineMedium,
      30,
      FontWeight.w800,
      spacing: -0.8,
      height: 1.15,
    ),
    headlineSmall: style(
      base.headlineSmall,
      24,
      FontWeight.w700,
      spacing: -0.5,
      height: 1.2,
    ),
    titleLarge: style(base.titleLarge, 19, FontWeight.w700, spacing: -0.3),
    titleMedium: style(base.titleMedium, 15, FontWeight.w600),
    titleSmall: style(base.titleSmall, 14, FontWeight.w600),
    bodyLarge: style(base.bodyLarge, 15, FontWeight.w400),
    bodyMedium: style(base.bodyMedium, 14, FontWeight.w400),
    bodySmall: style(
      base.bodySmall,
      12.5,
      FontWeight.w400,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: style(base.labelLarge, 14, FontWeight.w600),
    labelMedium: style(base.labelMedium, 12, FontWeight.w600),
    labelSmall: style(
      base.labelSmall,
      11,
      FontWeight.w700,
      spacing: 1.1,
      color: scheme.onSurfaceVariant,
    ),
  );
}

ThemeData buildTheme(String accent, Brightness brightness) {
  final scheme = _scheme(accentColor(accent), brightness);
  final palette = MelodyPalette.of(brightness);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: Platform.isWindows ? "Segoe UI" : null,
  );
  final text = _text(base.textTheme, scheme);
  const stadium = StadiumBorder();
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.medium),
  );
  final buttonText = text.labelLarge!.copyWith(color: null);
  return base.copyWith(
    textTheme: text,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    hoverColor: palette.hover,
    extensions: [palette],
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: stadium,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant, width: 1.2),
        shape: stadium,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: scheme.onSurface,
        shape: stadium,
        textStyle: buttonText,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant, width: 1.2),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onSurface
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.surface
              : scheme.onSurface,
        ),
        textStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      hoverColor: palette.hover,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: scheme.onSurface,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.onSurface,
      disabledActiveTrackColor: scheme.outline,
      disabledInactiveTrackColor: scheme.surfaceContainerHigh,
      disabledThumbColor: scheme.outline,
      overlayColor: scheme.onSurface.withValues(alpha: 0.08),
      trackShape: const RoundedRectSliderTrackShape(),
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: 6,
        disabledThumbRadius: 5,
        elevation: 0,
        pressedElevation: 0,
      ),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      showValueIndicator: ShowValueIndicator.never,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: rounded,
      textStyle: text.bodyMedium,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.panel),
      ),
      titleTextStyle: text.titleLarge,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: scheme.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      elevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium!.copyWith(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded,
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.large),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: stadium,
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainerHigh,
      labelStyle: text.labelMedium,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      textStyle: text.labelMedium!.copyWith(color: scheme.onInverseSurface),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(Radii.small),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(
        color: scheme.onInverseSurface,
      ),
      shape: rounded,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurface.withValues(alpha: 0.22),
      ),
    ),
  );
}

ThemeMode themeModeFor(String value) => switch (value) {
  "dark" => ThemeMode.dark,
  "light" => ThemeMode.light,
  _ => ThemeMode.system,
};
