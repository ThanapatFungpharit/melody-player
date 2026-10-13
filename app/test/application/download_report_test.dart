import "package:flutter_test/flutter_test.dart";
import "package:melody/application/download_report.dart";
import "package:melody/application/downloads.dart";
import "package:melody/application/models.dart";
import "package:melody/ui/controllers/search_controller.dart";
import "package:melody/ui/shared/format.dart";

DownloadRecord _record(
  String id,
  String video,
  DownloadStatus status, {
  String error = "",
}) => DownloadRecord(
  id: id,
  url: "https://music.youtube.com/watch?v=$video",
  title: "Song $video",
  status: status,
  error: error,
);

void main() {
  test("reports once the downloads settle", () {
    final reporter = DownloadReporter()
      ..add(_record("1", "aaaaaaaaaaa", DownloadStatus.completed));
    expect(reporter.settle(active: 1), isNull);
    reporter.add(_record("2", "bbbbbbbbbbb", DownloadStatus.failed));
    final report = reporter.settle(active: 0)!;
    expect(report.completed.map((record) => record.id), ["1"]);
    expect(report.failed.map((record) => record.id), ["2"]);
    // Reported once.
    expect(reporter.settle(active: 0), isNull);
  });

  test("a song's latest outcome wins and cancellations are dropped", () {
    final reporter = DownloadReporter()
      ..add(_record("1", "aaaaaaaaaaa", DownloadStatus.failed))
      ..add(_record("2", "aaaaaaaaaaa", DownloadStatus.completed))
      ..add(_record("3", "bbbbbbbbbbb", DownloadStatus.cancelled))
      ..add(_record("4", "ccccccccccc", DownloadStatus.downloading));
    final report = reporter.settle(active: 0)!;
    expect(report.completed.map((record) => record.id), ["2"]);
    expect(report.failed, isEmpty);
    // Only a cancellation: nothing to report.
    reporter.add(_record("5", "ddddddddddd", DownloadStatus.cancelled));
    expect(reporter.settle(active: 0), isNull);
  });

  test("report messages name single songs and count several", () {
    final done = _record("1", "aaaaaaaaaaa", DownloadStatus.completed);
    final also = _record("2", "bbbbbbbbbbb", DownloadStatus.completed);
    final failed = _record(
      "3",
      "ccccccccccc",
      DownloadStatus.failed,
      error: "The video is private.",
    );
    final other = _record("4", "ddddddddddd", DownloadStatus.failed);
    expect(
      downloadReportMessage(DownloadReport([done], const [])),
      "Downloaded “Song aaaaaaaaaaa”.",
    );
    expect(
      downloadReportMessage(DownloadReport([done, also], const [])),
      "Downloaded 2 songs.",
    );
    expect(
      downloadReportMessage(DownloadReport(const [], [failed])),
      "Couldn’t download “Song ccccccccccc”: The video is private.",
    );
    expect(
      downloadReportMessage(DownloadReport([done, also], [failed])),
      "Downloaded 2 songs; “Song ccccccccccc” failed.",
    );
    expect(
      downloadReportMessage(DownloadReport(const [], [failed, other])),
      "2 downloads failed.",
    );
  });

  test("batch messages say what happened to every song", () {
    String message(
      int size,
      int started,
      int joined,
      int existing,
      int failed,
    ) => MusicSearchController.batchDownloadMessage(
      DownloadBatch(
        "batch",
        [for (var i = 0; i < started + joined; i++) "$i"],
        size,
        started: started,
        existing: existing,
        failed: failed,
      ),
    );
    expect(message(3, 3, 0, 0, 0), "Downloading 3 songs.");
    expect(
      message(4, 1, 1, 1, 1),
      "Downloading 1 song. 1 already in your library, 1 already downloading "
      "and 1 couldn’t start.",
    );
    expect(
      message(2, 0, 0, 2, 0),
      "Nothing new to download. 2 already in your library.",
    );
    expect(
      message(1, 0, 0, 0, 1),
      "No songs could be downloaded. 1 couldn’t start.",
    );
  });
}
