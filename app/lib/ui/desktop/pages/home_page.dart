import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../../core/library/models.dart";
import "../../shared/format.dart";
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
    widget.app.home.ensureRecommendations();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Watch([app.libraryRevision], builder: (context) {
      final (count, recent, favorites) = app.home.collections();
      return ListView(
        children: [
          ResponsiveGrid(
            center: true,
            children: [
              GridCell(Heading(timeGreeting(), "Your music, ready when you are."), md: 9),
              GridCell(
                Align(
                  alignment: Alignment.centerRight,
                  child: Pill("$count tracks", icon: Icons.library_music_rounded),
                ),
                md: 3,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _Hero(app, count),
          const SizedBox(height: 24),
          ..._shelf(context, "Favorites", favorites, "Favorite a track to keep it close."),
          const SizedBox(height: 24),
          ListenableBuilder(
            listenable: app.home,
            builder: (context, _) => _Recommendations(app),
          ),
          const SizedBox(height: 24),
          ..._shelf(context, "Recently played", recent, "Play a track to start your listening history."),
        ],
      );
    });
  }

  List<Widget> _shelf(BuildContext context, String title, List<Track> tracks, String empty) => [
    Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        TextButton.icon(
          onPressed: () => widget.app.navigate(2),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text("Open library"),
          iconAlignment: IconAlignment.end,
        ),
      ],
    ),
    const SizedBox(height: 12),
    if (tracks.isEmpty)
      EmptyState(Icons.music_note_rounded, empty)
    else
      SizedBox(
        height: 236,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: tracks.length,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (context, index) => _TrackCard(widget.app, tracks[index]),
        ),
      ),
  ];
}

class _Hero extends StatelessWidget {
  const _Hero(this.app, this.count);

  final MelodyApp app;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onContainer = scheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerLow],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(
                  "YOUR COLLECTION",
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: onContainer),
                ),
                Text(
                  "Good music. All yours.",
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: onContainer),
                ),
                Text(
                  count > 0
                      ? "An old favorite or something new. Just press play."
                      : "Make room for your favorites. Add music to get started.",
                  style: TextStyle(fontSize: 13, color: onContainer),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PrimaryButton(
                        count > 0 ? "Shuffle your library" : "Find your music",
                        count > 0 ? Icons.shuffle_rounded : Icons.search_rounded,
                        () => count > 0 ? app.home.shuffleLibrary() : app.navigate(1),
                      ),
                      TextButton.icon(
                        onPressed: count > 0 ? app.home.playLibrary : null,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text("Play all"),
                      ),
                      IconButton(
                        onPressed: count > 0 ? app.home.queueLibrary : null,
                        tooltip: "Add library to queue",
                        icon: const Icon(Icons.add_to_queue_rounded),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Container(
            width: 126,
            height: 126,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(32),
            ),
            child: Icon(Icons.graphic_eq_rounded, size: 86, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard(this.app, this.track);

  final MelodyApp app;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = app.services.library.details(track.id);
    return Surface(
      width: 180,
      padding: const EdgeInsets.all(12),
      radius: 20,
      hover: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Stack(
            children: [
              Artwork(app, details.thumbnail, size: 156),
              Positioned(
                right: 8,
                bottom: 8,
                child: IconButton.filled(
                  onPressed: () => app.playback.playTrack(track.id),
                  tooltip: "Play ${track.displayTitle}",
                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
                ),
              ),
            ],
          ),
          Text(
            track.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Text(
            details.credit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    final Widget body;
    if (home.recommendationsLoading) {
      body = const LoadingRow("Building your YouTube Music mix…");
    } else if (home.recommendationsError.isNotEmpty) {
      body = EmptyState(Icons.cloud_off_rounded, home.recommendationsError);
    } else if (home.recommendations.isNotEmpty) {
      final playlists = app.services.manager.listPlaylists();
      final visible = home.visibleRecommendations();
      body = SizedBox(
        height: 330,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (context, index) => SearchResultCard(app, visible[index], playlists),
        ),
      );
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
      spacing: 12,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Recommended for you", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text(
                    "A mix based on your recent and favorite tracks",
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: home.recommendationsLoading ? null : home.reload,
              tooltip: "Refresh recommendations",
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body,
        if (total > 8)
          PageNavigation(total: total, start: start, end: end, onChange: home.changeRecommendationPage),
      ],
    );
  }
}
