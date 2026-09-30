import "package:flutter_test/flutter_test.dart";
import "package:flet_background_audio/src/native_queue_policy.dart";

void main() {
  test("removing the active row keeps it detached until its successor", () {
    final position = reconcileNativeQueue(["a", "c", "d"], "b", 1);

    expect(position.activeIndex, -1);
    expect(position.detachedSuccessorIndex, 1);
  });

  test("a selected duplicate stays selected after a queue reorder", () {
    final position = reconcileNativeQueue(["a", "b", "b", "c"], "b", 2);

    expect(position.activeIndex, 2);
    expect(position.detachedSuccessorIndex, -1);
  });

  test("an attached track keeps the queue order", () {
    final layout = nativePlaylistLayout(
      3,
      reconcileNativeQueue(["a", "b", "c"], "b", 1),
    );

    expect(layout.queueIndexes, [0, 1, 2]);
    expect(layout.initialIndex, 1);
  });

  test("a detached track plays between its predecessor and successor", () {
    // Rotating the queue behind the detached track used to make repeat-off
    // continue into earlier rows and Skip Previous miss the predecessor.
    final layout = nativePlaylistLayout(
      3,
      reconcileNativeQueue(["a", "c", "d"], "b", 1),
    );

    expect(layout.queueIndexes, [0, -1, 1, 2]);
    expect(layout.initialIndex, 1);
  });

  test("a detached preview before the first row keeps the full queue", () {
    final layout = nativePlaylistLayout(
      2,
      reconcileNativeQueue(["a", "b"], null, 0),
    );

    expect(layout.queueIndexes, [-1, 0, 1]);
    expect(layout.initialIndex, 0);
  });

  test("an empty queue keeps only the detached decoder", () {
    final layout = nativePlaylistLayout(0, reconcileNativeQueue([], "a", 0));

    expect(layout.queueIndexes, [-1]);
    expect(layout.initialIndex, 0);
  });
}
