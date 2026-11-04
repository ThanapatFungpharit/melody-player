import "package:flutter_test/flutter_test.dart";
import "package:melody_audio/src/native_queue_policy.dart";

NativeQueuePosition reconcile(List<String> ids, String? active, int index) =>
    reconcileNativeQueue(ids.length, (row) => ids[row], active, index);

List<int> upcoming(
  int length,
  int start, {
  bool wrap = false,
  int limit = 3,
  Set<int> unplayable = const {},
}) => upcomingQueueRows(
  length: length,
  start: start,
  wrap: wrap,
  limit: limit,
  playable: (row) => !unplayable.contains(row),
);

void main() {
  group("reconciling the playing track with a new queue", () {
    test("removing the active row keeps it detached until its successor", () {
      final position = reconcile(["a", "c", "d"], "b", 1);
      expect(position.activeIndex, -1);
      expect(position.detachedSuccessorIndex, 1);
    });

    test("a selected duplicate stays selected after a queue reorder", () {
      final position = reconcile(["a", "b", "b", "c"], "b", 2);
      expect(position.activeIndex, 2);
      expect(position.detachedSuccessorIndex, -1);
    });

    test("a moved track is found at its new row", () {
      expect(reconcile(["c", "a", "b"], "b", 1).activeIndex, 2);
    });

    test("nothing active starts from the requested row", () {
      final position = reconcile(["a", "b"], null, 1);
      expect(position.activeIndex, -1);
      expect(position.detachedSuccessorIndex, 1);
    });

    test("an empty queue has no position", () {
      final position = reconcile([], "a", 0);
      expect(position.activeIndex, -1);
      expect(position.detachedSuccessorIndex, -1);
    });

    test("the common case reads only the requested row", () {
      var reads = 0;
      final position = reconcileNativeQueue(
        5000,
        (row) {
          reads++;
          return "a";
        },
        "a",
        1234,
      );
      expect(position.activeIndex, 1234);
      expect(reads, 1);
    });
  });

  group("the rows to play next", () {
    test("stop at the limit", () => expect(upcoming(10, 2), [2, 3, 4]));

    test("stop at the end without repeat", () {
      expect(upcoming(4, 3), [3]);
      expect(upcoming(4, 4), isEmpty);
    });

    test("wrap with repeat", () {
      expect(upcoming(4, 3, wrap: true), [3, 0, 1]);
      expect(upcoming(4, 4, wrap: true), [0, 1, 2]);
    });

    test("a one-row queue on repeat fills the window", () {
      expect(upcoming(1, 1, wrap: true), [0, 0, 0]);
    });

    test("unplayable rows are skipped", () {
      expect(upcoming(5, 0, unplayable: {1, 2}), [0, 3, 4]);
    });

    test("nothing playable ends the search, even on repeat", () {
      expect(upcoming(3, 0, wrap: true, unplayable: {0, 1, 2}), isEmpty);
    });

    test("nothing follows without a start or a queue", () {
      expect(upcoming(0, 0, wrap: true), isEmpty);
      expect(upcoming(3, -1, wrap: true), isEmpty);
    });
  });
}
