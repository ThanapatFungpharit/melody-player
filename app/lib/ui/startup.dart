import "dart:async";
import "dart:math";
import "dart:ui" show lerpDouble;

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

import "shared/quotes.dart";
import "shared/widgets.dart";

/// The animated mark, startup stage, and rotating quotes shown while loading.
class LoadingView extends StatefulWidget {
  const LoadingView({
    super.key,
    this.stage,
    this.finishing = false,
    this.onReveal,
    this.onFinished,
  });

  /// What startup is doing now; a generic caption when absent.
  final ValueListenable<String>? stage;

  /// Plays the exit: the bars settle, the progress bar fills, and the view
  /// fades away while the mark zooms toward the viewer.
  final bool finishing;

  /// Called once the exit starts fading, so what lies beneath can come in.
  final VoidCallback? onReveal;

  /// Called when the exit has finished and the view is fully transparent.
  final VoidCallback? onFinished;

  @override
  State<LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<LoadingView>
    with TickerProviderStateMixin {
  final Random _random = Random();
  late String _quote = _next(null);
  Timer? _timer;

  /// Drives the equalizer bars, the ripples, and the breathing glow.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  /// Fades and lifts everything in once.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  /// The exit, from settling the bars to fully transparent.
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );
  bool _revealed = false;

  // Phases of [_exit]: the bars settle and the bar fills, then all fades.
  static const _fadeStart = 0.4;
  late final Animation<double> _settle = CurvedAnimation(
    parent: _exit,
    curve: const Interval(0, 0.35, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _fill = CurvedAnimation(
    parent: _exit,
    curve: const Interval(0, _fadeStart, curve: Curves.easeInOut),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _exit,
    curve: const Interval(_fadeStart, 1, curve: Curves.easeInCubic),
  );

  String _next(String? previous) {
    final choices = startupQuotes.where((quote) => quote != previous).toList();
    return choices[_random.nextInt(choices.length)];
  }

  /// Longer quotes get more reading time.
  Duration _displayTime(String quote) => Duration(
    milliseconds:
        (min(5.5, max(1.8, 0.8 + 0.28 * quote.split(" ").length)) * 1000)
            .round(),
  );

  void _schedule() {
    _timer = Timer(_displayTime(_quote), () {
      if (!mounted) return;
      setState(() => _quote = _next(_quote));
      _schedule();
    });
  }

  @override
  void initState() {
    super.initState();
    _schedule();
    _exit
      ..addListener(() {
        if (!_revealed && _exit.value >= _fadeStart) {
          _revealed = true;
          widget.onReveal?.call();
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onFinished?.call();
      });
    if (widget.finishing) _finish();
  }

  @override
  void didUpdateWidget(LoadingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.finishing && !oldWidget.finishing) _finish();
  }

  void _finish() {
    _timer?.cancel();
    _exit.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion keeps the mark still and skips the entrance.
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _entrance.value = 1;
    } else {
      if (!_pulse.isAnimating) _pulse.repeat();
      if (_entrance.isDismissed) _entrance.forward();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    _entrance.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final tile = (min(size.width, size.height) * 0.26).clamp(96.0, 150.0);
    final still = MediaQuery.disableAnimationsOf(context);
    final reveal = CurvedAnimation(
      parent: _entrance,
      curve: Curves.easeOutCubic,
    );
    // Taps go to the app beneath as soon as the exit starts.
    return IgnorePointer(
      ignoring: widget.finishing,
      child: FadeTransition(
        opacity: ReverseAnimation(_fade),
        child: _page(scheme, tile, still, reveal),
      ),
    );
  }

  Widget _page(
    ColorScheme scheme,
    double tile,
    bool still,
    Animation<double> reveal,
  ) {
    return Scaffold(
      backgroundColor: scheme.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.25),
            radius: 1.1,
            colors: [
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.08),
                scheme.surface,
              ),
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: reveal,
            child: Column(
              children: [
                const Spacer(),
                SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(reveal),
                  child: Column(
                    children: [
                      Semantics(
                        label: "Loading Melody",
                        child: ScaleTransition(
                          // Zooms toward the viewer as the view fades.
                          scale: Tween(
                            begin: 1.0,
                            end: still ? 1.0 : 1.35,
                          ).animate(_fade),
                          child: _PulsingMark(
                            size: tile,
                            pulse: _pulse,
                            settle: _settle,
                          ),
                        ),
                      ),
                      Text(
                        "Melody",
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: 168,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(100),
                          child: _ProgressBar(fill: _fill, scheme: scheme),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _StageCaption(stage: widget.stage),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 450),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 0.25),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: Text(
                            _quote,
                            key: ValueKey(_quote),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The brand tile with live equalizer bars, a breathing glow, and ripples.
class _PulsingMark extends StatelessWidget {
  const _PulsingMark({
    required this.size,
    required this.pulse,
    required this.settle,
  });

  final double size;
  final Animation<double> pulse;

  /// From 0 (playing) to 1: the bars come to rest in the logo's shape and
  /// the ripples die away.
  final Animation<double> settle;

  /// One unit of the logo's `graphic_eq_rounded` glyph (a 24-unit grid), as
  /// a fraction of the tile. The glyph's bars are 2 units wide, 2 apart.
  static const _unit = brandMarkGlyph / 24;

  /// Each bar's resting height in glyph units, as in the logo, and its wave
  /// phase.
  static const _bars = [
    (4.0, 0.0),
    (12.0, 0.35),
    (20.0, 0.7),
    (12.0, 0.15),
    (4.0, 0.5),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final extent = size * 1.9;
    return SizedBox(
      width: extent,
      height: extent,
      child: AnimatedBuilder(
        animation: Listenable.merge([pulse, settle]),
        builder: (context, _) {
          final t = pulse.value;
          final calm = settle.value;
          final breath = (0.5 - 0.5 * cos(2 * pi * t)) * (1 - calm);
          return Stack(
            alignment: Alignment.center,
            children: [
              // Two ripples spreading from the tile, half a cycle apart.
              for (final offset in const [0.0, 0.5])
                _ripple(scheme, (t + offset) % 1, 1 - calm),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * brandMarkRadius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: brandMarkColors(scheme),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(
                        alpha: 0.28 + 0.17 * breath,
                      ),
                      blurRadius: size * (0.28 + 0.14 * breath),
                      spreadRadius: -size * 0.06,
                      offset: Offset(0, size * 0.1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: size * _unit * 2,
                  children: [
                    for (final (rest, phase) in _bars)
                      Container(
                        width: size * _unit * 2,
                        height:
                            size *
                            _unit *
                            lerpDouble(_height(rest, phase, t), rest, calm)!,
                        decoration: BoxDecoration(
                          color: scheme.onPrimary,
                          borderRadius: BorderRadius.circular(100),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Two blended waves, so the bars move like music rather than in lockstep.
  /// Whole-number frequencies keep the loop seamless. In glyph units, kept
  /// within the glyph's 24-unit box.
  static double _height(double rest, double phase, double t) {
    final a = sin(2 * pi * (2 * t + phase));
    final b = sin(2 * pi * (3 * t + phase * 1.7));
    return (rest + 5 * a + 2.5 * b).clamp(2.0, 22.0);
  }

  Widget _ripple(ColorScheme scheme, double progress, double strength) {
    final extent = size * (1 + 0.85 * Curves.easeOut.transform(progress));
    return Container(
      width: extent,
      height: extent,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(extent * brandMarkRadius),
        border: Border.all(
          color: scheme.primary.withValues(
            alpha: 0.35 * (1 - progress) * strength,
          ),
          width: 2,
        ),
      ),
    );
  }
}

/// Indeterminate while loading; fills to the end as the exit starts.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fill, required this.scheme});

  final Animation<double> fill;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final track = scheme.primary.withValues(alpha: 0.14);
    return AnimatedBuilder(
      animation: fill,
      builder: (context, _) {
        final value = fill.value;
        return Stack(
          children: [
            // Fades out quickly so the filling bar takes over smoothly.
            Opacity(
              opacity: (1 - value * 3).clamp(0.0, 1.0),
              child: LinearProgressIndicator(
                minHeight: 4,
                color: scheme.primary,
                backgroundColor: track,
              ),
            ),
            if (value > 0)
              LinearProgressIndicator(
                minHeight: 4,
                value: lerpDouble(0.35, 1, value),
                color: scheme.primary,
                backgroundColor: track,
              ),
          ],
        );
      },
    );
  }
}

/// The current startup stage, cross-fading as it changes.
class _StageCaption extends StatelessWidget {
  const _StageCaption({required this.stage});

  final ValueListenable<String>? stage;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    Widget caption(String text) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Text(text, key: ValueKey(text), style: style),
    );
    final stage = this.stage;
    if (stage == null) return caption("Getting your library ready");
    return Semantics(
      liveRegion: true,
      child: ValueListenableBuilder(
        valueListenable: stage,
        builder: (context, text, _) => caption(text),
      ),
    );
  }
}

class StartupError extends StatelessWidget {
  const StartupError({super.key, this.error});

  /// Shown under the advice, so a report can quote it.
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = this.error;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 14,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 52,
                    color: scheme.error,
                  ),
                  const Text(
                    "Melody couldn’t start",
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    "Restart Melody and check that the configured music folder "
                    "and app data location are available.",
                  ),
                  if (error != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectableText(
                        "$error",
                        style: TextStyle(
                          fontFamily: "Consolas",
                          fontFamilyFallback: const ["Menlo", "monospace"],
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
