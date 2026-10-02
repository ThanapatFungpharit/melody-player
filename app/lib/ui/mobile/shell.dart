import "package:flutter/material.dart";

import "../../app/app_state.dart";
import "../shared/navigation.dart";
import "controls.dart";
import "pages.dart";
import "player.dart";

/// Header, content, mini player, and bottom navigation for touch devices.
class MobileShell extends StatelessWidget {
  const MobileShell(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: app.selectedNavigation,
      builder: (context, index, _) => PopScope(
        // Back from another destination returns Home before leaving the app;
        // playlist detail handles its own back press.
        canPop: index == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && index != 0 && app.playlists.selectedPlaylistId == null) app.navigate(0);
        },
        child: Scaffold(
          body: SafeArea(
            maintainBottomViewPadding: true,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    spacing: 4,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.graphic_eq_rounded, color: scheme.primary),
                      ),
                      Expanded(
                        child: Text(
                          "Melody",
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: scheme.primary),
                        ),
                      ),
                      ListenableBuilder(
                        listenable: app.services.downloads,
                        builder: (context, _) {
                          final active = app.services.downloads.activeCount();
                          return IconButton(
                            onPressed: () => pushPanel(context, app, AppPanel.downloads, MobileDownloads(app)),
                            tooltip: active > 0 ? "Downloads, $active active" : "Downloads",
                            icon: Badge(
                              isLabelVisible: active > 0,
                              label: Text("$active"),
                              child: const Icon(Icons.download_rounded),
                            ),
                          );
                        },
                      ),
                      TouchIconButton(
                        Icons.settings_rounded,
                        "Settings",
                        () => pushPanel(context, app, AppPanel.settings, MobileSettings(app)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: switch (index) {
                      0 => MobileHome(app),
                      1 => MobileSearch(app),
                      2 => MobileLibrary(app),
                      _ => MobilePlaylists(app),
                    },
                  ),
                ),
                MiniPlayer(app),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            height: 64,
            selectedIndex: index,
            backgroundColor: scheme.surfaceContainerLow,
            indicatorColor: scheme.primaryContainer,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: app.navigate,
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
      ),
    );
  }
}
