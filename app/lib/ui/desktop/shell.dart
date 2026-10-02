import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../app/app_state.dart";
import "../shared/navigation.dart";
import "../shared/widgets.dart";
import "controls.dart";
import "pages/downloads_page.dart";
import "pages/home_page.dart";
import "pages/library_page.dart";
import "pages/playlists_page.dart";
import "pages/queue_page.dart";
import "pages/search_page.dart";
import "pages/settings_page.dart";
import "player_bar.dart";

class _Intent extends Intent {
  const _Intent(this.action);

  final void Function() action;
}

/// Rail, workspace, utility panel, and player bar for pointer-first devices.
class DesktopShell extends StatelessWidget {
  const DesktopShell(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): _Intent(app.closePanel),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): _Intent(() {
        app.navigate(1);
        app.search.focusRequest.value++;
      }),
      const SingleActivator(LogicalKeyboardKey.keyQ, control: true): _Intent(
        () => app.openPanel(AppPanel.queue),
      ),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): _Intent(
        () => app.openPanel(AppPanel.downloads),
      ),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): _Intent(
        () => app.openPanel(AppPanel.settings),
      ),
      const SingleActivator(LogicalKeyboardKey.space, control: true): _Intent(app.playback.toggle),
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _Intent(app.playback.toggle),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): _Intent(app.playback.next),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): _Intent(app.playback.previous),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {_Intent: CallbackAction<_Intent>(onInvoke: (intent) => intent.action())},
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: scheme.surfaceContainerLow,
            body: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12, right: 12),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Rail(app, extended: MediaQuery.sizeOf(context).width >= 1180),
                          Expanded(child: _Workspace(app)),
                        ],
                      ),
                    ),
                  ),
                ),
                DesktopPlayerBar(app),
              ],
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
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    return ValueListenableBuilder(
      valueListenable: app.activePanel,
      builder: (context, panel, _) {
        // Only the queue docks beside the content, and only on wide windows.
        final docked = panel == AppPanel.queue && width >= 1400;
        final showContent = panel == null || docked;
        Widget surface(Widget child, {EdgeInsets padding = const EdgeInsets.all(28)}) => Container(
          padding: padding,
          decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(24)),
          child: child,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (showContent) Expanded(child: surface(_Content(app))),
            if (panel != null)
              docked
                  ? SizedBox(width: 430, child: surface(_panel(panel), padding: const EdgeInsets.all(20)))
                  : Expanded(child: surface(_panel(panel))),
          ],
        );
      },
    );
  }

  Widget _panel(AppPanel panel) => switch (panel) {
    AppPanel.queue => QueuePanel(app),
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
    builder: (context, index, _) => switch (index) {
      0 => HomePage(app),
      1 => SearchPage(app),
      2 => LibraryPage(app),
      _ => PlaylistsPage(app),
    },
  );
}

class _Rail extends StatelessWidget {
  const _Rail(this.app, {required this.extended});

  final MelodyApp app;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: extended ? 208 : 80,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Watch([app.selectedNavigation, app.activePanel, app.services.downloads], builder: (context) {
        final panel = app.activePanel.value;
        final utility = panel == AppPanel.downloads || panel == AppPanel.settings;
        final active = app.services.downloads.activeCount();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 28),
              child: Row(
                mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 26),
                  ),
                  if (extended) ...[
                    const SizedBox(width: 12),
                    Text(
                      "Melody",
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: scheme.primary),
                    ),
                  ],
                ],
              ),
            ),
            if (extended)
              Padding(
                padding: const EdgeInsets.only(left: 14, bottom: 8),
                child: Text(
                  "YOUR MUSIC",
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                ),
              ),
            for (final (index, destination) in navigationDestinations.indexed)
              _RailButton(
                label: destination.label,
                icon: destination.icon,
                selectedIcon: destination.selectedIcon,
                selected: index == app.selectedNavigation.value && !utility,
                extended: extended,
                onPressed: () => app.navigate(index),
              ),
            const Spacer(),
            _RailButton(
              label: "Downloads",
              icon: Icons.download_rounded,
              selected: panel == AppPanel.downloads,
              extended: extended,
              badge: active > 0 ? "$active" : null,
              tooltip: active > 0 ? "Downloads, $active active (Ctrl+D)" : "Downloads (Ctrl+D)",
              onPressed: () => app.openPanel(AppPanel.downloads),
            ),
            _RailButton(
              label: "Settings",
              icon: Icons.settings_outlined,
              selected: panel == AppPanel.settings,
              extended: extended,
              tooltip: "Settings (Ctrl+,)",
              onPressed: () => app.openPanel(AppPanel.settings),
            ),
            if (extended)
              Padding(
                padding: const EdgeInsets.only(left: 14, top: 14, bottom: 12),
                child: Text(
                  "Ctrl L to find your next track",
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        );
      }),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
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
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    Widget symbol = Icon(selected ? (selectedIcon ?? icon) : icon, size: 22, color: color);
    if (badge != null) symbol = Badge(label: Text(badge!), child: symbol);
    return Tooltip(
      message: tooltip ?? label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: selected ? scheme.primaryContainer : Colors.transparent,
          foregroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: extended ? Alignment.centerLeft : Alignment.center,
        ),
        child: Row(
          mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            symbol,
            if (extended) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Title row for utility panels, with a close button.
class ContextHeader extends StatelessWidget {
  const ContextHeader(this.app, this.title, this.subtitle, {super.key, this.actions = const []});

  final MelodyApp app;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 12,
    children: [
      Expanded(child: Heading(title, subtitle)),
      ...actions,
      IconButton(onPressed: app.closePanel, tooltip: "Close (Esc)", icon: const Icon(Icons.close_rounded)),
    ],
  );
}
