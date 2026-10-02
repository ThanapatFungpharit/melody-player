import "dart:async";

import "package:flutter/material.dart";

import "../shared/actions.dart";

/// A page title with the accent bar and a subtitle.
class Heading extends StatelessWidget {
  const Heading(this.title, this.subtitle, {super.key});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 30,
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// A rounded low-emphasis surface, optionally highlighting on hover.
class Surface extends StatefulWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.hover = false,
    this.onTap,
    this.selected = false,
    this.radius = 18,
    this.width,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool hover;
  final VoidCallback? onTap;
  final bool selected;
  final double radius;
  final double? width;

  @override
  State<Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<Surface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.selected
        ? scheme.primaryContainer
        : _hovered && widget.hover
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLow;
    return MouseRegion(
      onEnter: widget.hover ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.hover ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: widget.width,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(widget.radius)),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(widget.radius),
            onTap: widget.onTap,
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: scheme.primary), const SizedBox(width: 8)],
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
          ),
        ],
      ),
    );
  }
}

/// A "more" button listing [actions].
class ActionMenu extends StatelessWidget {
  const ActionMenu(this.actions, {super.key, this.tooltip = "More actions"});

  final List<MenuAction> Function() actions;
  final String tooltip;

  @override
  Widget build(BuildContext context) => PopupMenuButton<MenuAction>(
    icon: const Icon(Icons.more_horiz_rounded),
    tooltip: tooltip,
    itemBuilder: (context) => [
      for (final action in actions())
        PopupMenuItem(
          value: action,
          enabled: action.enabled,
          child: Row(
            children: [Icon(action.icon, size: 20), const SizedBox(width: 12), Flexible(child: Text(action.label))],
          ),
        ),
    ],
    onSelected: (action) => unawaited(Future.sync(action.onSelected)),
  );
}

/// Primary filled action used across desktop headers.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, this.icon, this.onPressed, {super.key});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
  );
}

/// Lays children out in a 12-column grid at breakpoints like Flet's
/// ResponsiveRow: xs < 576 ≤ sm < 768 ≤ md < 992 ≤ lg < 1200 ≤ xl.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.spacing = 16,
    this.runSpacing,
    this.center = false,
  });

  final List<GridCell> children;
  final double spacing;
  final double? runSpacing;

  /// Vertically centers cells in a run; otherwise they align to the top.
  final bool center;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      return Wrap(
        spacing: spacing,
        runSpacing: runSpacing ?? spacing,
        crossAxisAlignment: center ? WrapCrossAlignment.center : WrapCrossAlignment.start,
        children: [
          for (final cell in children)
            SizedBox(
              width: () {
                final columns = cell.columnsFor(width);
                if (columns >= 12) return width;
                return (width + spacing) * columns / 12 - spacing;
              }(),
              child: cell.child,
            ),
        ],
      );
    },
  );
}

class GridCell {
  const GridCell(this.child, {this.xs = 12, this.sm, this.md, this.lg, this.xl});

  final Widget child;
  final int xs;
  final int? sm;
  final int? md;
  final int? lg;
  final int? xl;

  int columnsFor(double width) {
    var columns = xs;
    if (width >= 576 && sm != null) columns = sm!;
    if (width >= 768) columns = md ?? sm ?? columns;
    if (width >= 992) columns = lg ?? md ?? sm ?? columns;
    if (width >= 1200) columns = xl ?? lg ?? md ?? sm ?? columns;
    return columns;
  }
}
