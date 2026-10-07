import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/settings_sections.dart";
import "../../shared/theme.dart";
import "../controls.dart";
import "../shell.dart";

class SettingsPanel extends StatefulWidget {
  const SettingsPanel(this.app, {super.key});

  final MelodyApp app;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  @override
  void initState() {
    super.initState();
    widget.app.settingsDraft.reset();
    widget.app.settingsDraft.refreshPackageStatus();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = context.colors;
    Widget card(SettingsSection section) => Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.panel),
      ),
      // List tiles paint on the nearest Material, not on this decoration.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 18,
          children: [SectionHeader(section), section.body],
        ),
      ),
    );
    return ListenableBuilder(
      listenable: app.settingsDraft,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 20,
        children: [
          ContextHeader(app, "Settings", "Shape your listening experience."),
          Expanded(
            child: SingleChildScrollView(
              child: ResponsiveGrid(
                children: [
                  GridCell(
                    Column(
                      spacing: 16,
                      children: [
                        card(appearanceSettings(context, app)),
                        card(youtubeSettings(context, app)),
                        card(maintenanceSettings(context, app)),
                      ],
                    ),
                    lg: 5,
                  ),
                  GridCell(
                    Column(
                      spacing: 16,
                      children: [
                        card(downloadSettings(context, app, mobile: false)),
                        card(dataManagementSettings(context, app)),
                      ],
                    ),
                    lg: 7,
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              spacing: 10,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                Expanded(
                  child: Text(
                    "Changes are saved locally on this device.",
                    style: context.text.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: app.settingsDraft.cancel,
                  child: const Text("Cancel"),
                ),
                FilledButton.icon(
                  onPressed: () => app.run(app.settingsDraft.save),
                  icon: const Icon(Icons.check_rounded, size: 20),
                  label: const Text("Save settings"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
