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
const _weekdays = ["M", "T", "W", "T", "F", "S", "S"];

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
          const SizedBox(height: 16),
          if (controller.error case final error?)
            EmptyState(Icons.error_outline_rounded, error)
          else if (shown == null)
            const LoadingRow("Adding up your listening…")
          else if (shown.isEmpty)
            EmptyState(
              Icons.insights_rounded,
              controller.offset == 0
                  ? "Nothing here yet. A song counts once you've heard half "
                        "of it, or four minutes."
                  : "You didn't listen to anything in this period.",
            )
          else
            _StatsBody(widget.app, shown),
        ],
      );
    },
  );
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar(this.controller);

  final StatisticsController controller;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
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
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: "Earlier",
            onPressed: () => controller.move(1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120),
            child: Text(
              statsRangeLabel(controller.range, controller.offset),
              textAlign: TextAlign.center,
              style: context.text.titleSmall,
            ),
          ),
          IconButton(
            tooltip: "Later",
            onPressed: controller.offset > 0 ? () => controller.move(-1) : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    ],
  );
}

class _StatsBody extends StatelessWidget {
  const _StatsBody(this.app, this.stats);

  final MelodyApp app;
  final ListeningStats stats;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final lists = [
        _TopList(
          "Top tracks",
          stats.topTracks,
          leading: (entry) => Artwork(
            app,
            entry.trackId != null &&
                    app.services.manager.hasTrack(entry.trackId!)
                ? app.services.library.artworkUri(entry.trackId!)
                : "",
            seed: entry.name,
            size: 40,
          ),
        ),
        _TopList("Top artists", stats.topArtists),
        _TopList(
          "Top albums",
          stats.topAlbums,
          empty: "Albums show here for songs whose source or tags name one.",
        ),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 20,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Tile("Listening time", listeningTime(stats.listenedMs)),
              _Tile("Plays", "${stats.listens}"),
              _Tile("Tracks", "${stats.tracks}"),
              _Tile(
                "Current streak",
                plural(stats.currentStreak, "day"),
                icon: Icons.local_fire_department_rounded,
              ),
              _Tile("Longest streak", plural(stats.longestStreak, "day")),
            ],
          ),
          _DailyChart(stats),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 20,
              children: [for (final list in lists) Expanded(child: list)],
            )
          else
            ...lists,
        ],
      );
    },
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            label,
            style: context.text.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (icon != null) Icon(icon, size: 18, color: scheme.primary),
              Text(value, style: context.text.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}

/// Minutes listened per day, as bars.
class _DailyChart extends StatelessWidget {
  const _DailyChart(this.stats);

  final ListeningStats stats;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final days = stats.days;
    final week = stats.range.period == StatsPeriod.week;
    final best = days.fold(0, (most, day) => max(most, day.listenedMs));
    final label = days.isEmpty
        ? ""
        : "Most on ${_date(dayStart(days.firstWhere((day) => day.listenedMs == best).day))}: "
              "${listeningTime(best)}";
    return Semantics(
      label: "Listening time per day. $label",
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.large),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Text("Listening per day", style: context.text.titleSmall),
            SizedBox(
              height: 120,
              child: CustomPaint(
                size: Size.infinite,
                painter: _BarsPainter(
                  [for (final day in days) day.listenedMs.toDouble()],
                  color: scheme.primary,
                  empty: scheme.surfaceContainerHighest,
                ),
              ),
            ),
            Row(
              children: [
                for (final (index, day) in days.indexed)
                  Expanded(
                    child: Text(
                      week
                          ? _weekdays[index % 7]
                          : (index == 0 ||
                                (index + 1) % 5 == 0 ||
                                index == days.length - 1)
                          ? "${dayStart(day.day).day}"
                          : "",
                      textAlign: TextAlign.center,
                      style: context.text.labelSmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            if (label.isNotEmpty)
              Text(
                label,
                style: context.text.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, {required this.color, required this.empty});

  final List<double> values;
  final Color color;
  final Color empty;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final top = values.reduce(max);
    final slot = size.width / values.length;
    final width = max(2.0, min(slot * 0.62, 28.0));
    final fill = Paint()..color = color;
    final track = Paint()..color = empty;
    for (final (index, value) in values.indexed) {
      final x = slot * index + (slot - width) / 2;
      final height = top <= 0 ? 0.0 : size.height * value / top;
      final radius = Radius.circular(min(width / 2, 6));
      if (height < 3) {
        canvas.drawRRect(
          RRect.fromLTRBR(x, size.height - 3, x + width, size.height, radius),
          track,
        );
        continue;
      }
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          x,
          size.height - height,
          x + width,
          size.height,
          topLeft: radius,
          topRight: radius,
        ),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.color != color || old.empty != empty || !_same(old.values, values);

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// A ranked list with a bar showing each row's share of the first.
class _TopList extends StatelessWidget {
  const _TopList(this.title, this.entries, {this.leading, this.empty = ""});

  final String title;
  final List<StatsEntry> entries;
  final Widget Function(StatsEntry entry)? leading;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final top = entries.isEmpty ? 1 : max(1, entries.first.listens);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(title, style: context.text.titleMedium),
        if (entries.isEmpty)
          Text(
            empty.isNotEmpty ? empty : "Nothing yet.",
            style: context.text.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        for (final (rank, entry) in entries.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              spacing: 10,
              children: [
                SizedBox(
                  width: 20,
                  child: Text(
                    "${rank + 1}",
                    textAlign: TextAlign.end,
                    style: context.text.labelMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (leading != null) leading!(entry),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 3,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium,
                      ),
                      if (entry.detail.isNotEmpty)
                        Text(
                          entry.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: entry.listens / top,
                          minHeight: 3,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  plural(entry.listens, "play"),
                  style: context.text.labelMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
