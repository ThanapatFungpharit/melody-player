import "package:flutter_test/flutter_test.dart";
import "package:melody/application/models.dart";
import "package:melody/application/power.dart";

void main() {
  group("LowPowerSetting", () {
    test("follows the system only when automatic", () {
      expect(LowPowerSetting.off.active(systemSaving: true), isFalse);
      expect(LowPowerSetting.on.active(systemSaving: false), isTrue);
      expect(LowPowerSetting.automatic.active(systemSaving: false), isFalse);
      expect(LowPowerSetting.automatic.active(systemSaving: true), isTrue);
    });

    test("an unknown stored value is automatic", () {
      expect(LowPowerSetting.parse("on"), LowPowerSetting.on);
      expect(LowPowerSetting.parse("turbo"), LowPowerSetting.automatic);
      expect(LowPowerSetting.parse(null), LowPowerSetting.automatic);
    });
  });

  group("PowerProfile", () {
    PowerProfile profile({
      required bool lowPower,
      bool visible = true,
      bool limitDownloads = true,
      bool deferAnalysis = true,
    }) => PowerProfile.of(
      lowPower: lowPower,
      visible: visible,
      limitDownloads: limitDownloads,
      deferAnalysis: deferAnalysis,
    );

    test("normal work keeps every optional task and pixel progress", () {
      final normal = profile(lowPower: false);
      expect(normal.pixelProgress, isTrue);
      expect(normal.deferLibraryAnalysis, isFalse);
      expect(normal.downloadLimit, isNull);
      expect(normal.concurrentDownloads(4), 4);
      expect(normal.positionSaveInterval, const Duration(seconds: 5));
    });

    test("Low Power Mode does everything less often", () {
      for (final visible in [true, false]) {
        final normal = profile(lowPower: false, visible: visible);
        final low = profile(lowPower: true, visible: visible);
        expect(
          low.positionReportInterval,
          greaterThan(normal.positionReportInterval),
        );
        expect(
          low.positionSaveInterval,
          greaterThan(normal.positionSaveInterval),
        );
        expect(
          low.downloadNotifyInterval,
          greaterThanOrEqualTo(normal.downloadNotifyInterval),
        );
      }
      final low = profile(lowPower: true);
      expect(low.pixelProgress, isFalse);
      expect(low.deferLibraryAnalysis, isTrue);
      expect(low.concurrentDownloads(4), 1);
    });

    test("views extrapolate past the gap between position reports", () {
      for (final lowPower in [false, true]) {
        final shown = profile(lowPower: lowPower);
        // A report can miss a second when the clock's phase slips, so the
        // estimate must outlast two intervals before holding still.
        expect(
          shown.maxExtrapolationMs,
          greaterThan(shown.positionReportInterval.inMilliseconds * 2),
        );
      }
    });

    test("off screen reports less often than on screen", () {
      for (final lowPower in [false, true]) {
        expect(
          profile(lowPower: lowPower, visible: false).positionReportInterval,
          greaterThan(profile(lowPower: lowPower).positionReportInterval),
        );
      }
    });

    test("its options keep downloads and loudness work as they are", () {
      final low = profile(
        lowPower: true,
        limitDownloads: false,
        deferAnalysis: false,
      );
      expect(low.downloadLimit, isNull);
      expect(low.concurrentDownloads(3), 3);
      expect(low.deferLibraryAnalysis, isFalse);
    });
  });

  test("settings keep Low Power Mode and its options", () {
    final settings = AppSettings(downloadDirectory: "/music")
      ..lowPowerMode = LowPowerSetting.on
      ..lowPowerLimitDownloads = false
      ..lowPowerDeferAnalysis = false;
    final read = AppSettings.fromJson(
      settings.toJson(),
      defaultDownloadDirectory: "/music",
    );
    expect(read.lowPowerMode, LowPowerSetting.on);
    expect(read.lowPowerLimitDownloads, isFalse);
    expect(read.lowPowerDeferAnalysis, isFalse);

    // Settings saved before Low Power Mode existed follow the system.
    final older = AppSettings.fromJson(const {
      "download_directory": "/music",
    }, defaultDownloadDirectory: "/music");
    expect(older.lowPowerMode, LowPowerSetting.automatic);
    expect(older.lowPowerLimitDownloads, isTrue);
    expect(older.lowPowerDeferAnalysis, isTrue);
  });
}
