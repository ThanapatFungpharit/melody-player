import "package:flutter/material.dart";

import "../../app/app_state.dart";
import "../../application/models.dart";
import "../../core/library/models.dart";
import "../../core/media.dart";
import "../controllers/home_controller.dart";
import "../shared/actions.dart";
import "../shared/dialogs.dart";
import "../shared/format.dart";
import "../shared/settings_sections.dart";
import "../shared/widgets.dart";
import "controls.dart";

ListView _scrollPage(List<Widget> children) => ListView.separated(
  itemCount: children.length,
  separatorBuilder: (_, _) => const SizedBox(height: 14),
  itemBuilder: (context, index) => children[index],
);

Widget libraryTrackRow(BuildContext context, MelodyApp app, Track track, List<Playlist> playlists, {TrackDetails? details}) {
  final info = details ?? app.services.library.details(track.id);
  return TrackRow(
    app: app,
    title: track.displayTitle,
    credit: info.credit,
    artwork: info.thumbnail,
    onTap: () => app.playback.playTrack(track.id),
    trailing: MoreButton(track.displayTitle, () => libraryTrackActions(context, app, track, info, playlists)),
  );
}

Widget searchResultRow(BuildContext context, MelodyApp app, SearchResult result, List<Playlist> playlists) {
  final detail = result.isPlaylist
      ? "${result.entryCount > 0 ? result.entryCount : "Multiple"} tracks"
      : formatDuration(result.duration);
  return TrackRow(
    app: app,
    title: result.title,
    credit: "${result.uploader} · $detail",
    artwork: result.thumbnail,
    onTap: () => app.search.playResult(result),
    trailing: MoreButton(
      result.title,
      () => searchResultActions(context, app, result, playlists, includePrimaryActions: true),
    ),
  );
}

// -- home --------------------------------------------------------------------

class MobileHome extends StatefulWidget {
  const MobileHome(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  @override
  void initState() {
    super.initState();
    widget.app.home.ensureRecommendations();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Watch([app.libraryRevision, app.home], builder: (context) {
      final (count, recent, favorites) = app.home.collections();
      final playlists = app.services.manager.listPlaylists();
      final home = app.home;
      return _scrollPage([
        MobileHeading(timeGreeting(), subtitle: "Your music, ready when you are."),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: count > 0 ? home.shuffleLibrary : null,
          icon: const Icon(Icons.shuffle_rounded),
          label: const Text("Shuffle your library"),
        ),
        const MobileHeading("Favorites"),
        for (final track in favorites) libraryTrackRow(context, app, track, playlists),
        if (favorites.isEmpty)
          const EmptyState(
            Icons.music_note_rounded,
            "Favorite tracks from their action menu to find them here.",
          ),
        MobileHeading(
          "Recommended for you",
          subtitle: "A mix based on your recent and favorite tracks",
          actions: [TouchIconButton(Icons.refresh_rounded, "Refresh recommendations", home.reload)],
        ),
        if (home.recommendationsLoading)
          const LoadingRow("Building your YouTube Music mix…")
        else if (home.recommendationsError.isNotEmpty)
          EmptyState(Icons.cloud_off_rounded, home.recommendationsError)
        else if (home.recommendations.isNotEmpty) ...[
          for (final result in home.visibleRecommendations())
            searchResultRow(context, app, result, playlists),
          if (home.recommendations.length > 8)
            PageNavigation(
              total: home.recommendations.length,
              start: home.recommendationPage * 8,
              end: (home.recommendationPage * 8 + 8).clamp(0, home.recommendations.length),
              onChange: home.changeRecommendationPage,
            ),
        ] else
          const EmptyState(
            Icons.auto_awesome_rounded,
            "Play a downloaded YouTube Music track to get recommendations.",
          ),
        const MobileHeading("Recently played"),
        for (final track in recent) libraryTrackRow(context, app, track, playlists),
        if (recent.isEmpty)
          const EmptyState(Icons.music_note_rounded, "Play a track to start your listening history."),
      ]);
    });
  }
}

// -- search ------------------------------------------------------------------

class MobileSearch extends StatefulWidget {
  const MobileSearch(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileSearch> createState() => _MobileSearchState();
}

class _MobileSearchState extends State<MobileSearch> {
  late final TextEditingController _query = TextEditingController(text: widget.app.search.draft);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final search = app.search;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Watch([search, app.libraryRevision], builder: (context) {
      final playlists = app.services.manager.listPlaylists();
      final Widget results;
      if (search.busy) {
        results = const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
      } else if (search.error != null) {
        results = EmptyState(Icons.cloud_off_rounded, search.error!);
      } else if (search.results.isEmpty) {
        results = EmptyState(
          Icons.search_rounded,
          search.queryText.isEmpty
              ? "Find a song, then tap it to listen. Use its actions to download or organize it."
              : "No matching music was found.",
        );
      } else {
        results = Column(
          spacing: 8,
          children: [for (final result in search.results) searchResultRow(context, app, result, playlists)],
        );
      }
      return _scrollPage([
        MobileHeading(
          "Search",
          actions: [
            MoreButton("Search actions", () => [
              MenuAction(
                "Download multiple links",
                Icons.download_rounded,
                () => showBatchDownloadDialog(context, app),
              ),
            ]),
          ],
        ),
        Row(
          spacing: 4,
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (value) => search.draft = value,
                onSubmitted: (_) => search.startSearch(),
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(hintText: "Song, artist or $youtubeMusicName link"),
              ),
            ),
            TouchIconButton(Icons.search_rounded, "Search $youtubeMusicName", search.busy ? null : search.startSearch),
          ],
        ),
        Text(
          search.status ?? "Search $youtubeMusicName or paste a playlist link.",
          style: TextStyle(fontSize: 12, color: muted),
        ),
        results,
        if (search.results.isNotEmpty || search.pageNumber > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: search.busy || search.pageNumber <= 1 ? null : () => search.loadPage(1),
                child: const Text("First page"),
              ),
              TouchIconButton(
                Icons.chevron_left_rounded,
                "Previous results",
                search.busy || search.pageNumber <= 1 ? null : () => search.loadPage(search.pageNumber - 1),
              ),
              Text("Page ${search.pageNumber}"),
              TouchIconButton(
                Icons.chevron_right_rounded,
                "Next results",
                search.busy || !search.hasNext ? null : () => search.loadPage(search.pageNumber + 1),
              ),
            ],
          ),
      ]);
    });
  }
}

// -- library -----------------------------------------------------------------

class MobileLibrary extends StatefulWidget {
  const MobileLibrary(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileLibrary> createState() => _MobileLibraryState();
}

class _MobileLibraryState extends State<MobileLibrary> {
  late final TextEditingController _query = TextEditingController(text: widget.app.library.queryText);

  @override
  void initState() {
    super.initState();
    widget.app.library.mode = "tracks";
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final library = app.library;
    return Watch([library, app.libraryRevision], builder: (context) {
      final (tracks, hasMore) = library.page();
      final playlists = app.services.manager.listPlaylists();
      final details = app.services.library.detailsMany(tracks.map((track) => track.id));
      final paged = library.pageOffset > 0 || hasMore;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 14,
        children: [
          MobileHeading(
            "Library",
            subtitle: "Music saved on this device",
            actions: [
              MoreButton("Library actions", () => [
                MenuAction("Add local audio files", Icons.library_add_rounded, () => pickLocalFiles(app)),
                MenuAction(
                  "Add these tracks to queue",
                  Icons.add_to_queue_rounded,
                  () => queueCollection(app, library.visibleTracks()),
                  enabled: tracks.isNotEmpty,
                ),
                MenuAction(
                  "Export library playlist",
                  Icons.ios_share_rounded,
                  () => exportLibrary(app),
                  enabled: app.services.manager.counts().$1 > 0,
                ),
              ]),
            ],
          ),
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: library.setQuery,
                  decoration: const InputDecoration(
                    hintText: "Find in your library",
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              MoreButton("Sort tracks", () => [
                for (final (key, label) in const [
                  ("recent", "Recently added"),
                  ("oldest", "Oldest first"),
                  ("title", "Title"),
                ])
                  MenuAction(label, key == library.sortKey ? Icons.check_rounded : Icons.sort_rounded, () => library.setSort(key)),
              ]),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: tracks.isEmpty ? null : library.playVisible,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text("Play all"),
                ),
              ),
              TouchIconButton(Icons.shuffle_rounded, "Shuffle visible tracks", tracks.isEmpty ? null : library.shuffleVisible),
            ],
          ),
          Expanded(
            child: tracks.isEmpty
                ? const EmptyState(
                    Icons.library_music_rounded,
                    "Nothing matches this view. Search for music or add local files.",
                  )
                : ListView.separated(
                    itemCount: tracks.length + (paged ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) => index == tracks.length
                        ? Row(
                            children: [
                              TextButton.icon(
                                onPressed: library.pageOffset == 0 ? null : () => library.changePage(-1),
                                icon: const Icon(Icons.chevron_left_rounded),
                                label: const Text("Previous"),
                              ),
                              Expanded(
                                child: Text(
                                  "${library.pageOffset + 1}–${library.pageOffset + tracks.length}",
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: hasMore ? () => library.changePage(1) : null,
                                icon: const Icon(Icons.chevron_right_rounded),
                                label: const Text("Next"),
                                iconAlignment: IconAlignment.end,
                              ),
                            ],
                          )
                        : libraryTrackRow(context, app, tracks[index], playlists, details: details[tracks[index].id]),
                  ),
          ),
        ],
      );
    });
  }
}

// -- playlists ---------------------------------------------------------------

class MobilePlaylists extends StatelessWidget {
  const MobilePlaylists(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => Watch([app.playlists, app.libraryRevision], builder: (context) {
    final selected = app.playlists.selectedPlaylistId;
    if (selected != null && app.services.manager.hasPlaylist(selected)) {
      return _PlaylistDetail(app, app.services.manager.getPlaylist(selected));
    }
    app.playlists.selectedPlaylistId = null;
    final playlists = app.services.manager.listPlaylists();
    return _scrollPage([
      MobileHeading(
        "Playlists",
        subtitle: "Collections made by you",
        actions: [
          MoreButton("Playlist actions", () => [
            MenuAction(
              "Import $youtubeMusicName playlist",
              Icons.playlist_add_rounded,
              () => showImportPlaylistDialog(context, app),
            ),
          ]),
        ],
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: () => showCreatePlaylistDialog(context, app),
        icon: const Icon(Icons.add_rounded),
        label: const Text("New playlist"),
      ),
      for (final playlist in playlists)
        TrackRow(
          app: app,
          title: playlist.name,
          credit: "${playlist.trackIds.length} tracks",
          artwork: playlist.trackIds.isEmpty ? "" : app.services.library.details(playlist.trackIds.first).thumbnail,
          onTap: () => app.playlists.openPlaylist(playlist.id),
          trailing: TouchIconButton(
            Icons.play_arrow_rounded,
            "Play ${playlist.name}",
            () => app.playlists.play(playlist),
          ),
        ),
      if (playlists.isEmpty)
        const EmptyState(Icons.album_rounded, "Create a playlist or import one from $youtubeMusicName."),
    ]);
  });
}

class _PlaylistDetail extends StatelessWidget {
  const _PlaylistDetail(this.app, this.playlist);

  final MelodyApp app;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final tracks = app.services.manager.playlistTracks(playlist.id);
    final (start, end) = app.playlists.visibleRange(tracks.length);
    final visible = tracks.sublist(start, end);
    final others = [
      for (final item in app.services.manager.listPlaylists())
        if (item.id != playlist.id) item,
    ];
    final details = app.services.library.detailsMany(visible.map((track) => track.id));
    final ids = [for (final track in tracks) track.id];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.playlists.closePlaylist();
      },
      child: _scrollPage([
        Row(
          spacing: 4,
          children: [
            TouchIconButton(Icons.arrow_back_rounded, "All playlists", app.playlists.closePlaylist),
            Expanded(
              child: Text(playlist.name, maxLines: 2, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            ),
            MoreButton(playlist.name, () => [
              if (tracks.isNotEmpty) ...[
                MenuAction(
                  "Add tracks",
                  Icons.playlist_add_rounded,
                  () => showBulkAddTracksDialog(context, app, playlist),
                ),
                MenuAction(
                  "Add playlist to queue",
                  Icons.add_to_queue_rounded,
                  () => queueCollection(app, tracks),
                ),
              ],
              ...playlistActions(context, app, playlist, tracks),
            ]),
          ],
        ),
        Text("${tracks.length} tracks · Reorder from a track’s actions", style: const TextStyle(fontSize: 12)),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: tracks.isEmpty ? null : () => app.playlists.play(playlist),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text("Play"),
              ),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: tracks.isEmpty ? null : () => app.playlists.shuffle(playlist),
              icon: const Icon(Icons.shuffle_rounded),
              label: const Text("Shuffle"),
            ),
          ],
        ),
        for (final (offset, track) in visible.indexed)
          TrackRow(
            app: app,
            title: track.displayTitle,
            credit: details[track.id]!.credit,
            artwork: details[track.id]!.thumbnail,
            onTap: () => app.playback.playTracks(ids, startIndex: start + offset),
            trailing: MoreButton(
              track.displayTitle,
              () => playlistTrackActions(context, app, playlist, track, start + offset, others, details[track.id]!),
            ),
          ),
        if (tracks.length > 50)
          PageNavigation(total: tracks.length, start: start, end: end, onChange: app.playlists.changePage),
        if (tracks.isEmpty)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => showBulkAddTracksDialog(context, app, playlist),
            icon: const Icon(Icons.add_rounded),
            label: const Text("Add tracks"),
          ),
      ]),
    );
  }
}

// -- queue -------------------------------------------------------------------

class MobileQueue extends StatefulWidget {
  const MobileQueue(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileQueue> createState() => _MobileQueueState();
}

class _MobileQueueState extends State<MobileQueue> {
  int? _offset;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = Theme.of(context).colorScheme;
    return Watch([app.playbackState, app.libraryRevision], builder: (context) {
      final queue = app.playback.queue;
      final mode = queueModeStatus(queue);
      _offset ??= (queue.currentIndex < 0 ? 0 : queue.currentIndex) ~/ 50 * 50;
      final (start, end) = pageBounds(queue.items.length, _offset!);
      _offset = start;
      final rows = <Widget>[];
      for (var index = start; index < end; index++) {
        final trackId = queue.items[index];
        if (!app.services.manager.hasTrack(trackId)) continue;
        final track = app.services.manager.getTrack(trackId);
        final details = app.services.library.details(trackId);
        final position = index;
        rows.add(
          TrackRow(
            app: app,
            title: track.displayTitle,
            credit: "${queueItemStatus(queue, index)} · ${details.uploader.isEmpty ? "Queued track" : details.uploader}",
            artwork: details.thumbnail,
            selected: index == queue.currentIndex,
            onTap: () => app.playback.playQueueIndex(position),
            trailing: MoreButton(track.displayTitle, () => queueRowActions(app, position)),
          ),
        );
      }
      return _scrollPage([
        MobileHeading(
          "Queue",
          subtitle: "${queue.items.length} tracks · ${mode.label}",
          actions: [TouchIconButton(Icons.arrow_back_rounded, "Back", () => Navigator.of(context).maybePop())],
        ),
        if (rows.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(14)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Icon(mode.icon, color: scheme.primary, size: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(mode.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(mode.description, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            children: [
              TextButton.icon(
                onPressed: queue.upcomingCount < 2 ? null : app.playback.shuffleUpcoming,
                icon: const Icon(Icons.shuffle_rounded),
                label: const Text("Shuffle upcoming"),
              ),
              TextButton.icon(onPressed: app.playback.cycleRepeat, icon: Icon(mode.icon), label: Text(mode.label)),
              TextButton.icon(
                onPressed: queue.items.length <= 1 ? null : app.playback.clearQueue,
                icon: const Icon(Icons.clear_all_rounded),
                label: const Text("Clear upcoming"),
              ),
            ],
          ),
        ],
        ...rows,
        if (queue.items.length > 50)
          PageNavigation(
            total: queue.items.length,
            start: start,
            end: end,
            onChange: (direction) => setState(() => _offset = start + direction * 50),
          ),
        if (rows.isEmpty) const EmptyState(Icons.queue_music_rounded, "Play music or add tracks to start your queue."),
      ]);
    });
  }
}

// -- downloads ---------------------------------------------------------------

class MobileDownloads extends StatelessWidget {
  const MobileDownloads(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.services.downloads,
    builder: (context, _) {
      final records = app.services.downloads.list();
      final active = [for (final r in records) if (const {"queued", "downloading", "processing"}.contains(r.status)) r];
      final issues = [for (final r in records) if (const {"failed", "cancelled"}.contains(r.status)) r];
      final completed = [for (final r in records) if (r.status == "completed") r];
      return _scrollPage([
        MobileHeading(
          "Downloads",
          subtitle: "${active.length} active · ${issues.length} need attention",
          actions: [TouchIconButton(Icons.arrow_back_rounded, "Back", () => Navigator.of(context).maybePop())],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: MoreButton("Download actions", () => [
            MenuAction(
              "Clear download history",
              Icons.cleaning_services_rounded,
              app.services.downloads.clearFinished,
              enabled: issues.isNotEmpty || completed.isNotEmpty,
            ),
          ]),
        ),
        for (final (label, items) in [("Needs attention", issues), ("In progress", active), ("Completed", completed)])
          if (items.isNotEmpty) ...[
            Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            for (final record in items) _DownloadCard(app, record),
          ],
        if (records.isEmpty)
          const EmptyState(Icons.download_done_rounded, "Download songs from Search to listen offline."),
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
    final active = const {"queued", "downloading", "processing"}.contains(record.status);
    final playable = record.trackIds.where(app.services.manager.hasTrack).toList();
    final Widget? action = active
        ? TextButton.icon(
            onPressed: () => app.services.downloads.cancel(record.id),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text("Cancel"),
          )
        : const {"failed", "cancelled"}.contains(record.status)
        ? FilledButton.icon(
            onPressed: () => app.run(() => app.services.downloads.retry(record.id)),
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
    final status = record.status.isEmpty
        ? ""
        : "${record.status[0].toUpperCase()}${record.status.substring(1)}";
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            record.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            record.batchSize > 1
                ? "Song ${record.batchPosition} of ${record.batchSize}"
                : (record.uploader.isNotEmpty ? record.uploader : record.source),
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            record.error.isNotEmpty ? record.error : downloadDetail(record),
            style: TextStyle(fontSize: 12, color: record.error.isNotEmpty ? scheme.error : scheme.onSurfaceVariant),
          ),
          LinearProgressIndicator(
            value: active || record.status == "completed" ? record.progress : 0,
            minHeight: 4,
          ),
          Row(children: [Expanded(child: Text(status, style: const TextStyle(fontSize: 12))), ?action]),
        ],
      ),
    );
  }
}

// -- settings ----------------------------------------------------------------

class MobileSettings extends StatefulWidget {
  const MobileSettings(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileSettings> createState() => _MobileSettingsState();
}

class _MobileSettingsState extends State<MobileSettings> {
  @override
  void initState() {
    super.initState();
    widget.app.settingsDraft.reset();
    widget.app.settingsDraft.refreshYtDlpStatus();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = Theme.of(context).colorScheme;
    Widget tile(SettingsSection section) {
      final color = section.destructive ? scheme.error : scheme.primary;
      final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
      return ExpansionTile(
        title: Text(section.mobileTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(section.mobileSubtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        leading: Icon(section.icon, color: color),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        backgroundColor: scheme.surfaceContainerLow,
        collapsedBackgroundColor: scheme.surfaceContainerLow,
        shape: shape,
        collapsedShape: shape,
        iconColor: color,
        collapsedIconColor: color,
        maintainState: true,
        children: [Material(type: MaterialType.transparency, child: section.body)],
      );
    }

    return ListenableBuilder(
      listenable: app.settingsDraft,
      builder: (context, _) => Column(
        spacing: 10,
        children: [
          Expanded(
            child: _scrollPage([
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
                child: MobileHeading(
                  "Settings",
                  subtitle: "Make Melody feel like yours.",
                  actions: [TouchIconButton(Icons.arrow_back_rounded, "Back", () => Navigator.of(context).maybePop())],
                ),
              ),
              tile(appearanceSettings(context, app)),
              tile(downloadSettings(context, app, mobile: true)),
              tile(youtubeSettings(context, app)),
              tile(maintenanceSettings(context, app)),
              tile(dataManagementSettings(context, app)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              spacing: 12,
              children: [
                TextButton(
                  onPressed: () {
                    app.settingsDraft.cancel();
                    Navigator.of(context).maybePop();
                  },
                  child: const Text("Cancel"),
                ),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => app.run(app.settingsDraft.save),
                    icon: const Icon(Icons.save_rounded),
                    label: const Text("Save settings"),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
