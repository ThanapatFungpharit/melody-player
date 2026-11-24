/// How much work Melody does at a moment: the rates of its periodic work and
/// which optional background work runs, from Low Power Mode and from whether
/// anyone can see the window.
library;

/// The Low Power Mode setting.
enum LowPowerSetting {
  /// Never in Low Power Mode.
  off("off", "Off"),

  /// In Low Power Mode while the system saves power (Battery Saver, Low
  /// Power Mode, Energy Saver, or the power-saver profile).
  automatic("auto", "With the system's battery saver"),

  /// Always in Low Power Mode.
  on("on", "Always on");

  const LowPowerSetting(this.id, this.label);

  /// The stored value.
  final String id;
  final String label;

  static LowPowerSetting parse(Object? value) => values.firstWhere(
    (setting) => setting.id == value,
    orElse: () => automatic,
  );

  /// Whether Low Power Mode is on, given whether the system saves power.
  bool active({required bool systemSaving}) => switch (this) {
    off => false,
    on => true,
    automatic => systemSaving,
  };
}

/// The rates and switches one state calls for. Nothing here changes what
/// Melody plays, keeps, or downloads: only how often it looks and redraws,
/// and when optional work runs.
class PowerProfile {
  const PowerProfile._({
    required this.lowPower,
    required this.visible,
    required this.positionReportInterval,
    required this.positionSaveInterval,
    required this.downloadNotifyInterval,
    required this.maxExtrapolationMs,
    required this.pixelProgress,
    required this.deferLibraryAnalysis,
    required this.downloadLimit,
  });

  /// The profile for Low Power Mode on or off, on screen or not.
  factory PowerProfile.of({
    required bool lowPower,
    required bool visible,
    bool limitDownloads = true,
    bool deferAnalysis = true,
  }) {
    return PowerProfile._(
      lowPower: lowPower,
      visible: visible,
      // On screen the views extrapolate between reports, so these only keep
      // the estimate honest; off screen they feed the saved position, the
      // sleep timer, and skip detection, none of which needs more than this.
      positionReportInterval: switch ((lowPower, visible)) {
        (false, true) => const Duration(milliseconds: 500),
        (false, false) => const Duration(seconds: 1),
        (true, true) => const Duration(seconds: 1),
        (true, false) => const Duration(seconds: 5),
      },
      // What a crash can lose of the playback position. Pause, stop, a track
      // change, and leaving the screen save it at once either way.
      positionSaveInterval: lowPower
          ? const Duration(seconds: 30)
          : const Duration(seconds: 5),
      // A progress bar nobody sees needs no rebuilds; status changes are
      // published at once regardless.
      downloadNotifyInterval: switch ((lowPower, visible)) {
        (false, true) => const Duration(milliseconds: 200),
        (true, true) => const Duration(seconds: 1),
        (_, false) => const Duration(seconds: 5),
      },
      // Reports come further apart in Low Power Mode, so the estimate may
      // run further past the last one before it holds still.
      maxExtrapolationMs: lowPower ? 3000 : 1500,
      pixelProgress: !lowPower,
      deferLibraryAnalysis: lowPower && deferAnalysis,
      downloadLimit: lowPower && limitDownloads ? 1 : null,
    );
  }

  final bool lowPower;
  final bool visible;

  /// How often the engine reports the position of a playing track.
  final Duration positionReportInterval;

  /// How often a playing track's position is written to the database.
  final Duration positionSaveInterval;

  /// How often download progress is published to the views.
  final Duration downloadNotifyInterval;

  /// How far the views extrapolate the position past the last report.
  final int maxExtrapolationMs;

  /// Whether progress bars move with every device pixel rather than with
  /// the clock's seconds.
  final bool pixelProgress;

  /// Whether the library-wide loudness pass waits. What plays next is still
  /// measured, so normalization stays right for what is heard.
  final bool deferLibraryAnalysis;

  /// The most downloads that run at once, below the user's own limit; null
  /// leaves that limit alone.
  final int? downloadLimit;

  /// The user's download limit as this profile allows it.
  int concurrentDownloads(int setting) =>
      downloadLimit == null || setting < downloadLimit!
      ? setting
      : downloadLimit!;

  @override
  bool operator ==(Object other) =>
      other is PowerProfile &&
      other.lowPower == lowPower &&
      other.visible == visible &&
      other.deferLibraryAnalysis == deferLibraryAnalysis &&
      other.downloadLimit == downloadLimit;

  @override
  int get hashCode =>
      Object.hash(lowPower, visible, deferLibraryAnalysis, downloadLimit);
}
