import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/statistics_view.dart";
import "../shell.dart";

/// Listening statistics as a desktop panel.
class StatisticsPanel extends StatelessWidget {
  const StatisticsPanel(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 20,
    children: [
      ContextHeader(
        app,
        "Statistics",
        "What you've been listening to, from this device.",
      ),
      Expanded(child: StatisticsView(app)),
    ],
  );
}
