import "../core/media.dart";
import "models.dart";

/// What finished since the downloads were last idle: each song's latest
/// outcome, so a failure that a retry fixed counts only as completed.
class DownloadReport {
  const DownloadReport(this.completed, this.failed);

  final List<DownloadRecord> completed;
  final List<DownloadRecord> failed;

  bool get hasFailures => failed.isNotEmpty;
}

/// Gathers finished downloads into one [DownloadReport] per burst of
/// activity, instead of a message for every song. Cancellations are the
/// user's own doing and are not reported.
class DownloadReporter {
  final Map<String, DownloadRecord> _outcomes = {};

  void add(DownloadRecord record) {
    if (!record.status.isFinished) return;
    final key = sourceKey(record.url);
    final song = key.isEmpty ? record.id : key;
    if (record.status == DownloadStatus.cancelled) {
      _outcomes.remove(song);
    } else {
      // Re-inserted, so the report lists songs in the order they finished.
      _outcomes
        ..remove(song)
        ..[song] = record;
    }
  }

  /// The report, once nothing is downloading and something finished.
  DownloadReport? settle({required int active}) {
    if (active > 0 || _outcomes.isEmpty) return null;
    final records = _outcomes.values.toList();
    _outcomes.clear();
    return DownloadReport(
      [
        for (final record in records)
          if (record.status == DownloadStatus.completed) record,
      ],
      [
        for (final record in records)
          if (record.status == DownloadStatus.failed) record,
      ],
    );
  }
}
