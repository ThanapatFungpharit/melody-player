import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../application/models.dart";
import "../../shared/actions.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobileDownloads extends StatelessWidget {
  const MobileDownloads(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.services.downloads,
    builder: (context, _) {
      final records = app.services.downloads.list();
      final active = [
        for (final r in records)
          if (r.status.isActive) r,
      ];
      final issues = [
        for (final r in records)
          if (r.status.isUnsuccessful) r,
      ];
      final failed = issues
          .where((r) => r.status == DownloadStatus.failed)
          .length;
      final completed = [
        for (final r in records)
          if (r.status == DownloadStatus.completed) r,
      ];
      return scrollPage([
        MobileHeading(
          "Downloads",
          subtitle: "${active.length} active · ${issues.length} need attention",
          large: true,
          actions: [
            TouchIconButton(
              Icons.arrow_back_rounded,
              "Back",
              () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: MoreButton(
            "Download actions",
            () => [
              MenuAction(
                "Clear download history",
                Icons.cleaning_services_rounded,
                app.services.downloads.clearFinished,
                enabled: issues.isNotEmpty || completed.isNotEmpty,
              ),
            ],
          ),
        ),
        for (final (label, items) in [
          ("Needs attention", issues),
          ("In progress", active),
          ("Completed", completed),
        ])
          if (items.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (identical(items, issues) && failed > 0)
                  TextButton.icon(
                    onPressed: () => retryFailed(app),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text("Retry all"),
                  ),
              ],
            ),
            for (final record in items) _DownloadCard(app, record),
          ],
        if (records.isEmpty)
          const EmptyState(
            Icons.download_done_rounded,
            "Download songs from Search to listen offline.",
          ),
      ]);
    },
  );
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard(this.app, this.record);

  final MelodyApp app;
  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = record.status.isActive;
    final playable = record.trackIds
        .where(app.services.manager.hasTrack)
        .toList();
    final Widget? action = active
        ? TextButton.icon(
            onPressed: () => app.services.downloads.cancel(record.id),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text("Cancel"),
          )
        : record.status.isUnsuccessful
        ? FilledButton.icon(
            onPressed: () =>
                app.run(() => app.services.downloads.retry(record.id)),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text("Retry"),
          )
        : playable.isNotEmpty
        ? TextButton.icon(
            onPressed: () => app.playback.playTracks(playable),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text("Play"),
          )
        : null;
    final status = downloadStatusLabel(record.status);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Artwork(
                app,
                record.thumbnail,
                size: 48,
                seed: record.title,
                playlist: record.kind == "playlist",
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [
                    Text(
                      record.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleSmall,
                    ),
                    Text(
                      record.batchSize > 1
                          ? "Song ${record.batchPosition} of ${record.batchSize}"
                          : (record.uploader.isNotEmpty
                                ? record.uploader
                                : record.source),
                      style: context.text.bodySmall,
                    ),
                    Text(
                      record.error.isNotEmpty
                          ? record.error
                          : downloadDetail(record),
                      style: context.text.bodySmall!.copyWith(
                        color: record.error.isNotEmpty ? scheme.error : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (active)
            LinearProgressIndicator(
              value: record.progress > 0 ? record.progress : null,
              minHeight: 4,
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  status,
                  style: context.text.labelMedium!.copyWith(
                    color: record.status.isUnsuccessful
                        ? scheme.error
                        : record.status == DownloadStatus.completed
                        ? context.palette.success
                        : scheme.primary,
                  ),
                ),
              ),
              ?action,
            ],
          ),
        ],
      ),
    );
  }
}
