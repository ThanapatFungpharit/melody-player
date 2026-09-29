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
  final selectedIndex = activeTrackId != null &&
          trackIds[boundedIndex] == activeTrackId
      ? boundedIndex
      : activeIndex;
  return selectedIndex >= 0
      ? NativeQueuePosition(selectedIndex, -1)
      : NativeQueuePosition(-1, boundedIndex);
}

int? nextNativeQueueIndex({
  required int length,
  required int activeIndex,
  required int detachedSuccessorIndex,
  required String repeatMode,
  required bool automatic,
  int? fromIndex,
}) {
  if (length == 0) return null;
  final index = fromIndex ?? activeIndex;
  if (index < 0) {
    return detachedSuccessorIndex >= 0 ? detachedSuccessorIndex : null;
  }
  if (automatic && repeatMode == "track") return index;
  if (index + 1 < length) return index + 1;
  if (repeatMode == "playlist") return 0;
  return null;
}
