import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../application/models.dart";
import "../../../core/library/models.dart";
import "../../../core/media.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class SearchPage extends StatefulWidget {
  const SearchPage(this.app, {super.key});

  final MelodyApp app;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.app.search.draft,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.app.search.focusRequest.addListener(_requestFocus);
  }

  void _requestFocus() => _focus.requestFocus();

  @override
  void dispose() {
    widget.app.search.focusRequest.removeListener(_requestFocus);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final search = app.search;
    final scheme = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([search, app.libraryRevision]),
      builder: (context, _) {
        final status =
            search.status ??
            "Songs, channels, and playlists. Find something you love.";
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Heading("Search", "Find songs on $youtubeMusicName."),
            const SizedBox(height: 22),
            Row(
              spacing: 10,
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    focusNode: _focus,
                    onChanged: (value) => search.draft = value,
                    onSubmitted: (_) => search.startSearch(),
                    textInputAction: TextInputAction.search,
                    style: context.text.bodyLarge,
                    decoration: InputDecoration(
                      hintText: "Search $youtubeMusicName or paste a link",
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.search_rounded),
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Center(widthFactor: 1, child: Pill("Ctrl L")),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide(
                          color: scheme.primary,
                          width: 1.6,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: search.busy ? null : search.startSearch,
                    child: const Text("Search"),
                  ),
                ),
                SizedBox(
                  height: 54,
                  child: OutlinedButton.icon(
                    onPressed: () => showBatchDownloadDialog(context, app),
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: const Text("Batch URLs"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Text(status, style: context.text.bodySmall)),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: "list",
                      icon: Icon(Icons.view_list_rounded, size: 18),
                      tooltip: "Track list",
                    ),
                    ButtonSegment(
                      value: "grid",
                      icon: Icon(Icons.grid_view_rounded, size: 18),
                      tooltip: "Grid",
                    ),
                  ],
                  selected: {search.viewMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) =>
                      search.setViewMode(value.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _results(context)),
            if (search.results.isNotEmpty || search.pageNumber > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 6,
                  children: [
                    TextButton(
                      onPressed: search.busy || search.pageNumber <= 1
                          ? null
                          : () => search.loadPage(1),
                      child: const Text("First"),
                    ),
                    IconButton(
                      onPressed: search.busy || search.pageNumber <= 1
                          ? null
                          : () => search.loadPage(search.pageNumber - 1),
                      tooltip: "Previous page",
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Text(
                      "Page ${search.pageNumber}",
                      style: context.text.labelLarge,
                    ),
                    IconButton(
                      onPressed: search.busy || !search.hasNext
                          ? null
                          : () => search.loadPage(search.pageNumber + 1),
                      tooltip: "Next page",
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _results(BuildContext context) {
    final app = widget.app;
    final search = app.search;
    if (search.busy) return const Center(child: CircularProgressIndicator());
    if (search.error != null) {
      return EmptyState(Icons.cloud_off_rounded, search.error!);
    }
    if (search.results.isEmpty) {
      return EmptyState(
        search.queryText.isEmpty
            ? Icons.travel_explore_rounded
            : Icons.search_off_rounded,
        search.queryText.isEmpty
            ? "Start with a song, artist, playlist, or $youtubeMusicName URL."
            : "No matching music was found.",
      );
    }
    final playlists = app.services.manager.listPlaylists();
    if (search.viewMode == "grid") {
      return SingleChildScrollView(
        child: CoverGrid(
          minWidth: 196,
          children: [
            for (final result in search.results)
              (width) => SearchResultCard(app, result, playlists, width: width),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: search.results.length,
      itemBuilder: (context, index) =>
          SearchResultRow(app, search.results[index], playlists),
    );
  }
}

String _resultDetail(SearchResult result, {String separator = " · "}) {
  if (result.isPlaylist) {
    return "$separator${result.entryCount > 0 ? result.entryCount : "Multiple"} tracks";
  }
  return result.duration > 0
      ? "$separator${formatDuration(result.duration)}"
      : "";
}

Widget _downloadAction(
  BuildContext context,
  MelodyApp app,
  SearchResult result,
  Track? local, {
  double size = 22,
}) => local != null
    ? Tooltip(
        message: "Already in library",
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.download_done_rounded,
            color: context.palette.success,
            size: size,
          ),
        ),
      )
    : IconButton(
        onPressed: () => app.search.downloadResult(result),
        tooltip: "Download",
        icon: Icon(Icons.download_rounded, size: size),
      );

class SearchResultRow extends StatelessWidget {
  const SearchResultRow(this.app, this.result, this.playlists, {super.key});

  final MelodyApp app;
  final SearchResult result;
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    final local = app.search.availableTrack(result);
    final uploader = result.uploader.isEmpty
        ? "Unknown uploader"
        : result.uploader;
    return TrackListRow(
      app: app,
      title: result.title,
      subtitle: "$uploader · ${result.source}",
      artwork: result.thumbnail,
      playlist: result.isPlaylist,
      duration: result.isPlaylist
          ? "${result.entryCount > 0 ? result.entryCount : "Many"} tracks"
          : result.duration > 0
          ? formatDuration(result.duration)
          : "",
      onPlay: () => app.search.playResult(result),
      playTooltip: result.isPlaylist ? "Preview playlist" : "Play",
      trailing: [
        _downloadAction(context, app, result, local),
        ActionMenu(() => searchResultActions(context, app, result, playlists)),
      ],
    );
  }
}

class SearchResultCard extends StatelessWidget {
  const SearchResultCard(
    this.app,
    this.result,
    this.playlists, {
    super.key,
    this.width = 196,
  });

  final MelodyApp app;
  final SearchResult result;
  final List<Playlist> playlists;
  final double width;

  @override
  Widget build(BuildContext context) {
    final local = app.search.availableTrack(result);
    final uploader = result.uploader.isEmpty
        ? "Unknown uploader"
        : result.uploader;
    return CoverCard(
      app: app,
      width: width,
      title: result.title,
      titleLines: 2,
      subtitle: "$uploader${_resultDetail(result)}",
      artwork: result.thumbnail,
      playlist: result.isPlaylist,
      onPlay: () => app.search.playResult(result),
      playTooltip: result.isPlaylist ? "Preview playlist" : "Play",
      footer: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Transform.translate(
              offset: const Offset(-8, 0),
              child: _downloadAction(context, app, result, local, size: 20),
            ),
            const Spacer(),
            Transform.translate(
              offset: const Offset(8, 0),
              child: ActionMenu(
                () => searchResultActions(context, app, result, playlists),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
