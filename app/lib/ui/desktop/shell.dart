import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../app_state.dart";
import "../shared/dialogs.dart";
import "../shared/format.dart";
import "../shared/navigation.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";
import "controls.dart";
import "pages/downloads_page.dart";
import "pages/home_page.dart";
import "pages/library_page.dart";
import "pages/lyrics_page.dart";
import "pages/playlists_page.dart";
import "pages/queue_page.dart";
import "pages/search_page.dart";
import "pages/settings_page.dart";
import "player_bar.dart";

class _Intent extends Intent {
  const _Intent(this.action);

  final void Function() action;
}

/// Sidebar, workspace, utility panel, and player bar for pointer-first
/// devices. Everything sits on the window canvas; the workspace and panels
/// are raised surfaces.
class DesktopShell extends StatelessWidget {
  const DesktopShell(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): _Intent(app.closePanel),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): _Intent(
        () {
          app.navigate(1);
          app.search.focusRequest.value++;
        },
      ),
      const SingleActivator(LogicalKeyboardKey.keyQ, control: true): _Intent(
        () => app.openPanel(AppPanel.queue),
      ),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): _Intent(
        () => app.openPanel(AppPanel.lyrics),
      ),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): _Intent(
        () => app.openPanel(AppPanel.downloads),
      ),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): _Intent(
        () => app.openPanel(AppPanel.settings),
      ),
      const SingleActivator(LogicalKeyboardKey.space, control: true): _Intent(
        app.playback.toggle,
      ),
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _Intent(
        app.playback.toggle,
      ),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): _Intent(
        app.playback.next,
      ),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): _Intent(
        app.playback.previous,
      ),
    };
    final extended = MediaQuery.sizeOf(context).width >= 1180;
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {
          _Intent: CallbackAction<_Intent>(
            onInvoke: (intent) => intent.action(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: context.palette.canvas,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Sidebar(app, extended: extended),
                    Expanded(child: _Workspace(app)),
                  ],
                ),
              ),
            ),
            // In the bottom slot, snackbars float above the player bar
            // instead of covering its controls.
            bottomNavigationBar: SafeArea(
              top: false,
              child: DesktopPlayerBar(app),
            ),
          ),
        ),
      ),
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace(this.app);

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final width = MediaQuery.sizeOf(context).width;
    return ValueListenableBuilder(
      valueListenable: app.activePanel,
      builder: (context, panel, _) {
        // Only the queue and lyrics dock beside the content, and only on
        // wide windows.
        final docked =
            (panel == AppPanel.queue || panel == AppPanel.lyrics) &&
            width >= 1400;
        final showContent = panel == null || docked;
        Widget surface(
          Widget child, {
          EdgeInsets padding = const EdgeInsets.fromLTRB(36, 32, 36, 24),
        }) => Container(
          padding: padding,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(Radii.panel),
          ),
          child: child,
        );
        // Content keeps its key while a docked panel comes and goes, so
        // the page is not rebuilt; a full-size panel fades over it.
        return PageSwitcher(
          child: showContent
              ? Row(
                  key: const ValueKey("content"),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: surface(_Content(app))),
                    _dock(
                      docked
                          ? SizedBox(
                              key: const ValueKey("dock"),
                              width: 428,
                              height: double.infinity,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: surface(
                                  PageSwitcher(
                                    child: KeyedSubtree(
                                      key: ValueKey(panel),
                                      child: _panel(panel!),
                                    ),
                                  ),
                                  padding: const EdgeInsets.fromLTRB(
                                    22,
                                    24,
                                    18,
                                    16,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(key: ValueKey("none")),
                    ),
                  ],
                )
              : KeyedSubtree(
                  key: ValueKey(panel),
                  child: surface(_panel(panel)),
                ),
        );
      },
    );
  }

  /// Slides the docked panel in from the edge, narrowing the content.
  Widget _dock(Widget child) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 280),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.centerLeft,
      children: [...previous, ?current],
    ),
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      axis: Axis.horizontal,
      alignment: Alignment.centerLeft,
      child: FadeTransition(opacity: animation, child: child),
    ),
    child: child,
  );

  Widget _panel(AppPanel panel) => switch (panel) {
    AppPanel.queue => QueuePanel(app),
    AppPanel.lyrics => LyricsPanel(app),
    AppPanel.downloads => DownloadsPanel(app),
    AppPanel.settings || AppPanel.player => SettingsPanel(app),
  };
}

class _Content extends StatelessWidget {
  const _Content(this.app);

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: app.selectedNavigation,
    builder: (context, index, _) => PageSwitcher(
      child: KeyedSubtree(
        key: ValueKey(index),
        child: switch (index) {
          0 => HomePage(app),
          1 => SearchPage(app),
          2 => LibraryPage(app),
          _ => PlaylistsPage(app),
        },
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.app, {required this.extended});

  final MelodyApp app;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return SizedBox(
      width: extended ? 248 : 76,
      child: Watch(
        [
          app.selectedNavigation,
          app.activePanel,
          app.services.downloads,
          app.playlists,
          app.libraryRevision,
        ],
        builder: (context) {
          final panel = app.activePanel.value;
          final utility =
              panel == AppPanel.downloads || panel == AppPanel.settings;
          final active = app.services.downloads.activeCount();
          final page = app.selectedNavigation.value;
          final openPlaylist = page == 3 && !utility
              ? app.playlists.selectedPlaylistId
              : null;
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: extended ? 14 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 2,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(extended ? 8 : 0, 14, 0, 26),
                  child: Row(
                    mainAxisAlignment: extended
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    spacing: 10,
                    children: [
                      const BrandMark(),
                      if (extended)
                        Text(
                          "Melody",
                          style: context.text.titleLarge!.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                    ],
                  ),
                ),
                for (final (index, destination)
                    in navigationDestinations.indexed)
                  _SidebarButton(
                    label: destination.label,
                    icon: destination.icon,
                    selectedIcon: destination.selectedIcon,
                    selected: index == page && !utility && openPlaylist == null,
                    extended: extended,
                    tooltip: index == 1 ? "Search (Ctrl+L)" : destination.label,
                    onPressed: () {
                      if (index == 3) app.playlists.closePlaylist();
                      app.navigate(index);
                    },
                  ),
                if (extended)
                  Expanded(child: _SidebarPlaylists(app, openPlaylist))
                else
                  const Spacer(),
                Divider(color: scheme.outlineVariant.withValues(alpha: 0.6)),
                const SizedBox(height: 6),
                _SidebarButton(
                  label: "Downloads",
                  icon: Icons.download_rounded,
                  selected: panel == AppPanel.downloads,
                  extended: extended,
                  badge: active > 0 ? "$active" : null,
                  tooltip: active > 0
                      ? "Downloads, $active active (Ctrl+D)"
                      : "Downloads (Ctrl+D)",
                  onPressed: () => app.openPanel(AppPanel.downloads),
                ),
                _SidebarButton(
                  label: "Settings",
                  icon: Icons.settings_outlined,
                  selectedIcon: Icons.settings_rounded,
                  selected: panel == AppPanel.settings,
                  extended: extended,
                  tooltip: "Settings (Ctrl+,)",
                  onPressed: () => app.openPanel(AppPanel.settings),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The user's playlists, one click away from anywhere.
class _SidebarPlaylists extends StatelessWidget {
  const _SidebarPlaylists(this.app, this.openPlaylist);

  final MelodyApp app;
  final String? openPlaylist;

  @override
  Widget build(BuildContext context) {
    final playlists = app.services.manager.listPlaylists();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 22, 0, 6),
          child: Row(
            children: [
              Expanded(
                child: Text("YOUR PLAYLISTS", style: context.text.labelSmall),
              ),
              IconButton(
                onPressed: () => showCreatePlaylistDialog(context, app),
                tooltip: "New playlist",
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: playlists.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    "Playlists you create or import appear here.",
                    style: context.text.bodySmall,
                  ),
                )
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final count = playlist.trackIds.length;
                    final selected = playlist.id == openPlaylist;
                    return _SidebarTile(
                      selected: selected,
                      onTap: () => app.playlists.openPlaylist(playlist.id),
                      child: Row(
                        spacing: 10,
                        children: [
                          Artwork(
                            app,
                            count > 0
                                ? app.services.library
                                      .details(playlist.trackIds.first)
                                      .thumbnail
                                : "",
                            size: 34,
                            playlist: true,
                            seed: playlist.name,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  playlist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.text.labelLarge!.copyWith(
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  plural(count, "track"),
                                  style: context.text.bodySmall!.copyWith(
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? scheme.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          hoverColor: context.palette.hover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.extended,
    required this.onPressed,
    this.selectedIcon,
    this.badge,
    this.tooltip,
  });

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final bool selected;
  final bool extended;
  final VoidCallback onPressed;
  final String? badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final color = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    Widget symbol = Icon(
      selected ? (selectedIcon ?? icon) : icon,
      size: 22,
      color: selected ? scheme.primary : color,
    );
    if (badge != null) symbol = Badge(label: Text(badge!), child: symbol);
    return Tooltip(
      message: tooltip ?? label,
      child: _SidebarTile(
        selected: selected,
        onTap: onPressed,
        child: SizedBox(
          height: 32,
          child: Row(
            mainAxisAlignment: extended
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(left: extended ? 4 : 0),
                child: symbol,
              ),
              if (extended) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: context.text.labelLarge!.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Title row for utility panels, with a close button.
class ContextHeader extends StatelessWidget {
  const ContextHeader(
    this.app,
    this.title,
    this.subtitle, {
    super.key,
    this.actions = const [],
    this.compact = false,
  });

  final MelodyApp app;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  /// Docked panels use a smaller title.
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      Expanded(
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(title, style: context.text.headlineSmall),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                ],
              )
            : Heading(title, subtitle),
      ),
      ...actions,
      IconButton(
        onPressed: app.closePanel,
        tooltip: "Close (Esc)",
        icon: const Icon(Icons.close_rounded),
      ),
    ],
  );
}
