import "package:flutter/material.dart";

import "../../../app/app_state.dart";
import "../../shared/settings_sections.dart";
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
    widget.app.settingsDraft.refreshYtDlpStatus();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final scheme = Theme.of(context).colorScheme;
    Widget card(SettingsSection section) => Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant),
      ),
      // List tiles paint on the nearest Material, not on this decoration.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [SectionHeader(section), section.body],
        ),
      ),
    );
    return ListenableBuilder(
      listenable: app.settingsDraft,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primaryContainer, scheme.surfaceContainerLow],
              ),
            ),
            child: ContextHeader(app, "Settings", "Shape your listening experience."),
          ),
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
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "Changes are saved locally on this device.",
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
                TextButton(onPressed: app.settingsDraft.cancel, child: const Text("Cancel")),
                const SizedBox(width: 12),
                SizedBox(
                  width: 180,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () => app.run(app.settingsDraft.save),
                    icon: const Icon(Icons.save_rounded),
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
