import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/dialogs.dart";
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
    widget.app.settingsDraft.reset();
    widget.app.settingsDraft.refreshPackageStatus();
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
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

    return ListenableBuilder(
      listenable: app.settingsDraft,
      builder: (context, _) => Column(
        spacing: 10,
        children: [
          Expanded(
            child: scrollPage([
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
              tile(downloadSettings(context, app, mobile: true)),
              tile(youtubeSettings(context, app)),
              tile(maintenanceSettings(context, app)),
              tile(dataManagementSettings(context, app)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              spacing: 12,
              children: [
                TextButton(
                  onPressed: () {
                    app.settingsDraft.cancel();
                    Navigator.of(context).maybePop();
                  },
                  child: const Text("Cancel"),
                ),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => saveSettings(context, app),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text("Save settings"),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
