import "dart:io";

/// Features that only some platforms have. Settings for a feature the
/// running platform lacks are shown disabled, with the reason.
/// docs/platform-support.md lists the same differences for users.
abstract final class PlatformFeatures {
  /// Custom buttons in the media notification. Windows and Apple controls
  /// have only built-in buttons.
  static bool get notificationShortcuts => Platform.isAndroid;

  /// Adding a whole folder of music. On Android, files are picked one by one.
  static bool get folderImport => !Platform.isAndroid;

  /// Showing and opening the app data folder. Android keeps it private.
  static bool get appDataFolder => !Platform.isAndroid;
}
