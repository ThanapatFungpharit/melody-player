import "dart:async";
import "dart:math";

import "package:flutter/material.dart";

import "shared/quotes.dart";

/// The animated mark, caption, and rotating quotes shown while loading.
class LoadingView extends StatefulWidget {
  const LoadingView({super.key});

  @override
  State<LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<LoadingView> {
  final Random _random = Random();
  late String _quote = _next(null);
  Timer? _timer;

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
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final shortest = min(size.width, size.height);
    final mark = min(shortest * 0.7, max(140.0, min(280.0, shortest * 0.44)));
    final bar = max(8.0, mark * 0.11);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Semantics(
              label: "Loading Melody",
              child: SizedBox(
                width: mark,
                height: mark,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: mark * 0.84,
                      height: mark * 0.84,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(
                      width: mark,
                      height: mark,
                      child: CircularProgressIndicator(
                        strokeWidth: max(4, mark * 0.025),
                        strokeCap: StrokeCap.round,
                        color: scheme.primary,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: mark * 0.045,
                      children: [
                        for (final ratio in const [0.38, 0.56, 0.48, 0.38])
                          Container(
                            width: bar,
                            height: mark * ratio,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(100),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              "Melody",
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Getting your library ready",
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _quote,
                      key: ValueKey(_quote),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StartupError extends StatelessWidget {
  const StartupError({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 14,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 52,
              color: Theme.of(context).colorScheme.error,
            ),
            const Text(
              "Melody couldn’t start",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const Text(
              "Restart Melody and check that the configured music folder and app data "
              "location are available.",
            ),
          ],
        ),
      ),
    ),
  );
}
