import "dart:io";

/// A fresh temporary directory under its long, canonical path. Windows can
/// hand out 8.3 short names (`RUNNER~1`), which never compare equal to the
/// paths the code under test resolves.
Future<Directory> createTestDirectory(String prefix) async {
  final created = await Directory.systemTemp.createTemp(prefix);
  return Directory(await created.resolveSymbolicLinks());
}
