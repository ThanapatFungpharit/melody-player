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
    widget.app.settingsControls.reset();
    widget.app.settingsControls.refreshPackageStatus();
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
      listenable: app.settingsControls,
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
        ],
      ),
    );
  }
}
