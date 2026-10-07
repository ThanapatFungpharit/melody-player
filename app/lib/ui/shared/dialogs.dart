import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";

import "../app_state.dart";
import "../../application/downloads.dart";
import "../../application/library_service.dart";
import "../../application/models.dart";
import "../../core/errors.dart" show failureMessage;
import "../../core/library/models.dart";
import "../../core/media.dart";
import "../controllers/search_controller.dart";
import "format.dart";
import "widgets.dart";

final _audioExtensions = [
  for (final suffix in audioSuffixes) suffix.substring(1),
];
const _dialogInsets = EdgeInsets.symmetric(horizontal: 16, vertical: 24);

double _dialogWidth(BuildContext context) =>
    (MediaQuery.sizeOf(context).width - 80).clamp(160.0, 560.0);

/// A text prompt with Cancel/confirm. [onConfirm] may throw a
/// [FormatException] whose message is shown under the field.
Future<void> showTextPrompt(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  String initial = "",
  String? hint,
  String? description,
  IconData? confirmIcon,
  required Future<void> Function(String value) onConfirm,
}) {
  final controller = TextEditingController(text: initial);
  String? error;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> submit() async {
          try {
            await onConfirm(controller.text);
            if (context.mounted) Navigator.of(context).pop();
          } on FormatException catch (failure) {
            // The dialog may have been dismissed while [onConfirm] ran.
            if (context.mounted) setState(() => error = failure.message);
          } on ArgumentError catch (failure) {
            if (context.mounted) setState(() => error = "${failure.message}");
          }
        }

        return AlertDialog(
          insetPadding: _dialogInsets,
          title: Text(title),
          content: SizedBox(
            width: _dialogWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (description != null) ...[
                  Text(description),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: label,
                    hintText: hint,
                    errorText: error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
            FilledButton.icon(
              onPressed: submit,
              icon: confirmIcon == null ? null : Icon(confirmIcon),
              label: Text(confirmLabel),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  IconData icon = Icons.delete_outline_rounded,
  bool prominent = false,
  bool warning = false,
  required Future<void> Function() onConfirm,
}) => showDialog<void>(
  context: context,
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: _dialogInsets,
      icon: warning
          ? Icon(Icons.warning_amber_rounded, color: scheme.error, size: 32)
          : null,
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: prominent ? scheme.error : null,
            foregroundColor: prominent ? scheme.onError : null,
          ),
          onPressed: () async {
            Navigator.of(context).pop();
            await onConfirm();
          },
          icon: Icon(icon),
          label: Text(confirmLabel),
        ),
      ],
    );
  },
);

Future<void> showDetailsDialog(
  BuildContext context,
  String title,
  List<(String, String)> rows, {
  String? footer,
}) => showDialog<void>(
  context: context,
  builder: (context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      insetPadding: _dialogInsets,
      title: Text(title),
      content: SizedBox(
        width: _dialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(label, style: TextStyle(color: muted)),
                      ),
                      Expanded(child: SelectableText(value, maxLines: 3)),
                    ],
                  ),
                ),
              if (footer != null)
                SelectableText(footer, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    );
  },
);

// -- tracks ----------------------------------------------------------------

Future<void> showRenameTrackDialog(
  BuildContext context,
  MelodyApp app,
  Track track,
) => showTextPrompt(
  context,
  title: "Edit track title",
  label: "Track title",
  initial: track.displayTitle,
  confirmLabel: "Save",
  onConfirm: (value) async => app.library.renameTrack(track.id, value),
);

Future<void> showTrackDetailsDialog(
  BuildContext context,
  MelodyApp app,
  Track track,
) {
  final details = app.services.library.details(track.id);
  String path;
  try {
    path = app.services.manager.trackPath(track.id);
  } on ArgumentError {
    path = "Unavailable";
  }
  return showDetailsDialog(context, "Track details", [
    ("Title", track.displayTitle),
    ("Uploader / channel", details.uploader.isEmpty ? "—" : details.uploader),
    ("Duration", formatDuration(details.duration)),
    (
      "Source",
      details.sourceName.isNotEmpty
          ? details.sourceName
          : (track.source.isNotEmpty ? track.source : "Local"),
    ),
    ("File", path),
  ]);
}

Future<void> showDeleteTrackDialog(
  BuildContext context,
  MelodyApp app,
  Track track,
) => showConfirmDialog(
  context,
  title: "Delete track?",
  message:
      "“${track.displayTitle}” will be removed from the library and every playlist. "
      "A file Melody downloaded is deleted; an imported file stays on disk.",
  confirmLabel: "Delete track",
  icon: Icons.delete_forever_rounded,
  onConfirm: () async {
    try {
      await app.library.deleteTrack(track.id);
    } on FileSystemException catch (error) {
      app.showError(
        "The track could not be deleted completely: ${error.message}",
      );
    } catch (error) {
      app.reportFailure(error);
    }
  },
);

Future<void> showSearchResultDetails(
  BuildContext context,
  SearchResult result,
) => showDetailsDialog(context, result.title, [
  (
    "Uploader / channel",
    result.uploader.isEmpty ? "Unknown uploader" : result.uploader,
  ),
  ("Source", result.source),
  ("Type", result.isPlaylist ? "Playlist" : "Track"),
  if (result.duration > 0) ("Duration", formatDuration(result.duration)),
  if (result.entryCount > 0) ("Tracks", "${result.entryCount}"),
], footer: result.url);

// -- playlists ---------------------------------------------------------------

Future<void> showCreatePlaylistDialog(BuildContext context, MelodyApp app) =>
    showTextPrompt(
      context,
      title: "New playlist",
      label: "Playlist name",
      confirmLabel: "Create",
      onConfirm: (value) async {
        app.playlists.create(value);
        app.navigate(3);
      },
    );

Future<void> showRenamePlaylistDialog(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) => showTextPrompt(
  context,
  title: "Rename playlist",
  label: "Playlist name",
  initial: playlist.name,
  confirmLabel: "Save",
  onConfirm: (value) async => app.playlists.rename(playlist.id, value),
);

Future<void> showDeletePlaylistDialog(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) => showConfirmDialog(
  context,
  title: "Delete playlist?",
  message:
      "Delete “${playlist.name}”? Your downloaded tracks will stay in the library.",
  confirmLabel: "Delete",
  onConfirm: () => app.run(() => app.playlists.delete(playlist.id)),
);

Future<void> showImportPlaylistDialog(BuildContext context, MelodyApp app) {
  if (app.playlists.importing) {
    app.showError("A playlist import is already in progress.");
    return Future.value();
  }
  return showTextPrompt(
    context,
    title: "Import playlist",
    label: "$youtubeMusicName playlist URL",
    hint: "https://music.youtube.com/playlist?list=…",
    description:
        "Paste a $youtubeMusicName playlist link. Melody will reuse tracks already in "
        "your library and download only the missing ones.",
    confirmLabel: "Import playlist",
    confirmIcon: Icons.download_rounded,
    onConfirm: (value) async {
      final url = value.trim();
      if (!isYoutubePlaylistUrl(url)) {
        throw const FormatException(
          "Paste a complete $youtubeMusicName playlist URL.",
        );
      }
      app.showMessage("Loading the $youtubeMusicName playlist…");
      app.playlists.importFromUrl(url);
    },
  );
}

/// Picks several library tracks to add to [playlist] at once.
Future<void> showBulkAddTracksDialog(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) {
  final members = playlist.trackIds.toSet();
  final candidates = [
    for (final track in app.services.manager.listTracks())
      if (!members.contains(track.id)) track,
  ];
  final selected = <String>{};
  var query = "";
  var offset = 0;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final matching = [
          for (final track in candidates)
            if (query.isEmpty ||
                track.displayTitle.toLowerCase().contains(query))
              track,
        ];
        final (start, end) = pageBounds(matching.length, offset);
        offset = start;
        final visible = matching.sublist(start, end);
        final details = app.services.library.detailsMany(
          visible.map((track) => track.id),
        );
        final muted = Theme.of(context).colorScheme.onSurfaceVariant;
        return AlertDialog(
          insetPadding: _dialogInsets,
          title: Text("Add tracks to “${playlist.name}”"),
          content: SizedBox(
            width: _dialogWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: "Find a track",
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) => setState(() {
                    query = value.toLowerCase();
                    offset = 0;
                  }),
                ),
                CheckboxListTile(
                  value:
                      candidates.isNotEmpty &&
                      selected.length == candidates.length,
                  onChanged: candidates.isEmpty
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            selected.addAll(
                              candidates.map((track) => track.id),
                            );
                          } else {
                            selected.clear();
                          }
                        }),
                  title: const Text("Select all tracks"),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                const Divider(height: 1),
                // Shrinks below its usual height when the keyboard or a
                // short landscape screen leaves less room, so the dialog
                // buttons stay on screen.
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: (MediaQuery.sizeOf(context).height * 0.35)
                          .clamp(96.0, 340.0),
                    ),
                    child: matching.isEmpty
                        ? Center(
                            child: Text(
                              candidates.isEmpty
                                  ? "Every library track is already in this playlist."
                                  : "No tracks match this search.",
                            ),
                          )
                        : ListView(
                            children: [
                              for (final track in visible)
                                CheckboxListTile(
                                  value: selected.contains(track.id),
                                  onChanged: (value) => setState(() {
                                    value == true
                                        ? selected.add(track.id)
                                        : selected.remove(track.id);
                                  }),
                                  title: Text(
                                    "${track.displayTitle} — ${details[track.id]!.credit}",
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  contentPadding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                  ),
                ),
                if (matching.length > 50)
                  PageNavigation(
                    total: matching.length,
                    start: start,
                    end: end,
                    onChange: (direction) =>
                        setState(() => offset += direction * 50),
                  ),
                Text(
                  selected.isEmpty
                      ? "No tracks selected"
                      : "${plural(selected.length, "track")} selected",
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final ids = [
                        for (final track in candidates)
                          if (selected.contains(track.id)) track.id,
                      ];
                      app.run(() {
                        final added = app.playlists.addTracks(playlist.id, ids);
                        app.showMessage(
                          "Added ${plural(added, "track")} to “${playlist.name}”.",
                        );
                      });
                      Navigator.of(context).pop();
                    },
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text("Add selected"),
            ),
          ],
        );
      },
    ),
  );
}

// -- search ------------------------------------------------------------------

Future<void> showBatchDownloadDialog(BuildContext context, MelodyApp app) {
  final controller = TextEditingController();
  String? error;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        insetPadding: _dialogInsets,
        title: const Text("Batch download"),
        content: SizedBox(
          width: _dialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Add multiple $youtubeMusicName URLs. Melody will queue them together "
                  "and show progress for each song.",
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 7,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: "$youtubeMusicName URLs",
                    hintText:
                        "Paste one $youtubeMusicName track or playlist URL per line",
                    errorText: error,
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Cancel"),
          ),
          FilledButton.icon(
            onPressed: () async {
              final urls = extractDownloadUrls(controller.text);
              if (urls.length < 2) {
                setState(
                  () => error =
                      "Paste at least two complete $youtubeMusicName URLs.",
                );
                return;
              }
              try {
                final batch = await app.services.downloads.startUrls(urls);
                if (context.mounted) Navigator.of(context).pop();
                app.showMessage(
                  MusicSearchController.batchDownloadMessage(batch),
                );
                app.openPanel(AppPanel.downloads);
              } catch (failure) {
                if (context.mounted) {
                  setState(() => error = failureMessage(failure));
                }
              }
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text("Start batch"),
          ),
        ],
      ),
    ),
  );
}

// -- files -------------------------------------------------------------------

Future<void> pickLocalFiles(MelodyApp app) async {
  final result = await FilePicker.pickFiles(
    dialogTitle: "Add music to Melody",
    type: FileType.custom,
    allowedExtensions: _audioExtensions,
    allowMultiple: true,
  );
  final paths = [
    for (final file in result?.files ?? const <PlatformFile>[])
      if (file.path != null) file.path!,
  ];
  if (paths.isEmpty) return;
  app.showMessage("Importing ${plural(paths.length, "local file")}…");
  await app.library.importLocalFiles(paths);
}

Future<void> _saveM3u8(
  MelodyApp app,
  String title,
  String name,
  List<int> contents,
  String done,
) async {
  final saved = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: name,
    type: FileType.custom,
    allowedExtensions: const ["m3u8"],
    bytes: Uint8List.fromList(contents),
  );
  if (saved != null) app.showMessage(done);
}

Future<void> exportLibrary(MelodyApp app) => app.run(
  () => _saveM3u8(
    app,
    "Export library playlist",
    "Melody Library.m3u8",
    app.services.library.exportLibraryM3u8(),
    "Library playlist exported.",
  ),
);

Future<void> exportPlaylist(MelodyApp app, Playlist playlist) => app.run(() {
  var safe = playlist.name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), "_");
  safe = safe.replaceAll(RegExp(r"^[ .]+|[ .]+$"), "");
  return _saveM3u8(
    app,
    "Export playlist",
    "${safe.isEmpty ? "Playlist" : safe}.m3u8",
    app.services.library.exportPlaylistM3u8(playlist.id),
    "Playlist exported.",
  );
});

Future<void> pickCookieFile(MelodyApp app) async {
  final FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      dialogTitle: "Upload $youtubeMusicName cookies",
      type: FileType.custom,
      allowedExtensions: const ["txt"],
      withData: true,
    );
  } catch (error) {
    app.showError("The cookie file picker could not be opened: $error");
    return;
  }
  final file = result?.files.firstOrNull;
  if (file == null) return;
  try {
    final bytes =
        file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) {
      app.showError("The selected cookie file could not be read.");
      return;
    }
    app.settingsDraft.stageCookie(file.name, bytes);
  } on FileSystemException catch (error) {
    app.showError(error.message);
  }
}

// -- settings ----------------------------------------------------------------

Future<void> showDataActionDialog(
  BuildContext context,
  MelodyApp app,
  String action,
) {
  final (tracks, playlists) = app.services.manager.counts();
  final trackWord = tracks == 1 ? "track" : "tracks";
  final playlistWord = playlists == 1 ? "playlist" : "playlists";
  final (title, message, label, prominent) = switch (action) {
    "library" => (
      "Clear library?",
      "Remove $tracks library $trackWord and $playlists $playlistWord. All playlists, the "
          "playback queue, favorites, and track-linked listening history will be cleared. "
          "Audio Melody downloaded is deleted; imported files stay on disk. Settings, "
          "download history, and search history are not changed.",
      "Clear library",
      false,
    ),
    "playlists" => (
      "Clear playlists?",
      "Delete $playlists user-created $playlistWord. Library tracks, audio files, settings, "
          "the playback queue, and histories are not changed.",
      "Clear playlists",
      false,
    ),
    "settings" => (
      "Reset settings?",
      "Restore appearance, volume, session, download, cookie, and notification settings to "
          "their defaults. Library tracks, playlists, audio files, download history, and "
          "search history are not changed. Your uploaded cookie file will be removed.",
      "Reset settings",
      false,
    ),
    "everything" => (
      "Reset everything?",
      "Remove $tracks library $trackWord and $playlists $playlistWord, clear the playback "
          "queue and track-linked history, delete every downloaded and imported audio file "
          "in the library, and restore every setting to its default. Download history and "
          "search history remain on this device. This cannot be undone.",
      "Reset everything",
      true,
    ),
    _ => throw ArgumentError("Unknown data-management action: $action"),
  };
  return showConfirmDialog(
    context,
    title: title,
    message: message,
    confirmLabel: label,
    icon: prominent
        ? Icons.delete_forever_rounded
        : Icons.delete_outline_rounded,
    prominent: prominent,
    warning: true,
    onConfirm: () async {
      try {
        app.showMessage(await app.settingsDraft.runDataAction(action));
      } catch (error) {
        app.showError("The reset could not be completed: $error");
      }
    },
  );
}

const _cleanupListed = 50;

/// Shows what library cleanup found, with actions that fix each finding:
/// missing audio can be restored or its tracks removed, and stray files can
/// be added to the library or deleted.
Future<void> showCleanupReport(
  BuildContext context,
  MelodyApp app,
  LibraryReconciliation report,
) {
  final removed = report.staleReferencesRemoved;
  final manager = app.services.manager;
  final missing = [
    for (final id in report.missingTrackIds)
      if (manager.hasTrack(id)) manager.getTrack(id),
  ];
  final stray = [...report.unregisteredFiles];
  if (removed == 0 && missing.isEmpty && stray.isEmpty) {
    app.showMessage(
      "Library cleanup found nothing to fix. No stale references or stray audio files.",
    );
    return Future.value();
  }
  final settings = app.settingsDraft;
  var busy = false;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final small = TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

        Future<void> run(Future<void> Function() action) async {
          setState(() => busy = true);
          try {
            await action();
          } finally {
            if (context.mounted) setState(() => busy = false);
          }
        }

        Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );

        Widget more(int count) => Text(
          "…and ${count - _cleanupListed} more.",
          style: const TextStyle(fontSize: 12),
        );

        Widget buttons(List<Widget> children) =>
            Wrap(spacing: 8, runSpacing: 8, children: children);

        final done = missing.isEmpty && stray.isEmpty;
        return AlertDialog(
          insetPadding: _dialogInsets,
          icon: const Icon(Icons.cleaning_services_rounded, size: 32),
          title: Text(done ? "Library cleanup complete" : "Library cleanup"),
          content: SizedBox(
            width: _dialogWidth(context),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    removed > 0
                        ? "Removed references to ${plural(removed, "deleted track")}."
                        : "No stale references were found.",
                  ),
                  if (missing.isNotEmpty) ...[
                    heading("Missing audio (${missing.length})"),
                    Text(
                      "${missing.length != 1 ? "These tracks have" : "This track has"} "
                      "no audio file on disk. Restore copies an imported file again "
                      "from its original, or downloads the song again.",
                    ),
                    for (final track in missing.take(_cleanupListed))
                      Text(track.displayTitle, style: small),
                    if (missing.length > _cleanupListed) more(missing.length),
                    buttons([
                      FilledButton.tonalIcon(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                final fixed = await settings
                                    .repairMissingTracks([
                                      for (final track in missing) track.id,
                                    ]);
                                missing.removeWhere(
                                  (track) => fixed.contains(track.id),
                                );
                              }),
                        icon: const Icon(Icons.restore_rounded),
                        label: const Text("Restore"),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => showConfirmDialog(
                                context,
                                title: "Remove missing tracks?",
                                message:
                                    "${plural(missing.length, "track")} will be removed "
                                    "from the library and every playlist.",
                                confirmLabel: "Remove",
                                onConfirm: () => run(() async {
                                  final gone = await settings.removeTracks([
                                    for (final track in missing) track.id,
                                  ]);
                                  missing.removeWhere(
                                    (track) => gone.contains(track.id),
                                  );
                                }),
                              ),
                        icon: const Icon(Icons.playlist_remove_rounded),
                        label: const Text("Remove from library"),
                      ),
                    ]),
                  ],
                  if (stray.isNotEmpty) ...[
                    heading("Not in your library (${stray.length})"),
                    Text(
                      "${stray.length != 1 ? "These audio files are" : "This audio file is"} "
                      "in the music folder but not in your library.",
                    ),
                    for (final path in stray.take(_cleanupListed))
                      SelectableText(path, style: small),
                    if (stray.length > _cleanupListed) more(stray.length),
                    buttons([
                      FilledButton.tonalIcon(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                final settled = await settings.addStrayFiles([
                                  ...stray,
                                ]);
                                stray.removeWhere(settled.contains);
                              }),
                        icon: const Icon(Icons.library_add_rounded),
                        label: const Text("Add to library"),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => showConfirmDialog(
                                context,
                                title: "Delete files?",
                                message:
                                    "${plural(stray.length, "audio file")} will be "
                                    "permanently deleted from the music folder. "
                                    "This cannot be undone.",
                                confirmLabel: "Delete files",
                                icon: Icons.delete_forever_rounded,
                                prominent: true,
                                warning: true,
                                onConfirm: () => run(() async {
                                  final settled = await settings
                                      .deleteStrayFiles([...stray]);
                                  stray.removeWhere(settled.contains);
                                }),
                              ),
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text("Delete files"),
                      ),
                    ]),
                  ],
                  if (busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              child: Text(done ? "Done" : "Close"),
            ),
          ],
        );
      },
    ),
  );
}
