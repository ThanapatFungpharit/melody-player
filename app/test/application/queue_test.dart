import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/queue.dart";

import "playback_test.dart" show IdentityRandom;

void main() {
  test("play next and append are distinct", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    queue
      ..addNext("next")
      ..addLast("last");
    expect(queue.items, ["a", "next", "b", "last"]);
  });

  test("several tracks played next keep their order", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    queue.addNextAll(["x", "y"]);
    expect(queue.items, ["a", "x", "y", "b"]);
    expect(queue.current, "a");

    final empty = PlaybackQueue()..addNextAll(["x", "y", "z"]);
    expect(empty.items, ["x", "y", "z"]);
    expect(empty.current, "x");
  });

  test("a replacement with duplicates starts at the chosen track", () {
    final queue = PlaybackQueue()..replace(["a", "a", "b", "c"], startIndex: 2);
    expect(queue.items, ["a", "b", "c"]);
    expect(queue.current, "b");
  });

  test("moving rows keeps the current track", () {
    final queue = PlaybackQueue()..replace(["a", "b", "c"], startIndex: 1);
    queue.move(1, 2);
    expect(queue.current, "b");
    expect(queue.items, ["a", "c", "b"]);
    queue.move(0, 2);
    expect(queue.current, "b");
    expect(queue.currentIndex, 1);
  });

  test("repeat track and repeat queue", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    queue.repeat = RepeatMode.track;
    expect(queue.next(automatic: true), "a");
    expect(queue.next(), "b");
    queue.repeat = RepeatMode.playlist;
    expect(queue.next(), "a");
    expect(queue.previous(), "b");
  });

  test("round trip and invalid restore fields", () {
    final queue = PlaybackQueue()..replace(["a", "b"], startIndex: 1);
    queue.repeat = RepeatMode.playlist;
    final restored = PlaybackQueue.fromJson(queue.toJson(positionMs: 9));
    expect(restored.items, ["a", "b"]);
    expect(restored.currentIndex, 1);
    expect(restored.repeat, RepeatMode.playlist);
    final broken = PlaybackQueue.fromJson({
      "queue": ["a", 3, "", null],
      "current_index": "x",
      "repeat": "sideways",
      "shuffle": true,
    });
    expect(broken.items, ["a"]);
    expect(broken.currentIndex, 0);
    expect(broken.repeat, RepeatMode.off);
    expect(broken.toJson().containsKey("shuffle"), isFalse);
  });

  test("shuffle reorders only upcoming tracks", () {
    final queue = PlaybackQueue(random: Random(4))
      ..replace(["a", "b", "c", "d", "e"], startIndex: 1);
    expect(queue.shuffleUpcoming(), isTrue);
    expect(queue.items.take(2), ["a", "b"]);
    expect(queue.items.skip(2).toSet(), {"c", "d", "e"});
    expect(queue.current, "b");
  });

  test("shuffle changes the order even when the random order is unchanged", () {
    final queue = PlaybackQueue(random: IdentityRandom())
      ..replace(["a", "b", "c"]);
    expect(queue.shuffleUpcoming(), isTrue);
    expect(queue.items, ["a", "c", "b"]);
  });

  test("shuffle does nothing with one remaining track", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    expect(queue.shuffleUpcoming(), isFalse);
  });

  test("a shuffled replacement reorders the whole collection once", () {
    final queue = PlaybackQueue(random: Random(1))
      ..replace(["a", "b", "c", "d"], shuffleOnce: true);
    expect(queue.currentIndex, 0);
    expect(queue.items.toSet(), {"a", "b", "c", "d"});
    queue.replace(["x", "y", "z"]);
    expect(queue.items, ["x", "y", "z"]);
  });

  test("play next stays next after a shuffle", () {
    final queue = PlaybackQueue(random: Random(2))
      ..replace(["a", "b", "c", "d"]);
    queue
      ..shuffleUpcoming()
      ..addNext("n");
    expect(queue.peekNext(), "n");
  });
}
