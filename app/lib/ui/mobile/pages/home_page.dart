import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../../core/library/models.dart";
import "../../shared/format.dart";
import "../../shared/theme.dart";
import "../../shared/widgets.dart";
import "../controls.dart";

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
      [app.libraryRevision, app.home, app.playbackState],
      builder: (context) {
        final (count, recent, favorites) = app.home.collections();
        final playlists = app.services.manager.listPlaylists();
        final home = app.home;
        return scrollPage([
          MobileHeading(
            timeGreeting(),
            subtitle: count == 0
                ? "Your music, ready when you are."
                : "${plural(count, "track")} · ${plural(playlists.length, "playlist")}",
            large: true,
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: count > 0 ? home.shuffleLibrary : null,
            icon: const Icon(Icons.shuffle_rounded),
            label: const Text("Shuffle your library"),
          ),
          if (recent.isNotEmpty) ...[
            const MobileHeading("Recently played"),
            _QuickGrid(app, recent),
          ],
          const MobileHeading("Favorites"),
          if (favorites.isEmpty)
            const EmptyState(
              Icons.favorite_border_rounded,
              "Favorite tracks from their action menu to find them here.",
            )
          else
            MobileShelf(
              app,
              itemCount: favorites.length,
              itemBuilder: (context, index) {
                final track = favorites[index];
                final details = app.services.library.details(track.id);
                return MobileCoverCard(
                  app: app,
                  title: track.displayTitle,
                  subtitle: details.credit,
                  artwork: details.thumbnail,
                  onTap: () => app.playback.playTrack(track.id),
                );
              },
            ),
          if (playlists.isNotEmpty) ...[
            const MobileHeading("Your playlists"),
            MobileShelf(
              app,
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return MobileCoverCard(
                  app: app,
                  title: playlist.name,
                  subtitle: plural(playlist.trackIds.length, "track"),
                  artwork: playlistArtwork(app, playlist),
                  playlist: true,
                  onTap: () => app.playlists.openPlaylist(playlist.id),
                );
              },
            ),
          ],
          MobileHeading(
            "Recommended for you",
            subtitle: "A mix based on your recent and favorite tracks",
            actions: [
              TouchIconButton(
                Icons.refresh_rounded,
                "Refresh recommendations",
                home.reload,
              ),
            ],
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
                end: (home.recommendationPage * 8 + 8).clamp(
                  0,
                  home.recommendations.length,
                ),
                onChange: home.changeRecommendationPage,
              ),
          ] else
            const EmptyState(
              Icons.auto_awesome_rounded,
              "Play a downloaded YouTube Music track to get recommendations.",
            ),
        ]);
      },
    );
  }
}

/// Recently played tracks as two columns of compact tiles.
class _QuickGrid extends StatelessWidget {
  const _QuickGrid(this.app, this.tracks);

  final MelodyApp app;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final width = (constraints.maxWidth - gap) / 2;
      final scheme = context.colors;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final track in tracks)
            SizedBox(
              width: width,
              child: Tooltip(
                message: "Play ${track.displayTitle}",
                child: Material(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(Radii.small),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => app.playback.playTrack(track.id),
                    child: Row(
                      children: [
                        Artwork(
                          app,
                          app.services.library.details(track.id).thumbnail,
                          size: 52,
                          seed: track.displayTitle,
                          radius: 0,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            track.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelLarge!.copyWith(
                              color: app.playback.currentTrackId == track.id
                                  ? scheme.primary
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
