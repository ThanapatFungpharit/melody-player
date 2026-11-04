import "dart:math";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/queue.dart";

import "playback_test.dart" show IdentityRandom;

void main() {
  test("play next and append are distinct", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    queue
      ..addNextAll(["next"])
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

  test("shuffle reorders the whole queue around the current track", () {
    final queue = PlaybackQueue(random: Random(4))
      ..replace(["a", "b", "c", "d", "e"], startIndex: 2);
    expect(queue.canShuffle, isTrue);
    expect(queue.shuffle(), isTrue);
    expect(queue.current, "c");
    expect(queue.currentIndex, 0);
    expect(queue.items.toSet(), {"a", "b", "c", "d", "e"});
    expect(queue.nextIndex(), 1);
  });

  test("shuffle reaches rows that already played", () {
    // With rows above the current one, repeat replays them too; none of the
    // seeds may leave them all in their old place at the end of the queue.
    final order = ["a", "b", "c", "d", "e", "f", "g", "h"];
    final moved = <bool>[
      for (var seed = 0; seed < 8; seed++)
        () {
          final queue = PlaybackQueue(
            random: Random(seed),
            repeat: RepeatMode.playlist,
          )..replace(order, startIndex: 4);
          queue.shuffle();
          return queue.items.indexOf("a") != queue.items.indexOf("b") - 1;
        }(),
    ];
    expect(moved, contains(true));
  });

  test("shuffle works from the last row", () {
    final queue = PlaybackQueue(random: Random(1), repeat: RepeatMode.playlist)
      ..replace(["a", "b", "c", "d"], startIndex: 3);
    expect(queue.canShuffle, isTrue);
    expect(queue.shuffle(), isTrue);
    expect(queue.current, "d");
    expect(queue.items.first, "d");
  });

  test("shuffle changes the order even when the random order is unchanged", () {
    final queue = PlaybackQueue(random: IdentityRandom())
      ..replace(["a", "b", "c"]);
    expect(queue.shuffle(), isTrue);
    expect(queue.items, ["a", "c", "b"]);
  });

  test("shuffle has nothing to offer with one other track after this one", () {
    final queue = PlaybackQueue()..replace(["a", "b"]);
    expect(queue.canShuffle, isFalse);
    expect(queue.shuffle(), isFalse);
    expect(queue.items, ["a", "b"]);
  });

  test("shuffle brings the current track to the top of two", () {
    final queue = PlaybackQueue()..replace(["a", "b"], startIndex: 1);
    expect(queue.canShuffle, isTrue);
    expect(queue.shuffle(), isTrue);
    expect(queue.items, ["b", "a"]);
    expect(queue.currentIndex, 0);
  });

  test("a shuffled replacement reorders the whole collection once", () {
    final queue = PlaybackQueue(random: Random(1))
      ..replace(["a", "b", "c", "d"], shuffleOnce: true);
    expect(queue.currentIndex, 0);
    expect(queue.items.toSet(), {"a", "b", "c", "d"});
    queue.replace(["x", "y", "z"]);
    expect(queue.items, ["x", "y", "z"]);
  });

  test("shuffling one track queued repeatedly reports no change", () {
    final queue = PlaybackQueue()..replace(["a"]);
    queue
      ..addLast("b")
      ..addLast("b");
    expect(queue.shuffle(), isFalse);
    expect(queue.items, ["a", "b", "b"]);
  });

  test("play next stays next after a shuffle", () {
    final queue = PlaybackQueue(random: Random(2))
      ..replace(["a", "b", "c", "d"]);
    queue
      ..shuffle()
      ..addNextAll(["n"]);
    expect(queue.items[queue.nextIndex()!], "n");
  });
}
