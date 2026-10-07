import "package:flutter/material.dart";

import "../app_state.dart";
import "../shared/navigation.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";
import "controls.dart";
import "pages/downloads_page.dart";
import "pages/home_page.dart";
import "pages/library_page.dart";
import "pages/playlists_page.dart";
import "pages/search_page.dart";
import "pages/settings_page.dart";
import "player.dart";

/// Header, content, mini player, and bottom navigation for touch devices.
class MobileShell extends StatelessWidget {
  const MobileShell(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return ValueListenableBuilder(
      valueListenable: app.selectedNavigation,
      builder: (context, index, _) => PopScope(
        // Back from another destination returns Home before leaving the app;
        // playlist detail handles its own back press.
        canPop: index == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop &&
              index != 0 &&
              app.playlists.selectedPlaylistId == null) {
            app.navigate(0);
          }
        },
        child: Scaffold(
          body: SafeArea(
            maintainBottomViewPadding: true,
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 6, 0),
                  child: Row(
                    spacing: 2,
                    children: [
                      const BrandMark(size: 30),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Melody",
                          style: context.text.titleLarge!.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                      ),
                      ListenableBuilder(
                        listenable: app.services.downloads,
                        builder: (context, _) {
                          final active = app.services.downloads.activeCount();
                          return IconButton(
                            onPressed: () => pushPanel(
                              context,
                              app,
                              AppPanel.downloads,
                              MobileDownloads(app),
                            ),
                            tooltip: active > 0
                                ? "Downloads, $active active"
                                : "Downloads",
                            icon: Badge(
                              isLabelVisible: active > 0,
                              label: Text("$active"),
                              child: const Icon(Icons.download_rounded),
                            ),
                          );
                        },
                      ),
                      TouchIconButton(
                        Icons.settings_outlined,
                        "Settings",
                        () => pushPanel(
                          context,
                          app,
                          AppPanel.settings,
                          MobileSettings(app),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: PageSwitcher(
                      child: KeyedSubtree(
                        key: ValueKey(index),
                        child: switch (index) {
                          0 => MobileHome(app),
                          1 => MobileSearch(app),
                          2 => MobileLibrary(app),
                          _ => MobilePlaylists(app),
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // In the bottom slot, snackbars float above the mini player instead
          // of covering its controls.
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MiniPlayer(app),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                child: NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: (target) {
                    if (target == 3 && index == 3) {
                      app.playlists.closePlaylist();
                    }
                    app.navigate(target);
                  },
                  destinations: [
                    for (final destination in navigationDestinations)
                      NavigationDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: destination.label,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
