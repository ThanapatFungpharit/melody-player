import "dart:async";

import "package:flutter/material.dart";

import "../../application/models.dart";
import "../../core/library/models.dart";
import "../app_state.dart";
import "../shared/actions.dart";
import "../shared/format.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";

/// A page title ([large]) or section title with optional trailing actions.
class MobileHeading extends StatelessWidget {
  const MobileHeading(
    this.title, {
    super.key,
    this.subtitle = "",
    this.actions = const [],
    this.large = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;
  final bool large;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: large ? 4 : 10),
    child: Row(
      spacing: 4,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: large
                    ? context.text.headlineMedium!.copyWith(fontSize: 28)
                    : context.text.titleLarge,
              ),
              if (subtitle.isNotEmpty)
                Text(subtitle, style: context.text.bodySmall),
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );
}

class TouchIconButton extends StatelessWidget {
  const TouchIconButton(
    this.icon,
    this.tooltip,
    this.onPressed, {
    super.key,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    constraints: const BoxConstraints.tightFor(
      width: touchTarget,
      height: touchTarget,
    ),
    icon: Icon(icon, color: color),
  );
}

/// Shows [actions] in a scrollable bottom sheet that respects system insets.
Future<void> showActionSheet(
  BuildContext context,
  String title,
  List<MenuAction> actions,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  isScrollControlled: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.85,
  ),
  // useSafeArea guards only the top and sides of a sheet, and an explicit
  // padding turns off the list's own inset, so clear the navigation bar here.
  builder: (sheetContext) => ListView(
    shrinkWrap: true,
    padding: EdgeInsets.fromLTRB(
      12,
      0,
      12,
      16 + MediaQuery.paddingOf(sheetContext).bottom,
    ),
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.titleMedium,
              ),
            ),
            TouchIconButton(
              Icons.close_rounded,
              "Close actions",
              () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
      for (final action in actions)
        ListTile(
          enabled: action.enabled,
          minTileHeight: 52,
          leading: Icon(action.icon),
          title: Text(action.label, maxLines: 2),
          onTap: () {
            Navigator.of(sheetContext).pop();
            unawaited(Future.sync(action.onSelected));
          },
        ),
    ],
  ),
);

class MoreButton extends StatelessWidget {
  const MoreButton(
    this.title,
    this.actions, {
    super.key,
    this.icon = Icons.more_vert_rounded,
  });

  final String title;
  final List<MenuAction> Function() actions;
  final IconData icon;

  @override
  Widget build(BuildContext context) => TouchIconButton(
    icon,
    "Actions for $title",
    () => showActionSheet(context, title, actions()),
    color: context.colors.onSurfaceVariant,
  );
}

/// A tappable row: artwork, title, credit, and a trailing control.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.app,
    required this.title,
    required this.credit,
    required this.artwork,
    required this.onTap,
    required this.trailing,
    this.selected = false,
    this.playlist = false,
  });

  final MelodyApp app;
  final String title;
  final String credit;
  final String artwork;
  final VoidCallback onTap;
  final Widget trailing;
  final bool selected;
  final bool playlist;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.medium),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: "Play $title",
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.medium),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                  child: Row(
                    spacing: 14,
                    children: [
                      Artwork(
                        app,
                        artwork,
                        size: 52,
                        seed: title,
                        playlist: playlist,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 3,
                          children: [
                            Row(
                              spacing: 6,
                              children: [
                                if (selected) const NowPlayingMark(size: 16),
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.text.titleMedium!.copyWith(
                                      color: selected ? scheme.primary : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              credit,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

/// A full-screen panel pushed over the shell. An [immersive] panel draws
/// edge to edge and handles the system insets itself.
Future<void> pushPanel(
  BuildContext context,
  MelodyApp app,
  AppPanel panel,
  Widget child, {
  bool immersive = false,
}) {
  app.openPanel(panel);
  return Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          fullscreenDialog: immersive,
          builder: (context) => Scaffold(
            body: immersive
                ? child
                : SafeArea(
                    maintainBottomViewPadding: true,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: child,
                    ),
                  ),
          ),
        ),
      )
      .whenComplete(() {
        if (app.activePanel.value == panel) app.closePanel();
      });
}

/// A vertically scrolling page of evenly spaced sections.
ListView scrollPage(List<Widget> children) => ListView.separated(
  padding: const EdgeInsets.only(bottom: 16),
  itemCount: children.length,
  separatorBuilder: (_, _) => const SizedBox(height: 10),
  itemBuilder: (context, index) => children[index],
);

Widget libraryTrackRow(
  BuildContext context,
  MelodyApp app,
  Track track,
  List<Playlist> playlists, {
  TrackDetails? details,
}) {
  final info = details ?? app.services.library.details(track.id);
  return TrackRow(
    app: app,
    title: track.displayTitle,
    credit: info.credit,
    artwork: info.thumbnail,
    selected: app.playback.currentTrackId == track.id,
    onTap: () => app.playback.playTrack(track.id),
    trailing: MoreButton(
      track.displayTitle,
      () => libraryTrackActions(context, app, track, info, playlists),
    ),
  );
}

Widget searchResultRow(
  BuildContext context,
  MelodyApp app,
  SearchResult result,
  List<Playlist> playlists,
) {
  final detail = result.isPlaylist
      ? "${result.entryCount > 0 ? result.entryCount : "Multiple"} tracks"
      : formatDuration(result.duration);
  return TrackRow(
    app: app,
    title: result.title,
    credit: "${result.uploader} · $detail",
    artwork: result.thumbnail,
    playlist: result.isPlaylist,
    onTap: () => app.search.playResult(result),
    trailing: MoreButton(
      result.title,
      () => searchResultActions(
        context,
        app,
        result,
        playlists,
        includePrimaryActions: true,
      ),
    ),
  );
}

/// A cover-first card for horizontal shelves.
class MobileCoverCard extends StatelessWidget {
  const MobileCoverCard({
    super.key,
    required this.app,
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.onTap,
    this.playlist = false,
    this.size = 148,
  });

  final MelodyApp app;
  final String title;
  final String subtitle;
  final String artwork;
  final VoidCallback onTap;
  final bool playlist;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: playlist ? "Open $title" : "Play $title",
    child: InkWell(
      borderRadius: BorderRadius.circular(Radii.medium),
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 3,
          children: [
            Artwork(app, artwork, size: size, seed: title, playlist: playlist),
            const SizedBox(height: 5),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.titleSmall,
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

/// A horizontally scrolling row that bleeds to the screen edges.
class MobileShelf extends StatelessWidget {
  const MobileShelf({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: children,
    ),
  );
}
