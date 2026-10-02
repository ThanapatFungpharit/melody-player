import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../../application/models.dart";
import "../../shared/format.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "../shell.dart";

const _activeStatuses = {"queued", "downloading", "processing"};

Color statusColor(BuildContext context, DownloadRecord record) {
  final scheme = Theme.of(context).colorScheme;
  if (record.status == "completed") return Colors.green.shade400;
  if (record.status == "failed") return scheme.error;
  return scheme.primary;
}

String statusLabel(String status) => status
    .split("_")
    .map((word) => word.isEmpty ? word : "${word[0].toUpperCase()}${word.substring(1)}")
    .join(" ");

class DownloadsPanel extends StatelessWidget {
  const DownloadsPanel(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.services.downloads,
    builder: (context, _) {
      final records = app.services.downloads.list();
      final batches = <String, List<DownloadRecord>>{};
      var active = 0;
      var completed = 0;
      var issues = 0;
      for (final record in records) {
        if (record.batchId.isNotEmpty) batches.putIfAbsent(record.batchId, () => []).add(record);
        if (_activeStatuses.contains(record.status)) {
          active++;
        } else if (record.status == "completed") {
          completed++;
        } else {
          issues++;
        }
      }
      final scheme = Theme.of(context).colorScheme;
      return ListView(
        children: [
          ContextHeader(
            app,
            "Downloads",
            "Save it here. Take it with you.",
            actions: [
              TextButton.icon(
                onPressed: completed + issues == 0 ? null : app.services.downloads.clearFinished,
                icon: const Icon(Icons.cleaning_services_rounded),
                label: const Text("Clear download history"),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ResponsiveGrid(
            children: [
              for (final (label, value, icon, color) in [
                ("Active", active, Icons.downloading_rounded, scheme.primary),
                ("Completed", completed, Icons.check_circle_outline_rounded, Colors.green.shade400),
                ("Needs attention", issues, Icons.error_outline_rounded, scheme.error),
                ("History", records.length, Icons.history_rounded, scheme.onSurfaceVariant),
              ])
                GridCell(_Metric(label, "$value", icon, color), sm: 6, lg: 3),
            ],
          ),
          if (batches.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text("Recent batches", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ResponsiveGrid(
              children: [
                for (final items in batches.values.take(3)) GridCell(_BatchOverview(items), lg: 6),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text("Download activity", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Text(plural(records.length, "item"), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 12),
          if (records.isEmpty)
            const EmptyState(
              Icons.download_done_rounded,
              "Your download history is empty. New downloads will appear here with live progress and actions.",
            )
          else
            ResponsiveGrid(
              children: [for (final record in records) GridCell(_DownloadRow(app, record), lg: 6)],
            ),
        ],
      );
    },
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.icon, this.color);

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Surface(
      padding: const EdgeInsets.all(16),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color, size: 24),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _BatchOverview extends StatelessWidget {
  const _BatchOverview(this.records);

  final List<DownloadRecord> records;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = records.first.batchSize > 0 ? records.first.batchSize : records.length;
    final completed = records.where((record) => record.status == "completed").length;
    final failed = records.where((record) => const {"failed", "cancelled"}.contains(record.status)).length;
    final finished = completed + failed;
    final active = total - finished;
    return Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(Icons.download_rounded, color: failed > 0 ? scheme.error : scheme.primary),
              Expanded(
                child: Text(
                  "Batch download • $finished of $total finished",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          Text(
            active > 0
                ? "$active active • $completed completed • $failed failed"
                : "Finished • $completed completed • $failed failed",
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          LinearProgressIndicator(
            value: total > 0 ? (finished / total).clamp(0.0, 1.0) : 0,
            color: failed > 0 && active == 0 ? scheme.error : scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
            minHeight: 6,
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow(this.app, this.record);

  final MelodyApp app;
  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _activeStatuses.contains(record.status);
    final completed = record.status == "completed";
    final playable = record.trackIds.where(app.services.manager.hasTrack).toList();
    final color = statusColor(context, record);
    var credit = record.uploader.isNotEmpty ? record.uploader : record.source;
    if (record.batchSize > 1) {
      credit = "Batch song ${record.batchPosition} of ${record.batchSize} • $credit";
    }
    final Widget? action = active
        ? IconButton(
            onPressed: () => app.services.downloads.cancel(record.id),
            tooltip: "Cancel",
            icon: const Icon(Icons.cancel_outlined),
          )
        : const {"failed", "cancelled"}.contains(record.status)
        ? FilledButton.icon(
            onPressed: () => app.run(() => app.services.downloads.retry(record.id)),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text("Retry"),
          )
        : completed && playable.isNotEmpty
        ? IconButton(
            onPressed: () => app.playback.playTracks(playable),
            tooltip: "Play",
            icon: const Icon(Icons.play_arrow_rounded),
          )
        : null;
    return Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        spacing: 12,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 14,
            children: [
              Artwork(app, record.thumbnail, size: 56, playlist: record.kind == "playlist"),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      record.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    Text(credit, maxLines: 1, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    Text(
                      record.error.isNotEmpty ? record.error : downloadDetail(record),
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 12,
                        color: record.error.isNotEmpty ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 8,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      statusLabel(record.status),
                      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
                    ),
                  ),
                  ?action,
                ],
              ),
            ],
          ),
          LinearProgressIndicator(
            value: active || completed ? record.progress : 0,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
            minHeight: 6,
          ),
        ],
      ),
    );
  }
}
