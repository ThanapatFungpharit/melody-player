import "package:flutter/material.dart";

import "../../app_state.dart";
import "../../shared/statistics_view.dart";
import "../controls.dart";

/// Listening statistics as a mobile page.
class MobileStatistics extends StatelessWidget {
  const MobileStatistics(this.app, {super.key});

  final MelodyApp app;

  @override
  Widget build(BuildContext context) => StatisticsView(
    app,
    header: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MobileHeading(
        "Statistics",
        subtitle: "What you've been listening to.",
        large: true,
        actions: [
          TouchIconButton(
            Icons.arrow_back_rounded,
            "Back",
            () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    ),
  );
}
