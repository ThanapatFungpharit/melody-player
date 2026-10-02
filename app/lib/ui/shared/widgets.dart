import "dart:io";

import "package:flutter/material.dart" hide RepeatMode;

import "../../app/app_state.dart";
import "../../application/models.dart";
import "../../application/queue.dart";

/// Track or playlist artwork: the offline cache first, then the network,
/// with a stable placeholder while loading or on failure.
class Artwork extends StatelessWidget {
  const Artwork(this.app, this.source, {super.key, this.size = 48, this.playlist = false});

  final MelodyApp app;
  final String source;
  final double size;
  final bool playlist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(size >= 100 ? 14 : 12);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: radius),
      alignment: Alignment.center,
      child: Icon(
        playlist ? Icons.album_rounded : Icons.music_note_rounded,
        size: size * 0.38 < 22 ? 22 : size * 0.38,
        color: scheme.primary,
      ),
    );
    if (source.isEmpty) return placeholder;
    final cached = app.services.thumbnails.cachedPath(source);
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final ImageProvider provider;
    if (cached != null) {
      provider = FileImage(File(cached));
    } else if (source.startsWith("http://") || source.startsWith("https://")) {
      provider = NetworkImage(source);
    } else if (File(source).existsSync()) {
      provider = FileImage(File(source));
    } else {
      return placeholder;
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image(
        image: ResizeImage(provider, width: cacheWidth, policy: ResizeImagePolicy.fit),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, synchronous) =>
            frame == null && !synchronous ? placeholder : child,
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.message, {super.key});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
            child: Icon(icon, size: 36, color: scheme.primary),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
        ],
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
    padding: const EdgeInsets.all(20),
    child: Row(
      children: [
        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ],
    ),
  );
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
  Widget build(BuildContext context) => Row(
    children: [
      TextButton.icon(
        onPressed: start == 0 ? null : () => onChange(-1),
        icon: const Icon(Icons.chevron_left_rounded),
        label: const Text("Previous"),
      ),
      Expanded(child: Text("${start + 1}–$end of $total", textAlign: TextAlign.center)),
      TextButton.icon(
        onPressed: end >= total ? null : () => onChange(1),
        icon: const Icon(Icons.chevron_right_rounded),
        label: const Text("Next"),
        iconAlignment: IconAlignment.end,
      ),
    ],
  );
}

/// A full page window, clamping a stale offset after the collection shrank.
(int, int) pageBounds(int total, int offset, {int pageSize = 50}) {
  final last = total <= 0 ? 0 : (total - 1) ~/ pageSize * pageSize;
  final start = offset.clamp(0, last);
  return (start, (start + pageSize).clamp(0, total));
}

/// Rebuilds when any of [listenables] fires.
class Watch extends StatelessWidget {
  const Watch(this.listenables, {super.key, required this.builder});

  final List<Listenable> listenables;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Listenable.merge(listenables), builder: (context, _) => builder(context));
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
    return queue.repeat == RepeatMode.track ? "Now playing · Repeats continuously" : "Now playing";
  }
  if (queue.repeat == RepeatMode.track) return "Waiting · Repeat track is on";
  if (index == queue.nextIndex(automatic: true)) {
    return queue.repeat == RepeatMode.playlist && index <= queue.currentIndex
        ? "Up next · Queue loops here"
        : "Up next";
  }
  if (index < queue.currentIndex) {
    return queue.repeat == RepeatMode.playlist
        ? "Played · Returns after the queue loops"
        : "Already played";
  }
  return "Later in queue";
}
