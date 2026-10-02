import "dart:async";
import "dart:io";
import "dart:math";

import "package:flutter/material.dart";
import "package:melody_audio/melody_audio.dart";

import "app/app_state.dart";
import "app/services.dart";
import "ui/desktop/shell.dart";
import "ui/mobile/shell.dart";
import "ui/shared/quotes.dart";
import "ui/shared/theme.dart";

const _minimumLoading = Duration(seconds: 3);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ensureMelodyAudioInitialized();
  runApp(const MelodyRoot());
}

/// Shows the loading view while services load, then the app shell.
class MelodyRoot extends StatefulWidget {
  const MelodyRoot({super.key});

  @override
  State<MelodyRoot> createState() => _MelodyRootState();
}

class _MelodyRootState extends State<MelodyRoot> with WidgetsBindingObserver {
  MelodyApp? _app;
  Object? _failure;
  bool _revealed = false;
  (String, String) _appearance = ("system", "violet");
  final GlobalKey<ScaffoldMessengerState> _messenger = GlobalKey();
  StreamSubscription<AppMessage>? _messages;

  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    final started = DateTime.now();
    try {
      final services = await AppServices.load(
        onStoreReady: (store) {
          final settings = store.settings;
          if (mounted) setState(() => _appearance = (settings.theme, settings.accentColor));
        },
      );
      if (!services.store.settings.skipLoadingDelay) {
        final remaining = _minimumLoading - DateTime.now().difference(started);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      final app = MelodyApp(services, mobile: _mobile);
      app.appearance.addListener(() => setState(() => _appearance = app.appearance.value));
      _messages = app.messages.listen(_show);
      if (!mounted) return;
      setState(() {
        _app = app;
        _appearance = app.appearance.value;
      });
      await app.reattachNativeState();
      // Let the first frame mount transparent before fading the app in.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (mounted) setState(() => _revealed = true);
    } catch (error, stack) {
      debugPrint("Melody failed to start: $error\n$stack");
      if (mounted) setState(() => _failure = error);
    }
  }

  void _show(AppMessage message) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    final scheme = Theme.of(messenger.context).colorScheme;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.text, style: message.error ? TextStyle(color: scheme.onErrorContainer) : null),
          backgroundColor: message.error ? scheme.errorContainer : null,
          showCloseIcon: true,
        ),
      );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _app?.resumed();
    if (state == AppLifecycleState.detached) _app?.close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_messages?.cancel());
    _app?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (theme, accent) = _appearance;
    final app = _app;
    return MaterialApp(
      title: "Melody",
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      theme: buildTheme(accent, Brightness.light),
      darkTheme: buildTheme(accent, Brightness.dark),
      themeMode: themeModeFor(theme),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeInOut,
        child: _failure != null
            ? const _StartupError()
            : app == null
            ? const LoadingView()
            : AnimatedOpacity(
                key: const ValueKey("shell"),
                opacity: _revealed ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                child: _mobile ? MobileShell(app) : DesktopShell(app),
              ),
      ),
    );
  }
}

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
    milliseconds: (min(5.5, max(1.8, 0.8 + 0.28 * quote.split(" ").length)) * 1000).round(),
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
                        color: scheme.primaryContainer.withValues(alpha: 0.5),
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
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600, color: scheme.onSurface),
            ),
            const SizedBox(height: 4),
            Text("Getting your library ready", style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
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

class _StartupError extends StatelessWidget {
  const _StartupError();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 14,
        children: [
          Icon(Icons.error_outline_rounded, size: 52, color: Theme.of(context).colorScheme.error),
          const Text("Melody couldn’t start", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const Text(
            "Restart Melody and check that the configured music folder and app data "
            "location are available.",
          ),
        ],
      ),
    ),
  );
}
