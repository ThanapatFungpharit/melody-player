import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../../application/models.dart";
import "../../../core/library/models.dart";
import "../../../core/media.dart";
import "../../shared/actions.dart";
import "../../shared/dialogs.dart";
import "../../shared/format.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

class SearchPage extends StatefulWidget {
  const SearchPage(this.app, {super.key});

  final MelodyApp app;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _query = TextEditingController(text: widget.app.search.draft);
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
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([search, app.libraryRevision]),
      builder: (context, _) {
        final status = search.status ?? "Songs, channels, and playlists. Find something you love.";
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            const Heading("Search", "Find songs on $youtubeMusicName."),
            ResponsiveGrid(
              spacing: 12,
              children: [
                GridCell(
                  TextField(
                    controller: _query,
                    focusNode: _focus,
                    onChanged: (value) => search.draft = value,
                    onSubmitted: (_) => search.startSearch(),
                    decoration: InputDecoration(
                      hintText: "Search $youtubeMusicName or paste a link",
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: scheme.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  md: 8,
                ),
                GridCell(
                  PrimaryButton("Search", Icons.search_rounded, search.busy ? null : search.startSearch),
                  md: 2,
                ),
                GridCell(
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                    onPressed: () => showBatchDownloadDialog(context, app),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text("Batch URLs"),
                  ),
                  md: 2,
                ),
              ],
            ),
            ResponsiveGrid(
              spacing: 10,
              center: true,
              children: [
                GridCell(
                  Text(status, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  md: 7,
                ),
                GridCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: "list", icon: Icon(Icons.view_list_rounded), label: Text("Track list")),
                        ButtonSegment(value: "grid", icon: Icon(Icons.grid_view_rounded), label: Text("Grid")),
                      ],
                      selected: {search.viewMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) => search.setViewMode(value.first),
                    ),
                  ),
                  md: 5,
                ),
              ],
            ),
            Expanded(child: _results(context)),
            if (search.results.isNotEmpty || search.pageNumber > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: search.busy || search.pageNumber <= 1 ? null : () => search.loadPage(1),
                    child: const Text("First"),
                  ),
                  IconButton(
                    onPressed: search.busy || search.pageNumber <= 1
                        ? null
                        : () => search.loadPage(search.pageNumber - 1),
                    tooltip: "Previous page",
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Text("Page ${search.pageNumber}", style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    onPressed: search.busy || !search.hasNext
                        ? null
                        : () => search.loadPage(search.pageNumber + 1),
                    tooltip: "Next page",
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
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
    if (search.error != null) return EmptyState(Icons.cloud_off_rounded, search.error!);
    if (search.results.isEmpty) {
      return EmptyState(
        search.queryText.isEmpty ? Icons.travel_explore_rounded : Icons.search_off_rounded,
        search.queryText.isEmpty
            ? "Start with a song, artist, playlist, or $youtubeMusicName URL."
            : "No matching music was found.",
      );
    }
    final playlists = app.services.manager.listPlaylists();
    if (search.viewMode == "grid") {
      return SingleChildScrollView(
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [for (final result in search.results) SearchResultCard(app, result, playlists)],
        ),
      );
    }
    return ListView.separated(
      itemCount: search.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => SearchResultRow(app, search.results[index], playlists),
    );
  }
}

String _resultDetail(SearchResult result, {String separator = "  •  "}) {
  if (result.isPlaylist) {
    return "$separator${result.entryCount > 0 ? result.entryCount : "Multiple"} tracks";
  }
  return result.duration > 0 ? "$separator${formatDuration(result.duration)}" : "";
}

Widget _downloadAction(MelodyApp app, SearchResult result, Track? local, {double size = 24}) => local != null
    ? Tooltip(
        message: "Already in library",
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.download_done_rounded, color: Colors.green.shade400, size: size),
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
    final scheme = Theme.of(context).colorScheme;
    final local = app.search.availableTrack(result);
    return Surface(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Artwork(app, result.thumbnail, size: 52, playlist: result.isPlaylist),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 5,
              children: [
                Text(
                  result.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                Text(
                  "${result.uploader}  •  ${result.source}${_resultDetail(result)}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => app.search.playResult(result),
            tooltip: result.isPlaylist ? "Preview playlist" : "Play",
            icon: const Icon(Icons.play_arrow_rounded),
          ),
          _downloadAction(app, result, local),
          ActionMenu(() => searchResultActions(context, app, result, playlists)),
        ],
      ),
    );
  }
}

class SearchResultCard extends StatelessWidget {
  const SearchResultCard(this.app, this.result, this.playlists, {super.key});

  final MelodyApp app;
  final SearchResult result;
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = app.search.availableTrack(result);
    final uploader = result.uploader.isEmpty ? "Unknown uploader" : result.uploader;
    return Surface(
      width: 204,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Artwork(app, result.thumbnail, size: 180, playlist: result.isPlaylist),
          SizedBox(
            height: 44,
            child: Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
          Text(
            "$uploader${_resultDetail(result, separator: " • ")}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () => app.search.playResult(result),
                tooltip: result.isPlaylist ? "Preview playlist" : "Play",
                icon: const Icon(Icons.play_arrow_rounded, size: 24),
              ),
              _downloadAction(app, result, local),
              const Spacer(),
              ActionMenu(() => searchResultActions(context, app, result, playlists)),
            ],
          ),
        ],
      ),
    );
  }
}
