import "dart:async";
import "dart:io";
import "dart:ui" show AppExitResponse;

import "package:flutter/material.dart";
import "package:melody_audio/melody_audio.dart";

import "services.dart";
import "ui/app_state.dart";
import "ui/desktop/shell.dart";
import "ui/mobile/shell.dart";
import "ui/shared/safe_area.dart";
import "ui/shared/theme.dart";
import "ui/startup.dart";

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
  // The app mounts beneath the loading view, which then plays its exit
  // ([_finishing]), lets the app grow in ([_revealed]), and goes ([_loaded]).
  bool _finishing = false;
  bool _revealed = false;
  bool _loaded = false;
  final ValueNotifier<String> _stage = ValueNotifier("Warming up");
  (String, String) _appearance = ("system", "violet");
  final GlobalKey<ScaffoldMessengerState> _messenger = GlobalKey();
  StreamSubscription<AppMessage>? _messages;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    // Closing a desktop window persists the final position and stops
    // background downloads before the process exits.
    onExitRequested: () async {
      _app?.close();
      return AppExitResponse.exit;
    },
  );

  /// Phones get the mobile shell. MELODY_LAYOUT (`mobile` or `desktop`)
  /// overrides that, so either UI can be developed in a desktop window.
  final bool _mobile = switch (Platform.environment["MELODY_LAYOUT"]) {
    "mobile" => true,
    "desktop" => false,
    _ => Platform.isAndroid,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle;
    unawaited(_start());
  }

  Future<void> _start() async {
    final started = DateTime.now();
    try {
      final services = await AppServices.load(
        onStoreReady: (store) {
          final settings = store.settings;
          if (mounted) {
            setState(
              () => _appearance = (settings.theme, settings.accentColor),
            );
          }
        },
        onStage: (stage) => _stage.value = stage,
      );
      _stage.value = "Almost ready";
      if (!services.store.settings.skipLoadingDelay) {
        final remaining = _minimumLoading - DateTime.now().difference(started);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      if (!mounted) {
        // Disposed while loading: nothing would ever close an app built now,
        // so stop the downloads that MelodyApp.close() would have stopped.
        services.downloads.shutdown();
        return;
      }
      final app = MelodyApp(services, mobile: _mobile);
      app.appearance.addListener(() {
        if (mounted) setState(() => _appearance = app.appearance.value);
      });
      _messages = app.messages.listen(_show);
      setState(() {
        _app = app;
        _appearance = app.appearance.value;
      });
      app.reattachNativeState();
      // Let the shell's first, heaviest frame pass hidden, so it doesn't
      // stutter the exit animation.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      _stage.value = "Ready";
      if (mounted) setState(() => _finishing = true);
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
          content: Text(
            message.text,
            style: message.error
                ? TextStyle(color: scheme.onErrorContainer)
                : null,
          ),
          backgroundColor: message.error ? scheme.errorContainer : null,
          showCloseIcon: true,
          action: switch (message.action) {
            (final label, final onPressed) => SnackBarAction(
              label: label,
              onPressed: onPressed,
              textColor: message.error ? scheme.error : null,
            ),
            null => null,
          },
        ),
      );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _app?.resumed();
    // Android reports detached whenever its activity is destroyed, but
    // MainActivity keeps this engine (and the playing decoder) cached and
    // attaches the next activity to it, which resumes this same app.
    if (state == AppLifecycleState.detached && !Platform.isAndroid) {
      _app?.close();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle.dispose();
    unawaited(_messages?.cancel());
    _app?.close();
    _stage.dispose();
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
      // Wraps the navigator, so routes, sheets, dialogs, and snackbars all
      // stay clear of the system bars.
      builder: (context, child) => SafeAreaGuard(child: child!),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeInOut,
        child: _failure != null
            ? StartupError(error: _failure)
            : Stack(
                key: const ValueKey("startup"),
                fit: StackFit.expand,
                children: [
                  if (app != null)
                    AnimatedScale(
                      key: const ValueKey("shell"),
                      scale: _revealed ? 1 : 0.96,
                      duration: const Duration(milliseconds: 650),
                      curve: Curves.easeOutCubic,
                      child: _mobile ? MobileShell(app) : DesktopShell(app),
                    ),
                  if (!_loaded)
                    LoadingView(
                      key: const ValueKey("loading"),
                      stage: _stage,
                      finishing: _finishing,
                      onReveal: () => setState(() => _revealed = true),
                      onFinished: () => setState(() => _loaded = true),
                    ),
                ],
              ),
      ),
    );
  }
}
