import "dart:math";
import "dart:ui" show DisplayFeature;

import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Lays the whole app out inside the system safe area: the status and
/// navigation bars, display cutouts, and window caption bars.
///
/// Edge-to-edge Android draws the app behind the system bars, so every
/// screen, sheet, dialog, and snackbar would otherwise have to inset itself,
/// and one that forgets ends up under the navigation bar. Under this guard
/// [MediaQuery] describes only the safe rectangle: its size leaves out the
/// insets and its padding is zero, so layouts sized from the screen
/// (dialog widths, sheet heights, breakpoints) stay on screen too. The bars
/// themselves show the theme surface, with icons that contrast with it.
///
/// Desktop windows report no insets, so there the guard changes nothing.
class SafeAreaGuard extends StatelessWidget {
  const SafeAreaGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    // Padding, not viewPadding: the keyboard covers the navigation bar, so
    // while it is open the bottom inset drops to zero and Scaffold makes
    // room for the keyboard on its own.
    final insets = media.padding;
    final icons = theme.brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        statusBarBrightness: theme.brightness,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: icons,
        systemNavigationBarContrastEnforced: false,
      ),
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: insets,
          child: MediaQuery(
            data: media.copyWith(
              size: Size(
                max(0, media.size.width - insets.horizontal),
                max(0, media.size.height - insets.vertical),
              ),
              padding: EdgeInsets.zero,
              viewPadding: _less(media.viewPadding, insets),
              viewInsets: _less(media.viewInsets, insets),
              systemGestureInsets: _less(media.systemGestureInsets, insets),
              // Hinges and folds are given in screen coordinates.
              displayFeatures: [
                for (final feature in media.displayFeatures)
                  DisplayFeature(
                    bounds: feature.bounds.shift(
                      Offset(-insets.left, -insets.top),
                    ),
                    type: feature.type,
                    state: feature.state,
                  ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

EdgeInsets _less(EdgeInsets value, EdgeInsets inset) => EdgeInsets.fromLTRB(
  max(0, value.left - inset.left),
  max(0, value.top - inset.top),
  max(0, value.right - inset.right),
  max(0, value.bottom - inset.bottom),
);
