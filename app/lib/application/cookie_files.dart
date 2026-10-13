import "dart:convert";
import "dart:io";

import "../core/storage.dart";

const maxCookieFileSize = 10 * 1024 * 1024;
final _netscapeHeader = RegExp(
  r"^#(?: Netscape)? HTTP Cookie File\b",
  caseSensitive: false,
);

/// An uploaded cookie file is unsafe or unsupported.
class CookieFileError implements Exception {
  CookieFileError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Normalized Netscape cookie-file contents ready for private storage.
class ValidatedCookieFile {
  const ValidatedCookieFile(this.content, this.cookieCount);

  final List<int> content;
  final int cookieCount;
}

/// Validates and normalizes a Netscape/Mozilla `cookies.txt` export.
///
/// Browser-extension JSON exports, browser databases, and arbitrary text are
/// rejected before anything is persisted or passed to yt-dlp.
ValidatedCookieFile validateCookieFile(List<int> content, {DateTime? now}) {
  if (content.isEmpty) {
    throw CookieFileError("The selected cookie file is empty.");
  }
  if (content.length > maxCookieFileSize) {
    throw CookieFileError("The selected cookie file is larger than 10 MB.");
  }
  if (content.contains(0)) {
    throw CookieFileError(
      "Unsupported cookie format. Upload a Netscape cookies.txt file.",
    );
  }
  String text;
  try {
    text = utf8.decode(content);
  } on FormatException {
    throw CookieFileError(
      "Cookie files must be UTF-8 text in Netscape cookies.txt format.",
    );
  }
  if (text.startsWith("﻿")) text = text.substring(1);
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || !_netscapeHeader.hasMatch(lines.first.trim())) {
    throw CookieFileError(
      "Unsupported cookie format. Upload a Netscape cookies.txt file.",
    );
  }
  final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  var cookies = 0;
  var usable = 0;
  for (var index = 1; index < lines.length; index++) {
    final number = index + 1;
    var line = lines[index];
    if (line.startsWith("#HttpOnly_")) {
      line = line.substring("#HttpOnly_".length);
    } else if (line.trim().isEmpty ||
        line.trimLeft().startsWith("#") ||
        line.trimLeft().startsWith(r"$")) {
      continue;
    }
    final fields = line.split("\t");
    if (fields.length != 7) {
      throw CookieFileError("Invalid Netscape cookie record on line $number.");
    }
    final [domain, subdomains, path, secure, expires, name, value] = fields;
    if (domain.isEmpty || path.isEmpty || (name.isEmpty && value.isEmpty)) {
      throw CookieFileError(
        "Incomplete Netscape cookie record on line $number.",
      );
    }
    const flags = {"TRUE", "FALSE"};
    if (!flags.contains(subdomains) || !flags.contains(secure)) {
      throw CookieFileError(
        "Invalid cookie flags on line $number; expected TRUE or FALSE.",
      );
    }
    if ((subdomains == "TRUE") != domain.startsWith(".")) {
      throw CookieFileError("Invalid cookie domain flags on line $number.");
    }
    int? expiry;
    if (expires.isNotEmpty) {
      expiry = int.tryParse(expires);
      if (expiry == null) {
        throw CookieFileError("Invalid cookie expiry value on line $number.");
      }
    }
    cookies++;
    if (expiry == null || expiry == 0 || expiry > nowSeconds) usable++;
  }
  if (cookies == 0) {
    throw CookieFileError("The selected file does not contain any cookies.");
  }
  if (usable == 0) {
    throw CookieFileError(
      "All cookies in this file have expired. Export and upload a fresh cookies.txt file.",
    );
  }
  final normalized = "${lines.join("\n").replaceAll(RegExp(r"\n+$"), "")}\n";
  return ValidatedCookieFile(utf8.encode(normalized), cookies);
}

/// Atomically installs a validated cookie file in app-private storage.
Future<String> installCookieFile(
  ValidatedCookieFile cookieFile,
  String destination,
) async {
  await atomicWrite(destination, cookieFile.content);
  if (!Platform.isWindows) {
    try {
      await Process.run("chmod", ["600", destination]);
    } on ProcessException {
      // Some Android-backed filesystems do not expose POSIX permissions.
    }
  }
  return destination;
}
