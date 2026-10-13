/// Queue coordinates for a decoder that may outlive its queue row.
class NativeQueuePosition {
  const NativeQueuePosition(this.activeIndex, this.detachedSuccessorIndex);

  final int activeIndex;
  final int detachedSuccessorIndex;
}

NativeQueuePosition reconcileNativeQueue(
  List<String> trackIds,
  String? activeTrackId,
  int requestedIndex,
) {
  if (trackIds.isEmpty) return const NativeQueuePosition(-1, -1);
  final boundedIndex = requestedIndex.clamp(0, trackIds.length - 1).toInt();
  final activeIndex = activeTrackId == null
      ? -1
      : trackIds.indexOf(activeTrackId);
  final selectedIndex =
      activeTrackId != null && trackIds[boundedIndex] == activeTrackId
      ? boundedIndex
      : activeIndex;
  return selectedIndex >= 0
      ? NativeQueuePosition(selectedIndex, -1)
      : NativeQueuePosition(-1, boundedIndex);
}

/// Decoder playlist rows, as queue indexes in playback order.
class NativePlaylistLayout {
  const NativePlaylistLayout(this.queueIndexes, this.initialIndex);

  /// Queue index for each decoder row; -1 is a detached active decoder.
  final List<int> queueIndexes;
  final int initialIndex;
}

/// Places a detached active decoder immediately before its successor so that
/// automatic completion, manual skips, and repeat-off termination all follow
/// the queue order.
NativePlaylistLayout nativePlaylistLayout(
  int length,
  NativeQueuePosition position,
) {
  final rows = List<int>.generate(length, (index) => index);
  if (position.activeIndex >= 0) {
    return NativePlaylistLayout(rows, position.activeIndex);
  }
  final detached = position.detachedSuccessorIndex < 0
      ? length
      : position.detachedSuccessorIndex;
  rows.insert(detached, -1);
  return NativePlaylistLayout(rows, detached);
}
