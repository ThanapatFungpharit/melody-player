import "dart:async";

import "package:flutter/material.dart";

import "../../app/app_state.dart";
import "../shared/actions.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";

class MobileHeading extends StatelessWidget {
  const MobileHeading(this.title, {super.key, this.subtitle = "", this.actions = const []});

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Row(
          spacing: 10,
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
            ),
            Expanded(
              child: Text(title, maxLines: 2, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            ),
            ...actions,
          ],
        ),
        if (subtitle.isNotEmpty) Text(subtitle, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class TouchIconButton extends StatelessWidget {
  const TouchIconButton(this.icon, this.tooltip, this.onPressed, {super.key});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    constraints: const BoxConstraints.tightFor(width: touchTarget, height: touchTarget),
    icon: Icon(icon),
  );
}

/// Shows [actions] in a scrollable bottom sheet that respects system insets.
Future<void> showActionSheet(BuildContext context, String title, List<MenuAction> actions) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          MobileHeading(
            title,
            actions: [
              TouchIconButton(Icons.close_rounded, "Close actions", () => Navigator.of(sheetContext).pop()),
            ],
          ),
          for (final action in actions)
            ListTile(
              enabled: action.enabled,
              minTileHeight: 52,
              leading: Icon(action.icon),
              title: Text(action.label, maxLines: 2),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(Future.sync(action.onSelected));
              },
            ),
        ],
      ),
    );

class MoreButton extends StatelessWidget {
  const MoreButton(this.title, this.actions, {super.key});

  final String title;
  final List<MenuAction> Function() actions;

  @override
  Widget build(BuildContext context) => TouchIconButton(
    Icons.more_horiz_rounded,
    "Actions for $title",
    () => showActionSheet(context, title, actions()),
  );
}

/// A tappable row: artwork, title, credit, and a trailing control.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.app,
    required this.title,
    required this.credit,
    required this.artwork,
    required this.onTap,
    required this.trailing,
    this.selected = false,
  });

  final MelodyApp app;
  final String title;
  final String credit;
  final String artwork;
  final VoidCallback onTap;
  final Widget trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Row(
          spacing: 4,
          children: [
            Expanded(
              child: Tooltip(
                message: "Play $title",
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      spacing: 12,
                      children: [
                        Artwork(app, artwork, size: 48),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 3,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                credit,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// A full-screen panel pushed over the shell.
Future<void> pushPanel(BuildContext context, MelodyApp app, AppPanel panel, Widget child) {
  app.openPanel(panel);
  return Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            body: SafeArea(
              maintainBottomViewPadding: true,
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      )
      .whenComplete(() {
        if (app.activePanel.value == panel) app.closePanel();
      });
}
