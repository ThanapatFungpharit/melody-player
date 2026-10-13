import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../core/media.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class MobileSearch extends StatefulWidget {
  const MobileSearch(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileSearch> createState() => _MobileSearchState();
}

class _MobileSearchState extends State<MobileSearch> {
  late final TextEditingController _query = TextEditingController(
    text: widget.app.search.draft,
  );

  void _searchAgain(String query) {
    FocusScope.of(context).unfocus();
    _query.text = query;
    widget.app.search.searchAgain(query);
  }

  void _clear() {
    _query.clear();
    widget.app.search.clear();
  }

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
    return Watch(
      [search, app.libraryRevision],
      builder: (context) {
        final playlists = app.services.manager.listPlaylists();
        final recent = search.queryText.isEmpty
            ? search.recentSearches
            : const <String>[];
        final Widget results;
        if (search.busy) {
          results = const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (search.error != null) {
          results = EmptyState(Icons.cloud_off_rounded, search.error!);
        } else if (recent.isNotEmpty) {
          results = RecentSearches(
            recent,
            onSelect: _searchAgain,
            onRemove: search.forgetSearch,
            onClear: search.clearSearchHistory,
          );
        } else if (search.results.isEmpty) {
          results = EmptyState(
            Icons.search_rounded,
            search.queryText.isEmpty
                ? "Find a song to listen to."
                : "No matching music was found.",
          );
        } else {
          results = Column(
            spacing: 8,
            children: [
              for (final result in search.results)
                searchResultRow(context, app, result, playlists),
            ],
          );
        }
        return scrollPage([
          MobileHeading(
            "Search",
            large: true,
            actions: [
              MoreButton(
                "Search actions",
                () => [
                  MenuAction(
                    "Download multiple links",
                    Icons.download_rounded,
                    () => showBatchDownloadDialog(context, app),
                  ),
                ],
              ),
            ],
          ),
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: _query,
                  builder: (context, value, _) => TextField(
                    controller: _query,
                    onChanged: (value) => search.draft = value,
                    onSubmitted: (_) => search.startSearch(),
                    style: const TextStyle(fontSize: 14),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: "Song, artist or $youtubeMusicName link",
                      prefixIcon: const Icon(Icons.search_rounded),
                      // Only while there is text, so the hint keeps its room.
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: _clear,
                              tooltip: "Clear search",
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
              ),
              IconButton.filled(
                onPressed: search.busy ? null : search.startSearch,
                tooltip: "Search $youtubeMusicName",
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ],
          ),
          Text(
            search.status ??
                "Search $youtubeMusicName or paste a playlist link.",
            style: TextStyle(fontSize: 12, color: muted),
          ),
          results,
          if (search.results.isNotEmpty || search.pageNumber > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: search.busy || search.pageNumber <= 1
                      ? null
                      : () => search.loadPage(1),
                  child: const Text("First page"),
                ),
                TouchIconButton(
                  Icons.chevron_left_rounded,
                  "Previous results",
                  search.busy || search.pageNumber <= 1
                      ? null
                      : () => search.loadPage(search.pageNumber - 1),
                ),
                Text("Page ${search.pageNumber}"),
                TouchIconButton(
                  Icons.chevron_right_rounded,
                  "Next results",
                  search.busy || !search.hasNext
                      ? null
                      : () => search.loadPage(search.pageNumber + 1),
                ),
              ],
            ),
        ]);
      },
    );
  }
}
