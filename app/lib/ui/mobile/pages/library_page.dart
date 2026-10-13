import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../controllers/home_controller.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobileLibrary extends StatefulWidget {
  const MobileLibrary(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileLibrary> createState() => _MobileLibraryState();
}

class _MobileLibraryState extends State<MobileLibrary> {
  late final TextEditingController _query = TextEditingController(
    text: widget.app.library.queryText,
  );

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
    return Watch(
      [library, app.libraryRevision, app.playbackState],
      builder: (context) {
        final (tracks, hasMore) = library.page();
        final playlists = app.services.manager.listPlaylists();
        final details = app.services.library.detailsMany(
          tracks.map((track) => track.id),
        );
        final paged = library.pageOffset > 0 || hasMore;
        final header = [
          MobileHeading(
            "Library",
            subtitle: "Music saved on this device",
            large: true,
            actions: [
              MoreButton(
                "Library actions",
                () => [
                  MenuAction(
                    "Add local audio files",
                    Icons.library_add_rounded,
                    () => pickLocalFiles(app),
                  ),
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
                ],
              ),
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
              MoreButton(
                "Sort tracks",
                () => [
                  for (final (key, label) in const [
                    ("recent", "Recently added"),
                    ("oldest", "Oldest first"),
                    ("title", "Title"),
                  ])
                    MenuAction(
                      label,
                      key == library.sortKey
                          ? Icons.check_rounded
                          : Icons.sort_rounded,
                      () => library.setSort(key),
                    ),
                ],
                icon: Icons.sort_rounded,
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: tracks.isEmpty ? null : library.playVisible,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text("Play all"),
                ),
              ),
              TouchIconButton(
                Icons.shuffle_rounded,
                "Shuffle visible tracks",
                tracks.isEmpty ? null : library.shuffleVisible,
              ),
            ],
          ),
        ];
        const empty = EmptyState(
          Icons.library_music_rounded,
          "Nothing matches this view. Search for music or add local files.",
        );
        final count = tracks.length + (paged ? 1 : 0);
        Widget separator(BuildContext context, int index) =>
            const SizedBox(height: 6);
        Widget row(BuildContext context, int index) => index == tracks.length
            ? Row(
                children: [
                  TextButton.icon(
                    onPressed: library.pageOffset == 0
                        ? null
                        : () => library.changePage(-1),
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
            : libraryTrackRow(
                context,
                app,
                tracks[index],
                playlists,
                details: details[tracks[index].id],
              );
        // A short screen, such as a landscape phone, has no room for a fixed
        // header above the tracks, so there it scrolls away with them. The
        // screen size ignores the keyboard, so typing never swaps layouts.
        if (MediaQuery.sizeOf(context).height < 500) {
          return CustomScrollView(
            slivers: [
              SliverList.list(
                children: [
                  for (final widget in header)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: widget,
                    ),
                ],
              ),
              if (tracks.isEmpty)
                const SliverToBoxAdapter(child: empty)
              else
                SliverList.separated(
                  itemCount: count,
                  separatorBuilder: separator,
                  itemBuilder: row,
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            ...header,
            Expanded(
              child: tracks.isEmpty
                  ? empty
                  : ListView.separated(
                      itemCount: count,
                      separatorBuilder: separator,
                      itemBuilder: row,
                    ),
            ),
          ],
        );
      },
    );
  }
}
