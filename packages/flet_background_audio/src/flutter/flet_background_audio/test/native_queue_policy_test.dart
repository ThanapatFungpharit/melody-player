import "package:flutter_test/flutter_test.dart";
import "package:flet_background_audio/src/native_queue_policy.dart";

void main() {
  test("removing the active row keeps it detached until its successor", () {
    final position = reconcileNativeQueue(["a", "c", "d"], "b", 1);

    expect(position.activeIndex, -1);
    expect(position.detachedSuccessorIndex, 1);
    expect(nextNativeQueueIndex(
      length: 3,
      activeIndex: position.activeIndex,
      detachedSuccessorIndex: position.detachedSuccessorIndex,
      repeatMode: "off",
      automatic: true,
    ), 1);
  });

  test("a selected duplicate stays selected after a queue reorder", () {
    final position = reconcileNativeQueue(["a", "b", "b", "c"], "b", 2);

    expect(position.activeIndex, 2);
    expect(position.detachedSuccessorIndex, -1);
  });

  test("manual navigation advances during track repeat", () {
    expect(nextNativeQueueIndex(
      length: 3,
      activeIndex: 1,
      detachedSuccessorIndex: -1,
      repeatMode: "track",
      automatic: true,
    ), 1);
    expect(nextNativeQueueIndex(
      length: 3,
      activeIndex: 1,
      detachedSuccessorIndex: -1,
      repeatMode: "track",
      automatic: false,
    ), 2);
  });

  test("playlist repeat wraps after the last row", () {
    expect(nextNativeQueueIndex(
      length: 3,
      activeIndex: 2,
      detachedSuccessorIndex: -1,
      repeatMode: "playlist",
      automatic: true,
    ), 0);
  });

  test("an empty queue has no successor", () {
    final position = reconcileNativeQueue([], "a", 0);
    expect(nextNativeQueueIndex(
      length: 0,
      activeIndex: position.activeIndex,
      detachedSuccessorIndex: position.detachedSuccessorIndex,
      repeatMode: "playlist",
      automatic: true,
    ), isNull);
  });
}
