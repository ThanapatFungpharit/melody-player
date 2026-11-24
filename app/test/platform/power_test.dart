import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:melody/platform/power.dart";
import "package:path/path.dart" as p;

import "../support/temp.dart";

void main() {
  late Directory root;

  setUp(() async => root = await createTestDirectory("melody-power"));
  tearDown(() => deleteTestDirectory(root));

  group("Linux power profile", () {
    Future<ProcessResult> noDaemon(String _, List<String> _) async =>
        ProcessResult(0, 1, "", "no such service");

    Future<bool> withProfile(
      String? profile, {
      Future<ProcessResult> Function(String, List<String>)? run,
    }) async {
      final file = p.join(root.path, "platform_profile");
      if (profile != null) await File(file).writeAsString("$profile\n");
      return SystemPowerSaver.linuxPowerSaving(
        profileFile: file,
        run: run ?? noDaemon,
      );
    }

    test("the firmware's low-power profile saves power", () async {
      expect(await withProfile("low-power"), isTrue);
      expect(await withProfile("quiet"), isTrue);
      expect(await withProfile("balanced"), isFalse);
      expect(await withProfile("performance"), isFalse);
    });

    test("without one, the power profiles daemon answers", () async {
      final asked = <String>[];
      Future<ProcessResult> daemon(String command, List<String> args) async {
        asked.add(args[3]);
        return ProcessResult(0, 0, "(<'power-saver'>,)\n", "");
      }

      expect(await withProfile(null, run: daemon), isTrue);
      expect(asked, ["org.freedesktop.UPower.PowerProfiles"]);
      expect(
        await withProfile(
          null,
          run: (_, _) async => ProcessResult(0, 0, "(<'balanced'>,)\n", ""),
        ),
        isFalse,
      );
    });

    test("no profile and no daemon means not saving", () async {
      expect(await withProfile(null), isFalse);
      expect(
        await withProfile(
          null,
          run: (_, _) => throw const ProcessException("gdbus", []),
        ),
        isFalse,
      );
    });
  });

  group("SystemPowerSaver", () {
    test("reads again on return only after the minimum wait", () async {
      var reads = 0;
      var saving = false;
      final saver = SystemPowerSaver(
        read: () async {
          reads++;
          return saving;
        },
        minimumRecheck: const Duration(hours: 1),
      );
      await saver.start();
      saving = true;
      await saver.refresh();
      expect(reads, 1);
      expect(saver.saving.value, isFalse);
      saver.dispose();
    });

    test("a failed read keeps working as usual", () async {
      final saver = SystemPowerSaver(
        read: () async => throw StateError("no power service"),
        minimumRecheck: Duration.zero,
      );
      final printed = <String?>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message);
      try {
        await saver.start();
      } finally {
        debugPrint = original;
      }
      expect(saver.saving.value, isFalse);
      expect(printed.single, contains("system power mode"));
      saver.dispose();
    });

    test("a change is heard once it is read", () async {
      var saving = false;
      final saver = SystemPowerSaver(
        read: () async => saving,
        minimumRecheck: Duration.zero,
      );
      await saver.start();
      saving = true;
      await saver.refresh();
      expect(saver.saving.value, isTrue);
      saver.dispose();
    });
  });
}
