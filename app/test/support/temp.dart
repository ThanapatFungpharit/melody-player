import "dart:io";

/// A fresh temporary directory under its long, canonical path. Windows can
/// hand out 8.3 short names (`RUNNER~1`), which never compare equal to the
/// paths the code under test resolves.
Future<Directory> createTestDirectory(String prefix) async {
  final created = await Directory.systemTemp.createTemp(prefix);
  return Directory(await created.resolveSymbolicLinks());
}

/// Deletes [directory], waiting for whatever is still letting go of a file in
/// it: Windows refuses to delete a file another handle has open.
Future<void> deleteTestDirectory(Directory directory) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 100) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
