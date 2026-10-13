import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:melody/application/cookie_files.dart";
import "package:path/path.dart" as p;

final _now = DateTime.utc(2026, 1, 1);
final _future = _now.millisecondsSinceEpoch ~/ 1000 + 3600;
final _past = _now.millisecondsSinceEpoch ~/ 1000 - 3600;

String _record({
  String domain = ".youtube.com",
  String subdomains = "TRUE",
  String path = "/",
  String secure = "TRUE",
  Object? expires,
  String name = "SID",
  String value = "abc",
}) => [
  domain,
  subdomains,
  path,
  secure,
  "${expires ?? _future}",
  name,
  value,
].join("\t");

ValidatedCookieFile _validate(String text) =>
    validateCookieFile(utf8.encode(text), now: _now);

Matcher _rejects(String message) => throwsA(
  isA<CookieFileError>().having((e) => e.message, "message", contains(message)),
);

void main() {
  group("validateCookieFile", () {
    test("accepts a Netscape export and normalizes line endings", () {
      final file = _validate(
        "﻿# Netscape HTTP Cookie File\r\n"
        "# comment\r\n"
        "\r\n"
        "${_record()}\r\n"
        "#HttpOnly_${_record(name: "HSID")}\r\n"
        "\r\n\r\n",
      );
      expect(file.cookieCount, 2);
      expect(
        utf8.decode(file.content),
        "# Netscape HTTP Cookie File\n# comment\n\n${_record()}\n"
        "#HttpOnly_${_record(name: "HSID")}\n",
      );
    });

    test("accepts the short header and session cookies", () {
      final file = _validate(
        "# HTTP Cookie File\n"
        "${_record(domain: "music.youtube.com", subdomains: "FALSE", expires: 0)}\n"
        "${_record(expires: "")}\n",
      );
      expect(file.cookieCount, 2);
    });

    test("counts expired cookies when at least one is usable", () {
      final file = _validate(
        "# Netscape HTTP Cookie File\n"
        "${_record(expires: _past)}\n"
        "${_record(name: "HSID")}\n",
      );
      expect(file.cookieCount, 2);
    });

    test("rejects empty, oversized, and binary files", () {
      expect(() => validateCookieFile([], now: _now), _rejects("is empty"));
      expect(
        () => validateCookieFile(
          List.filled(maxCookieFileSize + 1, 0x41),
          now: _now,
        ),
        _rejects("larger than 10 MB"),
      );
      expect(
        () => validateCookieFile([0x23, 0, 0x41], now: _now),
        _rejects("Unsupported cookie format"),
      );
      expect(
        () => validateCookieFile([0xc3, 0x28], now: _now),
        _rejects("must be UTF-8"),
      );
    });

    test("rejects files without a Netscape header", () {
      expect(
        () => _validate('[{"domain": ".youtube.com"}]'),
        _rejects("Unsupported cookie format"),
      );
    });

    test("reports the line of a malformed record", () {
      const header = "# Netscape HTTP Cookie File\n";
      expect(
        () => _validate("$header\n.youtube.com\tTRUE\t/\n"),
        _rejects("Invalid Netscape cookie record on line 3."),
      );
      expect(
        () => _validate("$header${_record(path: "")}\n"),
        _rejects("Incomplete Netscape cookie record on line 2."),
      );
      expect(
        () => _validate("$header${_record(name: "", value: "")}\n"),
        _rejects("Incomplete Netscape cookie record on line 2."),
      );
      expect(
        () => _validate("$header${_record(secure: "yes")}\n"),
        _rejects("Invalid cookie flags on line 2;"),
      );
      expect(
        () => _validate("$header${_record(subdomains: "FALSE")}\n"),
        _rejects("Invalid cookie domain flags on line 2."),
      );
      expect(
        () => _validate("$header${_record(expires: "soon")}\n"),
        _rejects("Invalid cookie expiry value on line 2."),
      );
    });

    test("rejects files without cookies or with only expired ones", () {
      expect(
        () => _validate("# Netscape HTTP Cookie File\n# only comments\n"),
        _rejects("does not contain any cookies"),
      );
      expect(
        () => _validate(
          "# Netscape HTTP Cookie File\n${_record(expires: _past)}\n",
        ),
        _rejects("have expired"),
      );
    });
  });

  test("installCookieFile writes the normalized contents", () async {
    final root = await Directory.systemTemp.createTemp("melody-cookies");
    addTearDown(() => root.delete(recursive: true));
    final file = _validate("# Netscape HTTP Cookie File\n${_record()}");
    final destination = p.join(root.path, "private", "cookies.txt");
    expect(await installCookieFile(file, destination), destination);
    expect(await File(destination).readAsBytes(), file.content);
  });
}
