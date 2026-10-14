import "dart:async";

import "package:flutter/material.dart";

import "../app_state.dart";
import "../shared/actions.dart";
import "../shared/theme.dart";
import "../shared/widgets.dart";

/// A page title with an optional small eyebrow and a subtitle.
class Heading extends StatelessWidget {
  const Heading(this.title, this.subtitle, {super.key, this.eyebrow = ""});

  final String title;
  final String subtitle;
  final String eyebrow;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (eyebrow.isNotEmpty) ...[
        Text(eyebrow.toUpperCase(), style: context.text.labelSmall),
        const SizedBox(height: 6),
      ],
      Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.text.headlineMedium,
      ),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: context.text.bodyMedium!.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    ],
  );
}

/// A rounded low-emphasis surface, optionally highlighting on hover.
class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.hover = false,
    this.onTap,
    this.selected = false,
    this.radius = Radii.large,
    this.width,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool hover;
  final VoidCallback? onTap;
  final bool selected;
  final double radius;
  final double? width;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Hoverable(
      builder: (context, hovered) {
        final base = color ?? scheme.surfaceContainerLow;
        final background = selected
            ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.12), base)
            : hovered && hover
            ? Color.alphaBlend(context.palette.hover, base)
            : base;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          width: width,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: onTap,
              child: Padding(padding: padding, child: child),
            ),
          ),
        );
      },
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final foreground = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color?.withValues(alpha: 0.12) ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (icon != null) Icon(icon, size: 14, color: foreground),
          Text(
            label,
            style: context.text.labelMedium!.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

/// A "more" button, or [icon], listing [actions].
class ActionMenu extends StatelessWidget {
  const ActionMenu(
    this.actions, {
    super.key,
    this.tooltip = "More actions",
    this.icon,
  });

  final List<MenuAction> Function() actions;
  final String tooltip;
  final Widget? icon;

  @override
  Widget build(BuildContext context) => PopupMenuButton<MenuAction>(
    icon:
        icon ??
        Icon(Icons.more_horiz_rounded, color: context.colors.onSurfaceVariant),
    tooltip: tooltip,
    position: PopupMenuPosition.under,
    itemBuilder: (context) => [
      for (final action in actions())
        PopupMenuItem(
          value: action,
          enabled: action.enabled,
          height: 42,
          child: Row(
            children: [
              Icon(action.icon, size: 19),
              const SizedBox(width: 12),
              Flexible(child: Text(action.label)),
            ],
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
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
    label: Text(label),
  );
}

/// The round accent play button that leads a page's actions.
class PlayCircle extends StatelessWidget {
  const PlayCircle({
    super.key,
    required this.onPressed,
    required this.tooltip,
    this.size = 52,
    this.icon = Icons.play_arrow_rounded,
  });

  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    onPressed: onPressed,
    tooltip: tooltip,
    iconSize: size * 0.56,
    style: IconButton.styleFrom(
      fixedSize: Size.square(size),
      minimumSize: Size.square(size),
      shape: const CircleBorder(),
      elevation: 0,
    ),
    icon: Icon(icon),
  );
}

/// A cover with a title and caption; reveals a play button on hover.
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.app,
    required this.title,
    required this.subtitle,
    required this.artwork,
    this.seed = "",
    this.playlist = false,
    this.width = 184,
    this.titleLines = 1,
    this.onTap,
    this.onPlay,
    this.playTooltip = "Play",
    this.footer,
  });

  final MelodyApp app;
  final String title;
  final String subtitle;
  final String artwork;
  final String seed;
  final bool playlist;
  final double width;
  final int titleLines;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final String playTooltip;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final cover = width - 20;
    return Hoverable(
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: width,
        decoration: BoxDecoration(
          color: hovered ? context.palette.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.large),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.large),
            onTap: onTap ?? onPlay,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    children: [
                      Artwork(
                        app,
                        artwork,
                        size: cover,
                        playlist: playlist,
                        seed: seed.isEmpty ? title : seed,
                      ),
                      if (onPlay != null)
                        Positioned(
                          right: 10,
                          bottom: 10,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 140),
                            opacity: hovered ? 1 : 0,
                            child: AnimatedSlide(
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              offset: hovered
                                  ? Offset.zero
                                  : const Offset(0, 0.25),
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Color(0x40000000),
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: PlayCircle(
                                  onPressed: onPlay,
                                  tooltip: playTooltip,
                                  size: 46,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: titleLines > 1 ? 40 : null,
                    child: Text(
                      title,
                      maxLines: titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleSmall,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                  ?footer,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Column labels above a [TrackListRow] list.
class TrackListHeader extends StatelessWidget {
  const TrackListHeader({
    super.key,
    this.numbered = true,
    this.leadingWidth = 0,
    this.trailingWidth = 120,
  });

  final bool numbered;
  final double leadingWidth;
  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    final style = context.text.labelSmall;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.colors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(width: leadingWidth),
          if (numbered)
            SizedBox(
              width: 36,
              child: Text("#", textAlign: TextAlign.center, style: style),
            ),
          const SizedBox(width: 14 + 44),
          Expanded(child: Text("TITLE", style: style)),
          SizedBox(
            width: 76,
            child: Align(
              alignment: Alignment.centerRight,
              child: Icon(
                Icons.schedule_rounded,
                size: 15,
                color: style!.color,
              ),
            ),
          ),
          SizedBox(width: trailingWidth),
        ],
      ),
    );
  }
}

/// One track in a desktop list: number (a play button on hover), cover,
/// title and credit, duration, favorite, and trailing controls.
class TrackListRow extends StatelessWidget {
  const TrackListRow({
    super.key,
    required this.app,
    required this.title,
    required this.subtitle,
    required this.artwork,
    this.number,
    this.leading,
    this.duration = "",
    this.status = "",
    this.statusHighlight = false,
    this.favorite,
    this.onFavorite,
    this.onPlay,
    this.playTooltip = "Play",
    this.trailing = const [],
    this.current = false,
    this.playlist = false,
  });

  final MelodyApp app;
  final String title;
  final String subtitle;
  final String artwork;
  final int? number;
  final Widget? leading;
  final String duration;
  final String status;
  final bool statusHighlight;
  final bool? favorite;
  final VoidCallback? onFavorite;
  final VoidCallback? onPlay;
  final String playTooltip;
  final List<Widget> trailing;
  final bool current;
  final bool playlist;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final palette = context.palette;
    return Hoverable(
      builder: (context, hovered) {
        final background = current
            ? scheme.primary.withValues(alpha: 0.10)
            : hovered
            ? palette.hover
            : Colors.transparent;
        final play = IconButton(
          onPressed: onPlay,
          tooltip: playTooltip,
          iconSize: 22,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.play_arrow_rounded),
        );
        final Widget numberCell;
        if (number == null) {
          numberCell = const SizedBox.shrink();
        } else {
          numberCell = SizedBox(
            width: 36,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The play button stays in the tree so keyboard and
                // screen-reader users can always reach it.
                Opacity(opacity: hovered ? 1 : 0, child: play),
                if (!hovered)
                  IgnorePointer(
                    child: current
                        ? const NowPlayingMark()
                        : Text(
                            "$number",
                            style: context.text.bodyMedium!.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                  ),
              ],
            ),
          );
        }
        final isFavorite = favorite ?? false;
        return GestureDetector(
          onDoubleTap: onPlay,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(Radii.medium),
            ),
            child: Row(
              children: [
                ?leading,
                numberCell,
                SizedBox(width: number == null ? 0 : 14),
                Artwork(
                  app,
                  artwork,
                  size: 44,
                  seed: title,
                  playlist: playlist,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleSmall!.copyWith(
                          color: current ? scheme.primary : null,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall,
                      ),
                      if (status.isNotEmpty)
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.labelMedium!.copyWith(
                            fontSize: 11,
                            color: statusHighlight
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (duration.isNotEmpty)
                  SizedBox(
                    width: 76,
                    child: Text(
                      duration,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: context.text.bodySmall!.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (favorite != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Opacity(
                      opacity: hovered || isFavorite ? 1 : 0,
                      child: IconButton(
                        onPressed: onFavorite,
                        tooltip: isFavorite ? "Remove favorite" : "Favorite",
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: isFavorite
                              ? palette.favorite
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                if (number == null && onPlay != null) play,
                ...trailing,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Lays children out in a 12-column grid at Bootstrap-style breakpoints:
/// xs < 576 ≤ sm < 768 ≤ md < 992 ≤ lg < 1200 ≤ xl.
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
        crossAxisAlignment: center
            ? WrapCrossAlignment.center
            : WrapCrossAlignment.start,
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
  const GridCell(
    this.child, {
    this.xs = 12,
    this.sm,
    this.md,
    this.lg,
    this.xl,
  });

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

/// A grid of [CoverCard]-sized children that fills the available width.
class CoverGrid extends StatelessWidget {
  const CoverGrid({super.key, required this.children, this.minWidth = 176});

  final List<Widget Function(double width)> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / minWidth).floor().clamp(1, 12);
      final width = constraints.maxWidth / columns;
      return Wrap(children: [for (final child in children) child(width)]);
    },
  );
}
