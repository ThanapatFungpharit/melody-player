import "dart:math";

import "package:flutter/material.dart";

import "../../application/listening.dart";
import "../../application/models.dart" show dayStart;
import "../app_state.dart";
import "../controllers/statistics_controller.dart";
import "format.dart" show plural;
import "theme.dart";
import "widgets.dart";

const _months = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];
const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

String _date(DateTime day) => "${_months[day.month - 1]} ${day.day}";

/// "This week", "Last month", or the dates a range covers.
String statsRangeLabel(StatsRange range, int offset) {
  final first = dayStart(range.firstDay);
  final last = dayStart(range.lastDay);
  return switch ((range.period, offset)) {
    (StatsPeriod.week, 0) => "This week",
    (StatsPeriod.week, 1) => "Last week",
    (StatsPeriod.month, 0) => "This month",
    (StatsPeriod.month, 1) => "Last month",
    (StatsPeriod.week, _) => "${_date(first)} – ${_date(last)}",
    (StatsPeriod.month, _) => "${_months[first.month - 1]} ${first.year}",
  };
}

/// Listening time as "3 h 12 min" or "45 min".
String listeningTime(int milliseconds) {
  final minutes = (milliseconds / 60000).round();
  if (minutes < 60) return "$minutes min";
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? "$hours h" : "$hours h $rest min";
}

/// Listening statistics, shared by the desktop panel and the mobile page.
/// [header] goes above the controls; the view scrolls as a whole.
class StatisticsView extends StatefulWidget {
  const StatisticsView(this.app, {super.key, this.header});

  final MelodyApp app;
  final Widget? header;

  @override
  State<StatisticsView> createState() => _StatisticsViewState();
}

class _StatisticsViewState extends State<StatisticsView> {
  StatisticsController get _controller => widget.app.statistics;

  @override
  void initState() {
    super.initState();
    _controller.show();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final controller = _controller;
      final stats = controller.stats;
      final shown = stats != null && stats.range == controller.range
          ? stats
          : null;
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ?widget.header,
          _PeriodBar(controller),
          const SizedBox(height: 20),
          if (controller.error case final error?)
            EmptyState(Icons.error_outline_rounded, error)
          else if (shown == null)
            const LoadingRow("Adding up your listening…")
          else if (shown.isEmpty)
            _Card(
              child: EmptyState(
                Icons.insights_rounded,
                controller.offset == 0
                    ? "Nothing here yet. A song counts once you've heard half "
                          "of it, or four minutes."
                    : "You didn't listen to anything in this period.",
              ),
            )
          else
            _StatsBody(widget.app, shown, today: controller.today),
        ],
      );
    },
  );
}

/// A neutral rounded surface that groups one part of the statistics.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Radii.large),
    ),
    child: child,
  );
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar(this.controller);

  final StatisticsController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        SegmentedButton<StatsPeriod>(
          segments: [
            for (final period in StatsPeriod.values)
              ButtonSegment(value: period, label: Text(period.label)),
          ],
          selected: {controller.period},
          showSelectedIcon: false,
          onSelectionChanged: (value) => controller.setPeriod(value.single),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: "Earlier",
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.move(1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 112),
                child: Text(
                  statsRangeLabel(controller.range, controller.offset),
                  textAlign: TextAlign.center,
                  style: context.text.titleSmall,
                ),
              ),
              IconButton(
                tooltip: "Later",
                visualDensity: VisualDensity.compact,
                onPressed: controller.offset > 0
                    ? () => controller.move(-1)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody(this.app, this.stats, {required this.today});

  final MelodyApp app;
  final ListeningStats stats;
  final int today;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Days of the range that have begun, for daily averages.
      final elapsed = stats.days.where((day) => day.day <= today).length;
      final active = stats.days.where((day) => day.listens > 0).length;
      final tracks = _TopList(
        "Top tracks",
        stats.topTracks,
        leading: (entry) => Artwork(
          app,
          entry.trackId != null && app.services.manager.hasTrack(entry.trackId!)
              ? app.services.library.artwork(entry.trackId!)
              : "",
          seed: entry.name,
          size: 40,
        ),
      );
      final artists = _TopList(
        "Top artists",
        stats.topArtists,
        leading: (entry) => _Initial(entry.name),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          _Grid(
            columns: width >= 640 ? 4 : 2,
            children: [
              _Metric(
                Icons.headphones_rounded,
                "Listened",
                listeningTime(stats.listenedMs),
                caption: elapsed > 1
                    ? "About ${listeningTime(stats.listenedMs ~/ elapsed)} a day"
                    : "",
              ),
              _Metric(
                Icons.play_arrow_rounded,
                "Plays",
                "${stats.listens}",
                caption: "On ${plural(active, "day")}",
              ),
              _Metric(
                Icons.music_note_rounded,
                "Tracks",
                "${stats.tracks}",
                caption: stats.tracks == 1 ? "One song" : "Different songs",
              ),
              _Metric(
                Icons.local_fire_department_rounded,
                "Streak",
                plural(stats.currentStreak, "day"),
                caption: "Best: ${plural(stats.longestStreak, "day")}",
                accent: stats.currentStreak > 0,
              ),
            ],
          ),
          _DailyChart(stats, today: today),
          // Track titles run longer than artist names, so tracks get more
          // of the row.
          if (width >= 720)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Expanded(flex: 3, child: tracks),
                  Expanded(flex: 2, child: artists),
                ],
              ),
            )
          else ...[
            tracks,
            artists,
          ],
        ],
      );
    },
  );
}

/// [children] in rows of [columns] equal cells.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      for (var start = 0; start < children.length; start += columns)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              for (var index = start; index < start + columns; index++)
                Expanded(
                  child: index < children.length
                      ? children[index]
                      : const SizedBox(),
                ),
            ],
          ),
        ),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric(
    this.icon,
    this.label,
    this.value, {
    this.caption = "",
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String caption;

  /// Whether the icon takes the accent, for a value worth celebrating.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final muted = context.text.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Semantics(
      container: true,
      label: [label, value, caption].where((s) => s.isNotEmpty).join(", "),
      child: ExcludeSemantics(
        child: _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                spacing: 8,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: accent
                          ? scheme.primary.withValues(alpha: 0.14)
                          : scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: 16,
                      color: accent ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelLarge!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  value,
                  maxLines: 1,
                  style: context.text.headlineSmall!.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              if (caption.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A round placeholder with a name's first letter, for artists.
class _Initial extends StatelessWidget {
  const _Initial(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final trimmed = name.trim();
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Text(
        trimmed.isEmpty ? "?" : trimmed.characters.first.toUpperCase(),
        style: context.text.titleSmall!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A step for the chart's guide lines, in minutes, giving about three lines
/// up to [most] minutes.
int _gridStep(double most) {
  const steps = [1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360, 480, 720];
  for (final step in steps) {
    if (most / step <= 3) return step;
  }
  return steps.last;
}

String _minutesLabel(int minutes) =>
    minutes < 60 ? "$minutes min" : "${minutes ~/ 60} h";

/// Minutes listened per day, as bars over guide lines.
class _DailyChart extends StatelessWidget {
  const _DailyChart(this.stats, {required this.today});

  final ListeningStats stats;
  final int today;

  static const _height = 140.0;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final days = stats.days;
    final week = stats.range.period == StatsPeriod.week;
    final best = days.fold(0, (most, day) => max(most, day.listenedMs));
    final bestDay = days.where((day) => day.listenedMs == best).firstOrNull;
    final summary = best <= 0 || bestDay == null
        ? ""
        : "Most on ${_date(dayStart(bestDay.day))}: ${listeningTime(best)}";
    final step = _gridStep(best / 60000);
    final lines = max(1, (best / 60000 / step).ceil());
    final scale = (lines * step * 60000).toDouble();
    final muted = context.text.labelSmall!.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0,
    );
    return Semantics(
      label: "Listening time per day. $summary",
      child: _Card(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 2,
              children: [
                Text("Listening per day", style: context.text.titleSmall),
                if (summary.isNotEmpty)
                  Text(
                    summary,
                    style: context.text.bodySmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Expanded(
                    child: Column(
                      spacing: 6,
                      children: [
                        SizedBox(
                          height: _height,
                          child: CustomPaint(
                            painter: _GuidesPainter(
                              lines,
                              color: scheme.outlineVariant,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final day in days)
                                  Expanded(
                                    child: _Bar(
                                      day,
                                      share: day.listenedMs / scale,
                                      today: day.day == today,
                                      future: day.day > today,
                                      best: best > 0 && day.listenedMs == best,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (final (index, day) in days.indexed)
                              Expanded(
                                child: Text(
                                  week
                                      ? _weekdays[index % 7].substring(0, 1)
                                      : (index == 0 ||
                                            (index + 1) % 5 == 0 ||
                                            index == days.length - 1)
                                      ? "${dayStart(day.day).day}"
                                      : "",
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: day.day == today
                                      ? muted.copyWith(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w700,
                                        )
                                      : muted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Guide line values, centered on the lines they label.
                  SizedBox(
                    height: _height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var line = 0; line <= lines; line++)
                          Positioned(
                            left: 0,
                            top: _height * (1 - line / lines) - 7,
                            height: 14,
                            child: Text(
                              line == 0 ? "0" : _minutesLabel(line * step),
                              style: muted.copyWith(height: 14 / 11),
                            ),
                          ),
                        // Sizes the column to its widest label.
                        Visibility.maintain(
                          visible: false,
                          child: Text(
                            _minutesLabel(lines * step),
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One day's bar, with its date and totals on hover or long press.
class _Bar extends StatelessWidget {
  const _Bar(
    this.day, {
    required this.share,
    required this.today,
    required this.future,
    required this.best,
  });

  final DayTotal day;

  /// The bar's height as a share of the chart's.
  final double share;
  final bool today;
  final bool future;
  final bool best;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final date = dayStart(day.day);
    final message = future
        ? "${_weekdays[date.weekday - 1]}, ${_date(date)}"
        : "${_weekdays[date.weekday - 1]}, ${_date(date)}\n"
              "${day.listens == 0 ? "No plays" : "${listeningTime(day.listenedMs)} · ${plural(day.listens, "play")}"}";
    final color = best || today
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.6);
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 150),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = max(3.0, min(constraints.maxWidth * 0.62, 28.0));
          final radius = Radius.circular(min(width / 2, 6));
          final height = constraints.maxHeight * share.clamp(0.0, 1.0);
          final empty = height < 3;
          return Container(
            // The whole column takes the hover, not just the bar.
            color: Colors.transparent,
            alignment: Alignment.bottomCenter,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: empty ? 3 : height),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => Container(
                width: width,
                height: value,
                decoration: BoxDecoration(
                  color: empty
                      ? (future
                            ? scheme.surfaceContainerHigh
                            : scheme.surfaceContainerHighest)
                      : color,
                  borderRadius: empty
                      ? BorderRadius.all(radius)
                      : BorderRadius.vertical(top: radius),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Horizontal guide lines: the baseline and [count] lines evenly above it.
class _GuidesPainter extends CustomPainter {
  _GuidesPainter(this.count, {required this.color});

  final int count;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var line = 0; line <= count; line++) {
      final y = (size.height - 0.5) * (1 - line / count) + 0.5;
      if (line == 0) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        continue;
      }
      // Dashed, so the bars stay the strongest marks.
      for (var x = 0.0; x < size.width; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(min(x + 3, size.width), y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GuidesPainter old) =>
      old.count != count || old.color != color;
}

/// A ranked list with a bar showing each row's share of the first. It shows
/// the first five rows until asked for the rest.
class _TopList extends StatefulWidget {
  const _TopList(this.title, this.entries, {this.leading});

  final String title;
  final List<StatsEntry> entries;
  final Widget Function(StatsEntry entry)? leading;
  static const _collapsed = 5;

  @override
  State<_TopList> createState() => _TopListState();
}

class _TopListState extends State<_TopList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final entries = widget.entries;
    final top = entries.isEmpty ? 1 : max(1, entries.first.listens);
    final more = entries.length > _TopList._collapsed;
    final shown = _expanded || !more
        ? entries
        : entries.take(_TopList._collapsed).toList();
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(widget.title, style: context.text.titleSmall),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                "Nothing yet.",
                style: context.text.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final (rank, entry) in shown.indexed)
            _TopRow(
              rank + 1,
              entry,
              share: entry.listens / top,
              leading: widget.leading?.call(entry),
            ),
          if (more)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  _expanded ? "Show fewer" : "Show all ${entries.length}",
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow(
    this.rank,
    this.entry, {
    required this.share,
    required this.leading,
  });

  final int rank;
  final StatsEntry entry;
  final double share;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final muted = context.text.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final first = rank == 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        spacing: 12,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              "$rank",
              textAlign: TextAlign.center,
              style: context.text.labelLarge!.copyWith(
                color: first ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: first ? FontWeight.w700 : null,
              ),
            ),
          ),
          ?leading,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (entry.detail.isNotEmpty)
                  Text(
                    entry.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: share,
                      minHeight: 4,
                      color: first
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.6),
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 2,
            children: [
              Text(
                plural(entry.listens, "play"),
                style: context.text.labelLarge,
              ),
              Text(listeningTime(entry.listenedMs), style: muted),
            ],
          ),
        ],
      ),
    );
  }
}
