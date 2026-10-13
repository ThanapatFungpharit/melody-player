import "dart:async";
import "dart:math";

import "package:flutter/material.dart";
import "package:flutter/rendering.dart" show ScrollDirection;

import "../app_state.dart";
import "../../application/lyrics.dart";
import "../../core/errors.dart";
import "playback_widgets.dart";
import "widgets.dart";

/// Lyrics for the current track. Saved lyrics show without a connection;
/// timed lyrics follow playback, and tapping a line plays from it. Scrolling
/// by hand stops following until the listener asks to go back.
class LyricsView extends StatefulWidget {
  const LyricsView(this.app, {super.key});

  final MelodyApp app;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  static const _margin = 12.0;
  static const _activeScale = 1.04;

  final GlobalKey _activeLine = GlobalKey();
  LyricsTrack? _track;
  Lyrics? _lyrics;
  bool _loading = false;
  String _message = "";
  int _active = -1;
  int _request = 0;

  /// Whether the view keeps the active line in sight.
  bool _following = true;
  late final PositionTicker _position;

  MelodyApp get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.playbackState.addListener(_trackChanged);
    _position = PositionTicker(
      app,
      _progressChanged,
      nextChange: _nextLineStart,
    );
    _track = _currentTrack();
    _reset();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    app.playbackState.removeListener(_trackChanged);
    _position.dispose();
    super.dispose();
  }

  /// The current library track; null for streams and nothing.
  LyricsTrack? _currentTrack() {
    final id = app.playback.currentTrackId;
    if (app.playback.externalTitle.isNotEmpty || id == null) return null;
    return app.lyricsTrack(id);
  }

  void _trackChanged() {
    final track = _currentTrack();
    if (track == _track) return;
    _track = track;
    _reload();
  }

  void _reload({bool refresh = false}) {
    setState(_reset);
    unawaited(_fetch(refresh: refresh));
  }

  void _reset() {
    _request++;
    _lyrics = null;
    _active = -1;
    _following = true;
    _loading = _track != null;
    _message = _track == null ? "Play a track to see its lyrics." : "";
  }

  Future<void> _fetch({bool refresh = false}) async {
    final track = _track;
    final request = _request;
    if (track == null) return;
    Lyrics? lyrics;
    var message = "";
    try {
      lyrics = await app.services.lyrics.forTrack(track, refresh: refresh);
      if (lyrics == null) {
        message = app.services.lyrics.supports(track.source)
            ? "No lyrics are available for this track."
            : "This track has no lyrics. To add some, put a .lrc file with "
                  "the same name beside its audio file, then check again.";
      }
    } on LyricsUnavailable catch (error) {
      message = error.message;
    } on ProviderError {
      message = "Connect to the internet to load lyrics for this track.";
    } catch (error) {
      message = "Lyrics could not be loaded: $error";
    }
    if (!mounted || request != _request) return;
    setState(() {
      _lyrics = lyrics;
      _message = message;
      _loading = false;
      _active = lyrics?.lineAt(app.estimatedPositionMs()) ?? -1;
    });
    _position.refresh();
    _scrollToActive();
  }

  void _progressChanged(int positionMs) {
    final lyrics = _lyrics;
    if (lyrics == null || !lyrics.synced) return;
    final active = lyrics.lineAt(positionMs);
    if (active == _active) return;
    setState(() => _active = active);
    _scrollToActive();
  }

  /// When the line after [positionMs]'s starts; plain lyrics never change.
  int? _nextLineStart(int positionMs) {
    final lyrics = _lyrics;
    if (lyrics == null || !lyrics.synced) return null;
    final next = lyrics.lineAt(positionMs) + 1;
    return next < lyrics.lines.length ? lyrics.lines[next].startMs : null;
  }

  /// Stops following when the listener drags or wheels the lyrics; the
  /// view's own scrolling to the active line does not count.
  bool _userScrolled(UserScrollNotification notification) {
    final lyrics = _lyrics;
    if (_following &&
        lyrics != null &&
        lyrics.synced &&
        notification.direction != ScrollDirection.idle) {
      setState(() => _following = false);
    }
    return false;
  }

  void _follow() {
    setState(() => _following = true);
    _scrollToActive();
  }

  void _scrollToActive() {
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _activeLine.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.4,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lyrics = _lyrics;
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (lyrics == null) {
      body = Center(
        child: SingleChildScrollView(
          child: EmptyState(Icons.lyrics_outlined, _message),
        ),
      );
    } else {
      // Lines wrap at a width the enlarged active line still fits in, so
      // scaling it up never pushes text past the edge.
      body = LayoutBuilder(
        builder: (context, constraints) {
          final width = max(0.0, constraints.maxWidth - _margin * 2);
          final scroll = SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              vertical: 24,
              horizontal: _margin,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: lyrics.synced ? width / _activeScale : width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, line) in lyrics.lines.indexed)
                      _line(context, lyrics, index, line),
                  ],
                ),
              ),
            ),
          );
          return NotificationListener<UserScrollNotification>(
            onNotification: _userScrolled,
            child: Stack(
              children: [
                Positioned.fill(child: scroll),
                if (!_following)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: Center(
                      child: FilledButton.tonalIcon(
                        onPressed: _follow,
                        icon: const Icon(Icons.my_location_rounded, size: 18),
                        label: const Text("Back to current line"),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: body),
        Row(
          children: [
            Expanded(
              child: Text(
                lyrics?.source ?? "",
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              onPressed: _loading || _track == null
                  ? null
                  : () => _reload(refresh: true),
              tooltip: "Check for lyrics again",
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  Widget _line(BuildContext context, Lyrics lyrics, int index, LyricLine line) {
    final scheme = Theme.of(context).colorScheme;
    final synced = lyrics.synced;
    final active = synced && index == _active;
    // A blank timed line marks an instrumental break.
    final blank = line.text.trim().isEmpty;
    final text = Text(
      blank ? (synced ? "♪" : " ") : line.text,
      style: TextStyle(
        fontSize: synced ? 22 : 16,
        height: 1.3,
        letterSpacing: synced ? -0.3 : 0,
        fontWeight: synced ? FontWeight.w800 : FontWeight.w500,
        color: !synced || active
            ? scheme.onSurface
            : scheme.onSurface.withValues(alpha: index < _active ? 0.3 : 0.45),
      ),
    );
    if (!synced) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: text,
      );
    }
    return InkWell(
      key: active ? _activeLine : null,
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        app.playback.playFrom(line.startMs);
        _follow();
      },
      child: AnimatedScale(
        scale: active ? _activeScale : 1,
        alignment: Alignment.centerLeft,
        duration: const Duration(milliseconds: 200),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: text,
        ),
      ),
    );
  }
}
