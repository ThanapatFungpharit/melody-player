import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../application/models.dart";
import "../../shared/actions.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "../shell.dart";

Color statusColor(BuildContext context, DownloadRecord record) {
  if (record.status == DownloadStatus.completed) {
    return context.palette.success;
  }
  if (record.status == DownloadStatus.failed) return context.colors.error;
  return context.colors.primary;
}

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
      var failed = 0;
      for (final record in records) {
        if (record.status == DownloadStatus.failed) failed++;
        if (record.batchId.isNotEmpty) {
          batches.putIfAbsent(record.batchId, () => []).add(record);
        }
        if (record.status.isActive) {
          active++;
        } else if (record.status == DownloadStatus.completed) {
          completed++;
        } else {
          issues++;
        }
      }
      final scheme = context.colors;
      return ListView(
        children: [
          ContextHeader(
            app,
            "Downloads",
            "Save it here. Take it with you.",
            actions: [
              TextButton.icon(
                onPressed: failed == 0 ? null : () => retryFailed(app),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text("Retry failed ($failed)"),
              ),
              TextButton.icon(
                onPressed: completed + issues == 0
                    ? null
                    : app.services.downloads.clearFinished,
                icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                label: const Text("Clear download history"),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Radii.large),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  for (final (index, (label, value, icon, color)) in [
                    (
                      "Active",
                      active,
                      Icons.downloading_rounded,
                      scheme.primary,
                    ),
                    (
                      "Completed",
                      completed,
                      Icons.check_circle_outline_rounded,
                      context.palette.success,
                    ),
                    (
                      "Needs attention",
                      issues,
                      Icons.error_outline_rounded,
                      scheme.error,
                    ),
                    (
                      "History",
                      records.length,
                      Icons.history_rounded,
                      scheme.onSurfaceVariant,
                    ),
                  ].indexed) ...[
                    if (index > 0)
                      VerticalDivider(color: scheme.outlineVariant),
                    Expanded(child: _Metric(label, "$value", icon, color)),
                  ],
                ],
              ),
            ),
          ),
          if (batches.isNotEmpty) ...[
            const SizedBox(height: 28),
            const SectionTitle("Recent batches"),
            const SizedBox(height: 12),
            ResponsiveGrid(
              spacing: 12,
              children: [
                for (final items in batches.values.take(3))
                  GridCell(_BatchOverview(items), lg: 6),
              ],
            ),
          ],
          const SizedBox(height: 28),
          SectionTitle(
            "Download activity",
            trailing: [
              Text(
                plural(records.length, "item"),
                style: context.text.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (records.isEmpty)
            const EmptyState(Icons.download_done_rounded, "No downloads yet.")
          else
            for (final (index, record) in records.indexed) ...[
              if (index > 0)
                Divider(color: scheme.outlineVariant.withValues(alpha: 0.6)),
              _DownloadRow(app, record),
            ],
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Row(
          spacing: 6,
          children: [
            Icon(icon, color: color, size: 16),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall,
              ),
            ),
          ],
        ),
        Text(
          value,
          style: context.text.headlineMedium!.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class _BatchOverview extends StatelessWidget {
  const _BatchOverview(this.records);

  final List<DownloadRecord> records;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final total = records.first.batchSize > 0
        ? records.first.batchSize
        : records.length;
    final completed = records
        .where((record) => record.status == DownloadStatus.completed)
        .length;
    final failed = records
        .where((record) => record.status.isUnsuccessful)
        .length;
    final finished = completed + failed;
    final active = total - finished;
    return Surface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(
                Icons.download_rounded,
                size: 20,
                color: failed > 0 ? scheme.error : scheme.primary,
              ),
              Expanded(
                child: Text(
                  "Batch download • $finished of $total finished",
                  style: context.text.titleSmall,
                ),
              ),
            ],
          ),
          Text(
            active > 0
                ? "$active active • $completed completed • $failed failed"
                : "Finished • $completed completed • $failed failed",
            style: context.text.bodySmall,
          ),
          LinearProgressIndicator(
            value: total > 0 ? (finished / total).clamp(0.0, 1.0) : 0,
            color: failed > 0 && active == 0 ? scheme.error : scheme.primary,
            minHeight: 5,
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
    final scheme = context.colors;
    final active = record.status.isActive;
    final completed = record.status == DownloadStatus.completed;
    final playable = record.trackIds
        .where(app.services.manager.hasTrack)
        .toList();
    final color = statusColor(context, record);
    var credit = record.uploader.isNotEmpty ? record.uploader : record.source;
    if (record.batchSize > 1) {
      credit =
          "Batch song ${record.batchPosition} of ${record.batchSize} • $credit";
    }
    final Widget? action = active
        ? IconButton(
            onPressed: () => app.services.downloads.cancel(record.id),
            tooltip: "Cancel",
            icon: const Icon(Icons.close_rounded),
          )
        : record.status.isUnsuccessful
        ? OutlinedButton.icon(
            onPressed: () =>
                app.run(() => app.services.downloads.retry(record.id)),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text("Retry"),
          )
        : completed && playable.isNotEmpty
        ? IconButton(
            onPressed: () => app.playback.playTracks(playable),
            tooltip: "Play",
            icon: const Icon(Icons.play_arrow_rounded),
          )
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          Artwork(
            app,
            record.thumbnail,
            size: 52,
            seed: record.title,
            playlist: record.kind == "playlist",
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                Row(
                  spacing: 10,
                  children: [
                    Flexible(
                      child: Text(
                        record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleSmall,
                      ),
                    ),
                    Pill(downloadStatusLabel(record.status), color: color),
                  ],
                ),
                Text(
                  credit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall,
                ),
                Text(
                  record.error.isNotEmpty
                      ? record.error
                      : downloadDetail(record),
                  maxLines: 2,
                  style: context.text.bodySmall!.copyWith(
                    color: record.error.isNotEmpty ? scheme.error : null,
                  ),
                ),
                if (active) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: record.progress > 0 ? record.progress : null,
                    color: color,
                    minHeight: 4,
                  ),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
