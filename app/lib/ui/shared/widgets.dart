import "dart:io";

import "package:flutter/material.dart" hide RepeatMode;
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../../application/models.dart";
import "../../application/queue.dart";
import "../../core/library/models.dart";
import "theme.dart";

/// Track or playlist artwork: the offline cache first, then the network,
/// with a placeholder while loading or on failure. The placeholder takes a
/// stable tint from [seed] so tracks without covers stay distinguishable.
class Artwork extends StatelessWidget {
  const Artwork(
    this.app,
    this.source, {
    super.key,
    this.size = 48,
    this.playlist = false,
    this.seed = "",
    this.radius,
  });

  final MelodyApp app;
  final String source;
  final double size;
  final bool playlist;
  final String seed;
  final double? radius;

  static double radiusFor(double size) => size >= 160
      ? Radii.large
      : size >= 72
      ? Radii.medium
      : Radii.small;

  @override
  Widget build(BuildContext context) {
    final corners = BorderRadius.circular(radius ?? radiusFor(size));
    final placeholder = _Placeholder(
      size: size,
      radius: corners,
      seed: seed,
      icon: playlist ? Icons.album_rounded : Icons.music_note_rounded,
    );
    if (source.isEmpty) return placeholder;
    final cached = app.services.thumbnails.cachedPath(source);
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final ImageProvider provider;
    if (cached != null) {
      provider = FileImage(File(cached));
    } else if (source.startsWith("http://") || source.startsWith("https://")) {
      provider = NetworkImage(source);
    } else if (p.isAbsolute(source)) {
      // No existence check while building: a missing file decodes to an
      // error, which shows the placeholder.
      provider = FileImage(File(source));
    } else {
      return placeholder;
    }
    return ClipRRect(
      borderRadius: corners,
      child: Image(
        image: ResizeImage(
          provider,
          width: cacheWidth,
          policy: ResizeImagePolicy.fit,
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // Images already in memory show at once; the rest fade in over the
        // placeholder.
        frameBuilder: (context, child, frame, synchronous) => synchronous
            ? child
            : Stack(
                children: [
                  placeholder,
                  AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: child,
                  ),
                ],
              ),
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}

/// A playlist's cover: its first track's artwork, or none when it is empty.
String playlistArtwork(MelodyApp app, Playlist playlist) =>
    playlist.trackIds.isEmpty
    ? ""
    : app.services.library.details(playlist.trackIds.first).thumbnail;

/// A stable hue for [seed]; String.hashCode is not stable across runs.
double seedHue(String seed) {
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return (hash % 360).toDouble();
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.size,
    required this.radius,
    required this.seed,
    required this.icon,
  });

  final double size;
  final BorderRadius radius;
  final String seed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final List<Color> colors;
    final Color foreground;
    if (seed.isEmpty) {
      colors = [scheme.surfaceContainerHigh, scheme.surfaceContainerHighest];
      foreground = scheme.onSurfaceVariant;
    } else {
      final hue = seedHue(seed);
      Color tone(double shift, double lightness) => HSLColor.fromAHSL(
        1,
        (hue + shift) % 360,
        dark ? 0.30 : 0.40,
        lightness,
      ).toColor();
      colors = dark
          ? [tone(0, 0.32), tone(40, 0.19)]
          : [tone(0, 0.85), tone(40, 0.73)];
      foreground = dark
          ? Colors.white.withValues(alpha: 0.7)
          : Colors.black.withValues(alpha: 0.36);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: (size * 0.36).clamp(16.0, 96.0),
        color: foreground,
      ),
    );
  }
}

/// A quiet, centered message for an empty or failed view.
class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.message, {super.key, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 14,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 26, color: scheme.onSurfaceVariant),
              ),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

/// A small progress indicator row used while something loads.
class LoadingRow extends StatelessWidget {
  const LoadingRow(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
    child: Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: context.colors.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

/// A section title with an optional caption and trailing control.
class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    super.key,
    this.caption = "",
    this.trailing = const [],
  });

  final String title;
  final String caption;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    spacing: 4,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(title, style: context.text.titleLarge),
            if (caption.isNotEmpty)
              Text(caption, style: context.text.bodySmall),
          ],
        ),
      ),
      ...trailing,
    ],
  );
}

/// Earlier queries, newest first: tap one to search again, or forget it.
class RecentSearches extends StatelessWidget {
  const RecentSearches(
    this.queries, {
    super.key,
    required this.onSelect,
    required this.onRemove,
    required this.onClear,
  });

  final List<String> queries;
  final void Function(String query) onSelect;
  final void Function(String query) onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text("Recent searches", style: context.text.titleMedium),
            ),
            TextButton(onPressed: onClear, child: const Text("Clear all")),
          ],
        ),
        for (final query in queries)
          InkWell(
            onTap: () => onSelect(query),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                spacing: 14,
                children: [
                  Icon(Icons.history_rounded, size: 20, color: muted),
                  Expanded(
                    child: Text(
                      query,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => onRemove(query),
                    tooltip: "Remove from recent searches",
                    icon: Icon(Icons.close_rounded, size: 18, color: muted),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Tracks whether the pointer is over [builder]'s widget.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.cursor});

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor? cursor;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor ?? MouseCursor.defer,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, _hovered),
  );
}

/// The accent's equalizer mark for whatever is playing now.
class NowPlayingMark extends StatelessWidget {
  const NowPlayingMark({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.graphic_eq_rounded, size: size, color: context.colors.primary);
}

class PageNavigation extends StatelessWidget {
  const PageNavigation({
    super.key,
    required this.total,
    required this.start,
    required this.end,
    required this.onChange,
  });

  final int total;
  final int start;
  final int end;
  final void Function(int direction) onChange;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: start == 0 ? null : () => onChange(-1),
          icon: const Icon(Icons.chevron_left_rounded),
          label: const Text("Previous"),
        ),
        Expanded(
          child: Text(
            "${start + 1}–$end of $total",
            textAlign: TextAlign.center,
            style: context.text.bodySmall,
          ),
        ),
        TextButton.icon(
          onPressed: end >= total ? null : () => onChange(1),
          icon: const Icon(Icons.chevron_right_rounded),
          label: const Text("Next"),
          iconAlignment: IconAlignment.end,
        ),
      ],
    ),
  );
}

/// A full page window, clamping a stale offset after the collection shrank.
(int, int) pageBounds(int total, int offset, {int pageSize = 50}) {
  final last = total <= 0 ? 0 : (total - 1) ~/ pageSize * pageSize;
  final start = offset.clamp(0, last);
  return (start, (start + pageSize).clamp(0, total));
}

/// Cross-fades between destinations with a slight rise. Give each
/// destination its own key; the switcher fills the space it is given.
class PageSwitcher extends StatelessWidget {
  const PageSwitcher({super.key, required this.child});

  final Widget child;

  static final _rise = Tween(begin: const Offset(0, 0.012), end: Offset.zero);

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 140),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.expand, children: [...previous, ?current]),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(position: _rise.animate(animation), child: child),
    ),
    child: child,
  );
}

/// Rebuilds when any of [listenables] fires.
class Watch extends StatelessWidget {
  const Watch(this.listenables, {super.key, required this.builder});

  final List<Listenable> listenables;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(listenables),
    builder: (context, _) => builder(context),
  );
}

// -- queue language shared by both presentations --------------------------

class QueueModeStatus {
  const QueueModeStatus(this.label, this.description, this.icon);

  final String label;
  final String description;
  final IconData icon;
}

QueueModeStatus queueModeStatus(PlaybackQueue queue) => switch (queue.repeat) {
  RepeatMode.track => const QueueModeStatus(
    "Repeat track",
    "The current track repeats. Every other track waits until repeat is changed.",
    Icons.repeat_one_rounded,
  ),
  RepeatMode.playlist => const QueueModeStatus(
    "Repeat queue",
    "After the last track, playback continues again from the first track.",
    Icons.repeat_rounded,
  ),
  RepeatMode.off => const QueueModeStatus(
    "Play once",
    "The remaining tracks play in order, then playback stops.",
    Icons.format_list_numbered_rounded,
  ),
};

/// Describes a queue row by its actual automatic playback role.
String queueItemStatus(PlaybackQueue queue, int index) {
  if (index == queue.currentIndex) {
    return queue.repeat == RepeatMode.track
        ? "Now playing · On repeat"
        : "Now playing";
  }
  if (queue.repeat != RepeatMode.track &&
      index == queue.nextIndex(automatic: true)) {
    return "Up next";
  }
  return index < queue.currentIndex ? "Played" : "Queued";
}

/// BrandMark's gradient, from the top-left corner to the bottom-right.
List<Color> brandMarkColors(ColorScheme scheme) => [
  scheme.primary,
  Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.55), scheme.primary),
];

/// BrandMark's corner radius and glyph size, as fractions of its size.
const brandMarkRadius = 0.3;
const brandMarkGlyph = 0.62;

/// The app's mark: an accent tile with the equalizer glyph.
///
/// The running app's window, dock, or taskbar icon is drawn from it by
/// `AppIcon`. The Android launcher icons reproduce it in the light theme for
/// every accent; run `tools/build/icons.py` again after changing it.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * brandMarkRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: brandMarkColors(scheme),
        ),
      ),
      child: Icon(
        Icons.graphic_eq_rounded,
        color: scheme.onPrimary,
        size: size * brandMarkGlyph,
      ),
    );
  }
}
