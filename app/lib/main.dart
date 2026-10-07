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
  bool _revealed = false;
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
      );
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
          content: Text(
            message.text,
            style: message.error
                ? TextStyle(color: scheme.onErrorContainer)
                : null,
          ),
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
    _lifecycle.dispose();
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
      // Wraps the navigator, so routes, sheets, dialogs, and snackbars all
      // stay clear of the system bars.
      builder: (context, child) => SafeAreaGuard(child: child!),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeInOut,
        child: _failure != null
            ? const StartupError()
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
