import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../core/library/models.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";
import "search_page.dart";

class HomePage extends StatefulWidget {
  const HomePage(this.app, {super.key});

  final MelodyApp app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    widget.app.home.attach();
  }

  @override
  void dispose() {
    widget.app.home.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Watch(
      [app.libraryRevision, app.playbackState],
      builder: (context) {
        final (count, recent, favorites) = app.home.collections();
        final playlists = app.services.manager.listPlaylists();
        final summary = count == 0
            ? "Your library is empty. Find something to play."
            : "${plural(count, "track")} · ${plural(playlists.length, "playlist")}";
        return ListView(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: 8,
              children: [
                Expanded(child: Heading(timeGreeting(), summary)),
                FilledButton.icon(
                  onPressed: count > 0
                      ? app.home.shuffleLibrary
                      : () => app.navigate(1),
                  icon: Icon(
                    count > 0 ? Icons.shuffle_rounded : Icons.search_rounded,
                    size: 20,
                  ),
                  label: Text(
                    count > 0 ? "Shuffle your library" : "Find your music",
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: count > 0 ? app.home.playLibrary : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text("Play all"),
                ),
                IconButton(
                  onPressed: count > 0 ? app.home.queueLibrary : null,
                  tooltip: "Add library to queue",
                  icon: const Icon(Icons.add_to_queue_rounded),
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (recent.isNotEmpty) ...[
              _QuickGrid(app, recent),
              const SizedBox(height: 36),
            ],
            const SectionTitle(
              "Favorites",
              caption: "The tracks you keep coming back to",
            ),
            const SizedBox(height: 10),
            if (favorites.isEmpty)
              const EmptyState(
                Icons.favorite_border_rounded,
                "Favorite a track to keep it close.",
              )
            else
              _Shelf([for (final track in favorites) _trackCard(track)]),
            if (playlists.isNotEmpty) ...[
              const SizedBox(height: 28),
              SectionTitle(
                "Your playlists",
                trailing: [
                  TextButton(
                    onPressed: () {
                      app.playlists.closePlaylist();
                      app.navigate(3);
                    },
                    child: const Text("Show all"),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _Shelf([
                for (final playlist in playlists.take(12))
                  CoverCard(
                    app: app,
                    title: playlist.name,
                    subtitle: plural(playlist.trackIds.length, "track"),
                    artwork: playlist.trackIds.isEmpty
                        ? ""
                        : app.services.library
                              .details(playlist.trackIds.first)
                              .thumbnail,
                    playlist: true,
                    onTap: () => app.playlists.openPlaylist(playlist.id),
                    onPlay: playlist.trackIds.isEmpty
                        ? null
                        : () => app.playlists.play(playlist),
                    playTooltip: "Play ${playlist.name}",
                  ),
              ]),
            ],
            const SizedBox(height: 28),
            ListenableBuilder(
              listenable: app.home,
              builder: (context, _) => _Recommendations(app),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  Widget _trackCard(Track track) {
    final app = widget.app;
    final details = app.services.library.details(track.id);
    return CoverCard(
      app: app,
      title: track.displayTitle,
      subtitle: details.credit,
      artwork: details.thumbnail,
      onPlay: () => app.playback.playTrack(track.id),
      playTooltip: "Play ${track.displayTitle}",
    );
  }
}

/// A horizontally scrolling row of cards.
class _Shelf extends StatelessWidget {
  const _Shelf(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    // Cards carry their own padding; pull the row flush with the headings.
    child: Transform.translate(
      offset: const Offset(-10, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
}

/// Recently played tracks as compact tiles to jump straight back in.
class _QuickGrid extends StatelessWidget {
  const _QuickGrid(this.app, this.tracks);

  final MelodyApp app;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionTitle("Recently played"),
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, constraints) {
          const gap = 10.0;
          final columns = constraints.maxWidth >= 900 ? 3 : 2;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final track in tracks)
                SizedBox(width: width, child: _QuickTile(app, track)),
            ],
          );
        },
      ),
    ],
  );
}

class _QuickTile extends StatelessWidget {
  const _QuickTile(this.app, this.track);

  final MelodyApp app;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final details = app.services.library.details(track.id);
    final current = app.playback.currentTrackId == track.id;
    return Hoverable(
      builder: (context, hovered) => Material(
        color: hovered
            ? Color.alphaBlend(
                context.palette.hover,
                scheme.surfaceContainerLow,
              )
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.medium),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => app.playback.playTrack(track.id),
          child: Row(
            children: [
              Artwork(
                app,
                details.thumbnail,
                size: 60,
                seed: track.displayTitle,
                radius: 0,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      track.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleSmall!.copyWith(
                        color: current ? scheme.primary : null,
                      ),
                    ),
                    Text(
                      details.credit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall,
                    ),
                  ],
                ),
              ),
              Opacity(
                opacity: hovered ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: PlayCircle(
                    onPressed: () => app.playback.playTrack(track.id),
                    tooltip: "Play ${track.displayTitle}",
                    size: 36,
                  ),
                ),
              ),
              if (current && !hovered)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: NowPlayingMark(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Recommendations extends StatelessWidget {
  const _Recommendations(this.app);

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final home = app.home;
    final Widget body;
    if (home.recommendationsLoading) {
      body = const LoadingRow("Building your YouTube Music mix…");
    } else if (home.recommendationsError.isNotEmpty) {
      body = EmptyState(Icons.cloud_off_rounded, home.recommendationsError);
    } else if (home.recommendations.isNotEmpty) {
      final playlists = app.services.manager.listPlaylists();
      body = _Shelf([
        for (final result in home.visibleRecommendations())
          SearchResultCard(app, result, playlists),
      ]);
    } else {
      body = const EmptyState(
        Icons.auto_awesome_rounded,
        "Play a downloaded YouTube Music track to get recommendations.",
      );
    }
    final total = home.recommendations.length;
    final start = home.recommendationPage * 8;
    final end = (start + 8).clamp(0, total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        SectionTitle(
          "Recommended for you",
          caption: "A mix based on your recent and favorite tracks",
          trailing: [
            IconButton(
              onPressed: home.recommendationsLoading ? null : home.reload,
              tooltip: "Refresh recommendations",
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body,
        if (total > 8)
          PageNavigation(
            total: total,
            start: start,
            end: end,
            onChange: home.changeRecommendationPage,
          ),
      ],
    );
  }
}
