import "../../application/models.dart";

String formatDuration(double seconds) {
  if (seconds <= 0) return "—";
  final total = seconds.toInt();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final secs = (total % 60).toString().padLeft(2, "0");
  return hours > 0
      ? "$hours:${minutes.toString().padLeft(2, "0")}:$secs"
      : "$minutes:$secs";
}

String formatMilliseconds(int milliseconds) =>
    milliseconds > 0 ? formatDuration(milliseconds / 1000) : "0:00";

String formatBytes(int value) {
  var size = value.toDouble();
  for (final unit in const ["B", "KB", "MB", "GB"]) {
    if (size < 1024 || unit == "GB") {
      return unit == "B"
          ? "${size.toStringAsFixed(0)} $unit"
          : "${size.toStringAsFixed(1)} $unit";
    }
    size /= 1024;
  }
  return "${size.toStringAsFixed(1)} GB";
}

String downloadStatusLabel(DownloadStatus status) =>
    "${status.name[0].toUpperCase()}${status.name.substring(1)}";

String downloadDetail(DownloadRecord record) {
  if (record.status == DownloadStatus.completed) {
    return "Added ${plural(record.trackIds.length, "track")} to your library";
  }
  if (record.status == DownloadStatus.processing) {
    return "Converting audio…";
  }
  if (record.totalBytes > 0) {
    return "${formatBytes(record.downloadedBytes)} of ${formatBytes(record.totalBytes)} • "
        "${(record.progress * 100).round()}%";
  }
  if (record.batchId.isNotEmpty && record.url.isNotEmpty) return record.url;
  return record.filename.isNotEmpty ? record.filename : record.source;
}

String timeGreeting([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

String plural(int count, String word) => "$count $word${count != 1 ? "s" : ""}";
