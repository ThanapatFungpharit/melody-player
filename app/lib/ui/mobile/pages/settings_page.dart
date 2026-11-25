import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/listening_settings.dart";
import "../../shared/settings_sections.dart";
import "../../shared/theme.dart";
import "../controls.dart";

class MobileSettings extends StatefulWidget {
  const MobileSettings(this.app, {super.key});

  final MelodyApp app;

  @override
  State<MobileSettings> createState() => _MobileSettingsState();
}

class _MobileSettingsState extends State<MobileSettings> {
  @override
  void initState() {
    super.initState();
    widget.app.settingsControls.reset();
    widget.app.settingsControls.refreshPackageStatus();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = Theme.of(context).colorScheme;
    Widget tile(SettingsSection section) {
      final color = section.destructive ? scheme.error : scheme.primary;
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.large),
      );
      return ExpansionTile(
        title: Text(
          section.mobileTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          section.mobileSubtitle,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        leading: Icon(section.icon, color: color),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 3, 16, 16),
        backgroundColor: scheme.surfaceContainerLow,
        collapsedBackgroundColor: scheme.surfaceContainerLow,
        shape: shape,
        collapsedShape: shape,
        iconColor: color,
        collapsedIconColor: color,
        maintainState: true,
        children: [
          Material(type: MaterialType.transparency, child: section.body),
        ],
      );
    }

    // Section subtitles summarize the equalizer and scrobbling too.
    return StreamBuilder<void>(
      stream: app.adjustments.changes,
      builder: (context, _) => ListenableBuilder(
        listenable: Listenable.merge([app.settingsControls, app.scrobbler]),
        builder: (context, _) => scrollPage([
          MobileHeading(
            "Settings",
            subtitle: "Make Melody feel like yours.",
            large: true,
            actions: [
              TouchIconButton(
                Icons.arrow_back_rounded,
                "Back",
                () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          tile(appearanceSettings(context, app)),
          tile(soundSettings(context, app)),
          tile(downloadSettings(context, app, mobile: true)),
          tile(powerSettings(context, app)),
          tile(youtubeSettings(context, app)),
          tile(scrobblingSettings(context, app)),
          tile(maintenanceSettings(context, app)),
          tile(dataManagementSettings(context, app)),
        ]),
      ),
    );
  }
}
