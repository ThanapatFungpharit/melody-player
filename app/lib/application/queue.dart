import "dart:math";

import "models.dart";

/// A persistent temporary play queue, independent of library playlists.
class PlaybackQueue {
  PlaybackQueue({
    List<String>? items,
    this.currentIndex = -1,
    this.repeat = RepeatMode.off,
    Random? random,
  }) : items = items ?? [],
       _random = random ?? Random();

  List<String> items;
  int currentIndex;
  RepeatMode repeat;
  final Random _random;

  String? get current => currentIndex >= 0 && currentIndex < items.length
      ? items[currentIndex]
      : null;

  int get upcomingCount => items.length - max(0, currentIndex + 1);

  String? replace(
    List<String> trackIds, {
    int startIndex = 0,
    bool shuffleOnce = false,
  }) {
    items = trackIds.toSet().toList();
    // [startIndex] indexes [trackIds]; duplicates dropped before it would
    // otherwise shift the selection onto a later track.
    currentIndex = items.isEmpty
        ? -1
        : items.indexOf(trackIds[startIndex.clamp(0, trackIds.length - 1)]);
    if (shuffleOnce && items.isNotEmpty) {
      // Starting a collection shuffled is a one-time reorder. Later selections
      // and queue replacements never inherit a shuffle mode.
      items.shuffle(_random);
      currentIndex = 0;
    }
    return current;
  }

  /// Selects a visible row without mutating its order.
  String? select(int index) {
    currentIndex = items.isEmpty ? -1 : index.clamp(0, items.length - 1);
    return current;
  }

  /// Inserts [trackIds] after the current track, in their given order. An
  /// empty queue starts with the first of them.
  void addNextAll(Iterable<String> trackIds) {
    final added = trackIds.toList();
    if (added.isEmpty) return;
    if (items.isEmpty || currentIndex < 0) {
      items.insertAll(0, added);
      currentIndex = max(currentIndex, 0);
      return;
    }
    items.insertAll(currentIndex + 1, added);
  }

  void addLast(String trackId) {
    items.add(trackId);
    currentIndex = max(currentIndex, 0);
  }

  String removeAt(int index) {
    final removed = items.removeAt(index);
    if (items.isEmpty) {
      currentIndex = -1;
    } else if (index < currentIndex) {
      currentIndex -= 1;
    } else if (index == currentIndex && currentIndex >= items.length) {
      currentIndex = items.length - 1;
    }
    return removed;
  }

  void move(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final current = currentIndex;
    final item = items.removeAt(oldIndex);
    final target = newIndex.clamp(0, items.length);
    items.insert(target, item);
    if (current == oldIndex) {
      currentIndex = target;
    } else if (oldIndex < current && current <= target) {
      currentIndex -= 1;
    } else if (target <= current && current < oldIndex) {
      currentIndex += 1;
    }
  }

  void clear({bool keepCurrent = false}) {
    final kept = keepCurrent ? current : null;
    items = kept != null ? [kept] : [];
    currentIndex = kept != null ? 0 : -1;
  }

  /// Reshuffles the remaining tracks once.
  bool shuffleUpcoming() {
    final start = max(0, currentIndex + 1);
    if (upcomingCount < 2) return false;
    final original = items.sublist(start);
    // One track queued several times has no other order to offer.
    if (original.toSet().length < 2) return false;
    final upcoming = List.of(original)..shuffle(_random);
    final unchanged = Iterable.generate(
      upcoming.length,
    ).every((i) => upcoming[i] == original[i]);
    final reordered = unchanged
        ? [...upcoming.skip(1), upcoming.first]
        : upcoming;
    items.replaceRange(start, items.length, reordered);
    return true;
  }

  /// The exact next row, including automatic repeat behavior.
  int? nextIndex({bool automatic = false}) {
    if (items.isEmpty) return null;
    if (automatic && repeat == RepeatMode.track) {
      return current != null ? currentIndex : null;
    }
    if (currentIndex + 1 < items.length) return currentIndex + 1;
    if (repeat == RepeatMode.playlist) return 0;
    return null;
  }

  String? next({bool automatic = false}) {
    final index = nextIndex(automatic: automatic);
    if (index == null) return null;
    currentIndex = index;
    return current;
  }

  String? previous() {
    if (items.isEmpty) return null;
    if (currentIndex > 0) {
      currentIndex -= 1;
    } else if (repeat == RepeatMode.playlist) {
      currentIndex = items.length - 1;
    }
    return current;
  }

  RepeatMode cycleRepeat() {
    const order = [RepeatMode.off, RepeatMode.track, RepeatMode.playlist];
    repeat = order[(order.indexOf(repeat) + 1) % order.length];
    return repeat;
  }

  Map<String, Object?> toJson({int positionMs = 0, int durationMs = 0}) => {
    "queue": List.of(items),
    "current_index": currentIndex,
    "position_ms": max(0, positionMs),
    "duration_ms": max(0, durationMs),
    "repeat": repeat.value,
  };

  factory PlaybackQueue.fromJson(Map<String, Object?> data, {Random? random}) {
    final raw = data["queue"];
    final items = [
      if (raw is List)
        for (final item in raw)
          if (item is String && item.isNotEmpty) item,
    ];
    var index = switch (data["current_index"]) {
      int value => value,
      num value when value.isFinite => value.toInt(),
      String value => int.tryParse(value) ?? -1,
      _ => -1,
    };
    index = items.isEmpty ? -1 : index.clamp(0, items.length - 1);
    return PlaybackQueue(
      items: items,
      currentIndex: index,
      repeat: RepeatMode.parse(data["repeat"]),
      random: random,
    );
  }
}
