import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../controllers/library_controller.dart";
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
        final ids = library.visibleIds();
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
                    "Select tracks",
                    Icons.checklist_rounded,
                    library.startSelecting,
                    enabled: ids.isNotEmpty,
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
                  for (final MapEntry(:key, :value) in librarySorts.entries)
                    MenuAction(
                      value,
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
          if (library.selecting)
            Row(
              children: [
                TouchIconButton(
                  Icons.close_rounded,
                  "Stop selecting",
                  library.stopSelecting,
                ),
                Expanded(child: Text("${library.selectedIds.length} selected")),
                TouchIconButton(
                  Icons.select_all_rounded,
                  "Select all",
                  library.toggleSelectAll,
                ),
                for (final action in selectedTracksActions(context, app))
                  TouchIconButton(
                    action.icon,
                    action.label,
                    action.enabled ? action.onSelected : null,
                  ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: ids.isEmpty ? null : library.playVisible,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text("Play all"),
                  ),
                ),
                TouchIconButton(
                  Icons.shuffle_rounded,
                  "Shuffle these tracks",
                  ids.isEmpty ? null : library.shuffleVisible,
                ),
              ],
            ),
        ];
        const empty = EmptyState(
          Icons.library_music_rounded,
          "Nothing matches this view. Search for music or add local files.",
        );
        Widget row(BuildContext context, int index) =>
            libraryTrackRow(context, app, ids[index], index);
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
              if (ids.isEmpty)
                const SliverToBoxAdapter(child: empty)
              else
                SliverList.builder(itemCount: ids.length, itemBuilder: row),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            ...header,
            Expanded(
              child: ids.isEmpty
                  ? empty
                  : ListView.builder(itemCount: ids.length, itemBuilder: row),
            ),
          ],
        );
      },
    );
  }
}
