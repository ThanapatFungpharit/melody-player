/// Queue coordinates for a decoder that may outlive its queue row.
class NativeQueuePosition {
  const NativeQueuePosition(this.activeIndex, this.detachedSuccessorIndex);

  final int activeIndex;
  final int detachedSuccessorIndex;
}

/// Where the track [activeTrackId] the decoder is playing belongs in a queue
/// of [length] rows, read through [trackAt]. Duplicates keep [requestedIndex]
/// when it holds the track, so most edits read one row.
NativeQueuePosition reconcileNativeQueue(
  int length,
  String Function(int row) trackAt,
  String? activeTrackId,
  int requestedIndex,
) {
  if (length == 0) return const NativeQueuePosition(-1, -1);
  final boundedIndex = requestedIndex.clamp(0, length - 1).toInt();
  if (activeTrackId != null) {
    if (trackAt(boundedIndex) == activeTrackId) {
      return NativeQueuePosition(boundedIndex, -1);
    }
    for (var row = 0; row < length; row++) {
      if (trackAt(row) == activeTrackId) return NativeQueuePosition(row, -1);
    }
  }
  return NativeQueuePosition(-1, boundedIndex);
}

/// The queue rows the decoder should play next, in order: up to [limit]
/// [playable] rows from [start], wrapping to the first row when [wrap] is set.
/// A row can appear more than once, such as a one-row queue on repeat.
List<int> upcomingQueueRows({
  required int length,
  required int start,
  required bool wrap,
  required int limit,
  required bool Function(int row) playable,
}) {
  final rows = <int>[];
  if (length == 0 || start < 0) return rows;
  // One lap at most, so a queue with nothing playable cannot spin; a short
  // queue on repeat fills the window with further laps.
  var unplayable = 0;
  for (var offset = 0; rows.length < limit; offset++) {
    final row = start + offset;
    if (row >= length && !wrap) break;
    final wrapped = row % length;
    if (playable(wrapped)) {
      rows.add(wrapped);
      unplayable = 0;
    } else if (++unplayable >= length) {
      break;
    }
  }
  return rows;
}
