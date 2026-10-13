import "dart:io";

import "package:path/path.dart" as p;

/// Opens [path] in the system file manager (Explorer, Finder, or the
/// desktop's default), creating it first so a fresh install has something
/// to show. Desktop only: Android apps cannot browse their private storage.
Future<void> revealFolder(String path) async {
  final folder = p.normalize(p.absolute(path));
  await Directory(folder).create(recursive: true);
  final (executable, arguments) = Platform.isWindows
      ? ("explorer.exe", [folder])
      : Platform.isMacOS
      ? ("open", [folder])
      : ("xdg-open", [folder]);
  // Explorer exits with 1 even when it opens the folder, so the exit code
  // says nothing; only a failure to launch is reported.
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}
