import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart"
    show Clipboard, ClipboardData, PlatformException;
import "package:melody_audio/melody_audio.dart" show AndroidPlatform;
import "package:path/path.dart" as p;

import "../app_state.dart";
import "../../application/downloads.dart";
import "../../application/library_service.dart";
import "../../application/models.dart";
import "../../core/errors.dart" show failureMessage;
import "../../core/library/models.dart";
import "../../core/media.dart";
import "../../platform/folders.dart";
import "../controllers/playlists_controller.dart" show MissingPlaylistTracks;
import "../controllers/search_controller.dart";
import "format.dart";

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

/// Saves the settings, first asking to move the library when the music
/// folder changes while it has tracks.
Future<void> applyMusicFolder(BuildContext context, MelodyApp app) {
  final settings = app.settingsControls;
  final tracks = settings.tracksToMove;
  if (tracks == 0) return app.run(settings.applyMusicFolder);
  return showConfirmDialog(
    context,
    title: "Move your library?",
    message:
        "Melody will move the audio of ${plural(tracks, "library track")} "
        "from ${app.settings.downloadDirectory} to "
        "${settings.requestedMusicFolder}, and save new downloads there. "
        "Playback stops while the files move. Other files in the old folder "
        "stay where they are.",
    confirmLabel: "Move library",
    icon: Icons.drive_file_move_rounded,
    onConfirm: () =>
        app.run(() => settings.applyMusicFolder(moveLibrary: true)),
  );
}

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

/// Edits what a track is called in the library; its file stays as it is.
Future<void> showEditTrackDialog(
  BuildContext context,
  MelodyApp app,
  Track track,
) {
  final title = TextEditingController(text: track.displayTitle);
  final artist = TextEditingController(
    text: app.services.library.details(track.id).uploader,
  );
  String? error;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          try {
            app.library.editTrack(
              track.id,
              title: title.text,
              artist: artist.text,
            );
            Navigator.of(context).pop();
          } on FormatException catch (failure) {
            setState(() => error = failure.message);
          } on ArgumentError catch (failure) {
            setState(() => error = "${failure.message}");
          }
        }

        return AlertDialog(
          insetPadding: _dialogInsets,
          title: const Text("Edit track details"),
          content: SizedBox(
            width: _dialogWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: "Title",
                    errorText: error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
                TextField(
                  controller: artist,
                  decoration: const InputDecoration(labelText: "Artist"),
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
            FilledButton(onPressed: submit, child: const Text("Save")),
          ],
        );
      },
    ),
  );
}

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
    ("Artist", details.uploader.isEmpty ? "—" : details.uploader),
    ("Duration", formatDuration(details.duration)),
    (
      "Source",
      details.sourceName.isNotEmpty
          ? details.sourceName
          : (track.source.isNotEmpty ? track.source : "Local"),
    ),
    for (final link in LibraryService.linksOf([track])) ("Link", link),
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
      "“${track.displayTitle}” will be removed from the library and every playlist, "
      "and Melody's file for it deleted. An original you imported it from is not "
      "touched, and a file added from the music folder stays on disk.",
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

Future<void> showDeleteSelectedTracksDialog(
  BuildContext context,
  MelodyApp app,
) {
  final count = app.library.selectedIds.length;
  return showConfirmDialog(
    context,
    title: "Delete ${plural(count, "track")}?",
    message:
        "${count == 1 ? "This track" : "These tracks"} will be removed from the "
        "library and every playlist, and Melody's files for them deleted. "
        "Originals you imported from are not touched, and files added from the "
        "music folder stay on disk.",
    confirmLabel: "Delete",
    icon: Icons.delete_forever_rounded,
    onConfirm: () => app.run(app.library.deleteSelected),
  );
}

Future<void> showSearchResultDetails(
  BuildContext context,
  SearchResult result,
) => showDetailsDialog(context, result.title, [
  ("Artist", result.uploader.isEmpty ? "Unknown artist" : result.uploader),
  ("Source", result.source),
  if (result.duration > 0) ("Duration", formatDuration(result.duration)),
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

/// Lets the user pick one of their playlists, or name a new one, and hands
/// over its ID. [except] is left out of the list.
Future<void> showPlaylistPicker(
  BuildContext context,
  MelodyApp app, {
  required String title,
  String? except,
  required void Function(String playlistId) onChosen,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    void choose(String playlistId) {
      Navigator.of(dialogContext).pop();
      onChosen(playlistId);
    }

    final playlists = [
      for (final playlist in app.services.manager.listPlaylists())
        if (playlist.id != except) playlist,
    ];
    return AlertDialog(
      insetPadding: _dialogInsets,
      title: Text(title),
      content: SizedBox(
        width: _dialogWidth(dialogContext),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text("New playlist…"),
              contentPadding: EdgeInsets.zero,
              onTap: () {
                Navigator.of(dialogContext).pop();
                showTextPrompt(
                  context,
                  title: "New playlist",
                  label: "Playlist name",
                  confirmLabel: "Create",
                  onConfirm: (name) async =>
                      onChosen(app.playlists.create(name, open: false)),
                );
              },
            ),
            for (final playlist in playlists)
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: Text(playlist.name),
                subtitle: Text(plural(playlist.trackIds.length, "track")),
                contentPadding: EdgeInsets.zero,
                onTap: () => choose(playlist.id),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text("Cancel"),
        ),
      ],
    );
  },
);

Future<void> showImportPlaylistDialog(BuildContext context, MelodyApp app) {
  if (app.playlists.importing) {
    app.showError("A playlist import is already in progress.");
    return Future.value();
  }
  final source = app.settings.musicSource;
  return showTextPrompt(
    context,
    title: "Import playlist",
    label: "${source.label} playlist URL",
    hint: "https://${source.host}/playlist?list=…",
    description:
        "Paste a ${source.label} playlist link. Melody will reuse tracks already in "
        "your library and download only the missing ones.",
    confirmLabel: "Import playlist",
    confirmIcon: Icons.download_rounded,
    onConfirm: (value) async {
      final url = value.trim();
      if (!isYoutubePlaylistUrl(url)) {
        throw FormatException("Paste a complete ${source.label} playlist URL.");
      }
      app.showMessage("Loading the ${source.label} playlist…");
      app.playlists.importFromUrl(url);
    },
  );
}

/// Asks for a name and links to songs, and makes a playlist of them.
Future<void> showPlaylistFromLinksDialog(BuildContext context, MelodyApp app) {
  final name = TextEditingController();
  final links = TextEditingController();
  String? error;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        insetPadding: _dialogInsets,
        title: const Text("New playlist from links"),
        content: SizedBox(
          width: _dialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: "Playlist name"),
                ),
                TextField(
                  controller: links,
                  minLines: 5,
                  maxLines: 10,
                  decoration: InputDecoration(
                    labelText: "${app.settings.musicSource.label} song links",
                    hintText: "Paste the links someone shared with you",
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
          FilledButton(
            onPressed: () {
              try {
                app.playlists.importFromLinks(name.text, links.text);
                Navigator.of(context).pop();
              } on FormatException catch (failure) {
                setState(() => error = failure.message);
              }
            },
            child: const Text("Create playlist"),
          ),
        ],
      ),
    ),
  );
}

/// Picks several library tracks to add to [playlist] at once.
Future<void> showBulkAddTracksDialog(
  BuildContext context,
  MelodyApp app,
  Playlist playlist,
) {
  final members = playlist.trackIds.toSet();
  final hasCandidates = app.services.manager.trackIds.any(
    (id) => !members.contains(id),
  );
  final selected = <String>{};
  var query = "";
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final matching = [
          for (final id in app.services.library.trackIds(query: query))
            if (!members.contains(id)) id,
        ];
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
                  onChanged: (value) => setState(() => query = value),
                ),
                CheckboxListTile(
                  value: matching.isNotEmpty && selected.containsAll(matching),
                  onChanged: matching.isEmpty
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            selected.addAll(matching);
                          } else {
                            selected.removeAll(matching);
                          }
                        }),
                  title: Text(
                    query.trim().isEmpty
                        ? "Select all tracks"
                        : "Select all ${matching.length} shown",
                  ),
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
                              !hasCandidates
                                  ? "Every library track is already in this playlist."
                                  : "No tracks match this search.",
                            ),
                          )
                        : ListView.builder(
                            itemCount: matching.length,
                            itemBuilder: (context, index) {
                              final id = matching[index];
                              final track = app.services.manager.getTrack(id);
                              final credit = app.services.library
                                  .details(id)
                                  .credit;
                              return CheckboxListTile(
                                value: selected.contains(id),
                                onChanged: (value) => setState(() {
                                  value == true
                                      ? selected.add(id)
                                      : selected.remove(id);
                                }),
                                title: Text("${track.displayTitle} — $credit"),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                contentPadding: EdgeInsets.zero,
                              );
                            },
                          ),
                  ),
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
                      app.run(() {
                        final added = app.playlists.addTracks(
                          playlist.id,
                          selected.toList(),
                        );
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
                  "Add links to one or more songs on ${app.settings.musicSource.label}. Melody will "
                  "queue them together and show progress for each song. To save a "
                  "playlist, use Import playlist on the Playlists page.",
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
                    labelText: "${app.settings.musicSource.label} URLs",
                    hintText:
                        "Paste one ${app.settings.musicSource.label} song link per line",
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
              if (urls.isEmpty) {
                setState(
                  () => error =
                      "Paste at least one complete ${app.settings.musicSource.label} URL.",
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

/// Adds every audio file under a chosen folder to the library.
Future<void> pickLocalFolder(MelodyApp app) => app.run(() async {
  final folder = await FilePicker.getDirectoryPath(
    dialogTitle: "Add a folder of music to Melody",
  );
  if (folder == null || folder.isEmpty) return;
  final paths = await LibraryService.audioFilesIn(folder);
  if (paths.isEmpty) {
    app.showMessage("That folder has no audio files Melody can play.");
    return;
  }
  app.showMessage("Importing ${plural(paths.length, "local file")}…");
  await app.library.importLocalFiles(paths);
});

/// Copies links to the clipboard, one per line.
Future<void> copyLinks(MelodyApp app, List<String> links) async {
  await Clipboard.setData(ClipboardData(text: links.join("\n")));
  app.showMessage(
    links.length == 1 ? "Link copied." : "Copied ${links.length} links.",
  );
}

/// Copies the links of a playlist's tracks, saying which have none to share.
Future<void> copyPlaylistLinks(MelodyApp app, Playlist playlist) async {
  final tracks = app.playlists.tracks(playlist.id);
  final links = LibraryService.linksOf(tracks);
  if (links.isEmpty) {
    app.showMessage(
      "These tracks came from files, so they have no links to share.",
    );
    return;
  }
  await Clipboard.setData(ClipboardData(text: links.join("\n")));
  final local = tracks.length - links.length;
  app.showMessage(
    "Copied ${plural(links.length, "link")}."
    "${local > 0 ? " ${plural(local, "track")} from files could not be included." : ""}",
  );
}

/// What to say about a file listing [tracks], whose local ones need their files
/// wherever it is opened.
String _exportedMessage(String what, List<Track> tracks) {
  final local = tracks.length - LibraryService.linksOf(tracks).length;
  return "$what exported."
      "${local > 0 ? " ${plural(local, "track")} from files will need those files wherever it's opened." : ""}";
}

/// Saves a playlist file made by [contents] for the folder it is saved in,
/// so its relative paths start there. Mobile pickers write the file
/// themselves and do not say where, so there they start at the music
/// folder.
Future<void> _saveM3u8(
  MelodyApp app,
  String title,
  String name,
  List<int> Function(String? directory) contents,
  String done,
) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final saved = await FilePicker.saveFile(
      dialogTitle: title,
      fileName: name,
      type: FileType.custom,
      allowedExtensions: const ["m3u8"],
      bytes: Uint8List.fromList(contents(null)),
    );
    if (saved != null) app.showMessage(done);
    return;
  }
  final chosen = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: name,
    type: FileType.custom,
    allowedExtensions: const ["m3u8"],
  );
  if (chosen == null) return;
  final path = p.extension(chosen).isEmpty ? "$chosen.m3u8" : chosen;
  await File(path).writeAsBytes(contents(p.dirname(path)), flush: true);
  app.showMessage(done);
}

Future<void> exportLibrary(MelodyApp app) => app.run(
  () => _saveM3u8(
    app,
    "Export library playlist",
    "Melody Library.m3u8",
    (directory) => app.services.library.exportLibraryM3u8(directory: directory),
    _exportedMessage("Library playlist", app.services.manager.listTracks()),
  ),
);

Future<void> exportPlaylist(MelodyApp app, Playlist playlist) => app.run(() {
  var safe = playlist.name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), "_");
  safe = safe.replaceAll(RegExp(r"^[ .]+|[ .]+$"), "");
  return _saveM3u8(
    app,
    "Export playlist",
    "${safe.isEmpty ? "Playlist" : safe}.m3u8",
    (directory) => app.services.library.exportPlaylistM3u8(
      playlist.id,
      directory: directory,
    ),
    _exportedMessage("Playlist", app.playlists.tracks(playlist.id)),
  );
});

/// Picks an M3U or M3U8 file and makes a playlist of what it lists.
/// Tracks that are not found can then be located one by one.
Future<void> importPlaylistFile(BuildContext context, MelodyApp app) =>
    app.run(() async {
      final result = await FilePicker.pickFiles(
        dialogTitle: "Import playlist file",
        type: FileType.custom,
        allowedExtensions: const ["m3u8", "m3u"],
        withData: true,
      );
      final file = result?.files.firstOrNull;
      if (file == null) return;
      final bytes =
          file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const FormatException(
          "The selected playlist file could not be read",
        );
      }
      await app.playlists.importFromFile(
        bytes,
        file.name,
        // Relative entries are relative to the file; a picker's cached copy
        // (Android) has no such folder, so those match another way.
        directory: file.path != null && !Platform.isAndroid
            ? p.dirname(file.path!)
            : null,
        onLocate: (missing) {
          if (context.mounted) showMissingTracksDialog(context, app, missing);
        },
      );
    });

/// Lists the tracks of an imported playlist file that were not found, each
/// with a button to pick its audio file.
Future<void> showMissingTracksDialog(
  BuildContext context,
  MelodyApp app,
  MissingPlaylistTracks missing,
) {
  var busy = false;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final small = TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        final pending = missing.pending;

        Future<void> locate(int index) async {
          final picked = await FilePicker.pickFiles(
            dialogTitle: "Locate “${missing.entries[index].title}”",
            type: FileType.custom,
            allowedExtensions: _audioExtensions,
          );
          final path = picked?.files.firstOrNull?.path;
          if (path == null) return;
          setState(() => busy = true);
          try {
            await app.playlists.locateMissing(missing, index, path);
          } catch (error) {
            app.reportFailure(error);
          } finally {
            if (context.mounted) setState(() => busy = false);
          }
        }

        return AlertDialog(
          insetPadding: _dialogInsets,
          icon: const Icon(Icons.search_off_rounded, size: 32),
          title: Text(
            pending.isEmpty ? "All tracks found" : "Tracks not found",
          ),
          content: SizedBox(
            width: _dialogWidth(context),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  Text(
                    pending.isEmpty
                        ? "Every track is now in the playlist."
                        : "Melody could not find ${pending.length != 1 ? "these tracks" : "this track"} "
                              "in your library. Locate the audio file to add it to the "
                              "playlist in its place.",
                  ),
                  for (final index in pending)
                    Row(
                      spacing: 8,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                missing.entries[index].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                missing.entries[index].location,
                                style: small,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => locate(index),
                          child: const Text("Locate…"),
                        ),
                      ],
                    ),
                  if (busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              child: Text(pending.isEmpty ? "Done" : "Close"),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> pickCookieFile(MelodyApp app) async {
  final FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      dialogTitle: "Upload $youtubeName cookies",
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
    await app.settingsControls.uploadCookie(file.name, bytes);
  } on FileSystemException catch (error) {
    app.showError(error.message);
  }
}

/// Chooses a new music folder for the settings draft; it applies on save.
///
/// Android lets Melody write audio only inside the shared Music folder, so a
/// folder elsewhere is refused there.
Future<void> pickMusicFolder(MelodyApp app) async {
  final current = app.settings.downloadDirectory;
  final String? folder;
  try {
    folder = await FilePicker.getDirectoryPath(
      dialogTitle: "Choose the music & download folder",
      initialDirectory: Directory(current).existsSync() ? current : null,
    );
  } catch (error) {
    app.showError("The folder picker could not be opened: $error");
    return;
  }
  if (folder == null || folder.isEmpty) return;
  final publicRoot = app.services.paths.publicMusicRoot;
  if (publicRoot != null && !p.isWithin(publicRoot, folder)) {
    app.showError(
      "Choose or create a folder inside Music. Android lets Melody save "
      "music only there.",
    );
    return;
  }
  app.settingsControls.chooseMusicFolder(p.normalize(folder));
}

/// Opens [folder] in the system file manager, or on Android in the Files
/// app.
Future<void> openFolder(MelodyApp app, String folder) async {
  final publicRoot = app.services.paths.publicMusicRoot;
  if (Platform.isAndroid && publicRoot != null) {
    await _openAndroidMusicFolder(app, publicRoot, folder);
    return;
  }
  try {
    await revealFolder(folder);
  } on Exception catch (error) {
    app.showError("$folder could not be opened: $error");
  }
}

Future<void> _openAndroidMusicFolder(
  MelodyApp app,
  String publicRoot,
  String folder,
) async {
  final relative = p.isWithin(publicRoot, folder)
      ? p.relative(folder, from: publicRoot).replaceAll(r"\", "/")
      : "";
  final shown = relative.isEmpty ? "Music" : "Music/$relative";
  // Files cannot open a folder that does not exist yet.
  try {
    await Directory(folder).create(recursive: true);
  } on FileSystemException catch (error) {
    debugPrint("Could not create $folder: $error");
  }
  try {
    if (await AndroidPlatform.openMusicFolder(relative)) return;
  } on PlatformException catch (error) {
    debugPrint("Could not open $shown: $error");
  }
  app.showMessage("Open the Files app and go to $shown.");
}

/// Copies [folder] to the clipboard.
Future<void> copyFolderPath(MelodyApp app, String folder) async {
  await Clipboard.setData(ClipboardData(text: folder));
  app.showMessage("Folder path copied.");
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
        app.showMessage(await app.settingsControls.runDataAction(action));
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
  final settings = app.settingsControls;
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
                      "from its original, or downloads the song again. If the file "
                      "was moved, locate it instead.",
                    ),
                    for (final track in missing.take(_cleanupListed))
                      Row(
                        spacing: 8,
                        children: [
                          Expanded(
                            child: Text(
                              track.displayTitle,
                              style: small,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    final picked = await FilePicker.pickFiles(
                                      dialogTitle:
                                          "Locate “${track.displayTitle}”",
                                      type: FileType.custom,
                                      allowedExtensions: _audioExtensions,
                                    );
                                    final path =
                                        picked?.files.firstOrNull?.path;
                                    if (path != null &&
                                        await settings.relinkTrack(
                                          track.id,
                                          path,
                                        )) {
                                      missing.remove(track);
                                    }
                                  }),
                            child: const Text("Locate…"),
                          ),
                        ],
                      ),
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
