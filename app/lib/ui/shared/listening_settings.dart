import "package:flutter/material.dart";

import "../../application/audio_adjustments.dart";
import "../../application/scrobbling.dart";
import "../../core/errors.dart" show failureMessage;
import "../app_state.dart";
import "format.dart" show plural;
import "settings_sections.dart" show SettingsSection;

Widget _note(BuildContext context, String text) =>
    Text(text, style: TextStyle(fontSize: 12, color: context.colorsVariant));

extension on BuildContext {
  Color get colorsVariant => Theme.of(this).colorScheme.onSurfaceVariant;
}

String _db(double value) =>
    "${value > 0
        ? "+"
        : value < 0
        ? "−"
        : ""}${value.abs().toStringAsFixed(value.abs() % 1 == 0 ? 0 : 1)} dB";

String _hz(double frequency) => frequency >= 1000
    ? "${(frequency / 1000).toStringAsFixed(0)} kHz"
    : "${frequency.toStringAsFixed(0)} Hz";

// ---------------------------------------------------------------------------
// Sound: the equalizer and per-track loudness. `soundSettings` (in
// settings_sections.dart) lays them out beside loudness normalization.
// ---------------------------------------------------------------------------

/// The equalizer's switch, presets, and bands. A band is saved when the
/// drag ends, not on every step of it.
class EqualizerControls extends StatefulWidget {
  const EqualizerControls(this.adjustments, {super.key});

  final AudioAdjustments adjustments;

  @override
  State<EqualizerControls> createState() => _EqualizerControlsState();
}

class _EqualizerControlsState extends State<EqualizerControls> {
  /// The band being dragged and where it is.
  (int, double)? _dragging;

  AudioAdjustments get _adjustments => widget.adjustments;

  void _apply(void Function() change) {
    try {
      change();
    } on Object catch (error) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(failureMessage(error))));
    }
    setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    final state = _adjustments.equalizer;
    final supported = _adjustments.equalizerSupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        SwitchListTile(
          value: state.enabled,
          onChanged: supported
              ? (value) => _apply(() => _adjustments.setEqualizerEnabled(value))
              : null,
          title: const Text("Use equalizer"),
          subtitle: Text(
            supported
                ? "Raise or lower bass, mids, and treble in everything you "
                      "play. Boosts lower the overall level by as much, so "
                      "nothing clips."
                : "This device's audio engine has no equalizer. The "
                      "loudness settings above still work.",
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (supported) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in equalizerPresets.keys)
                ChoiceChip(
                  label: Text(name),
                  selected: state.enabled && state.preset == name,
                  onSelected: (_) =>
                      _apply(() => _adjustments.applyPreset(name)),
                ),
            ],
          ),
          // A preset turns the equalizer on; the bands show once it is.
          if (state.enabled)
            for (final (index, frequency) in equalizerFrequencies.indexed)
              _band(index, frequency, state),
        ],
      ],
    );
  }

  Widget _band(int index, double frequency, EqualizerState state) {
    final dragging = _dragging;
    final value = dragging != null && dragging.$1 == index
        ? dragging.$2
        : state.gains[index];
    return Row(
      children: [
        SizedBox(width: 64, child: Text(_hz(frequency))),
        Expanded(
          child: Slider(
            value: value,
            min: -maxEqualizerGainDb,
            max: maxEqualizerGainDb,
            divisions: (maxEqualizerGainDb * 4).round(),
            label: _db(value),
            semanticFormatterCallback: (value) =>
                "${_hz(frequency)}: ${_db(value)}",
            onChanged: state.enabled
                ? (value) => setState(() => _dragging = (index, value))
                : null,
            onChangeEnd: (value) =>
                _apply(() => _adjustments.setBand(index, value)),
          ),
        ),
        SizedBox(width: 60, child: Text(_db(value), textAlign: TextAlign.end)),
      ],
    );
  }
}

/// Asks how much louder or quieter a track and its album should play than
/// normalization (or the track as made, with it off) would have them.
Future<void> showVolumeAdjustment(
  BuildContext context,
  MelodyApp app,
  String trackId,
) => showDialog<void>(
  context: context,
  builder: (context) => _VolumeDialog(app, trackId),
);

class _VolumeDialog extends StatefulWidget {
  const _VolumeDialog(this.app, this.trackId);

  final MelodyApp app;
  final String trackId;

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
  late final AudioAdjustments _adjustments = widget.app.adjustments;
  late final String _album = widget.app.services.library
      .details(widget.trackId)
      .album
      .trim();
  late double _track = _adjustments.trackGainDb(widget.trackId);
  late double _albumGain = _album.isEmpty
      ? 0
      : _adjustments.albumGainDb(_album);

  Widget _slider(String label, double value, ValueChanged<double> changed) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text(_db(value)),
            ],
          ),
          Slider(
            value: value,
            min: -12,
            max: 12,
            divisions: 48,
            label: _db(value),
            semanticFormatterCallback: (value) => "$label: ${_db(value)}",
            onChanged: changed,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final title = widget.app.services.manager
        .getTrack(widget.trackId)
        .displayTitle;
    return AlertDialog(
      // Narrow phones keep Reset, Cancel, and Save on one row.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text("Adjust loudness"),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            _slider(
              "This track: $title",
              _track,
              (value) => setState(() => _track = value),
            ),
            if (_album.isNotEmpty)
              _slider(
                "Album: $_album",
                _albumGain,
                (value) => setState(() => _albumGain = value),
              ),
            _note(
              context,
              "Moves this track from where normalization puts it, or from "
              "how it was made when normalization is off. A raise stops "
              "before the track would clip.",
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _track = 0;
            _albumGain = 0;
          }),
          child: const Text("Reset"),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: () {
            final app = widget.app;
            Navigator.of(context).pop();
            app.run(() {
              _adjustments.setTrackGain(widget.trackId, _track);
              if (_album.isNotEmpty) {
                _adjustments.setAlbumGain(_album, _albumGain);
              }
            });
          },
          child: const Text("Save"),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Scrobbling
// ---------------------------------------------------------------------------

SettingsSection scrobblingSettings(BuildContext context, MelodyApp app) =>
    SettingsSection(
      icon: Icons.podcasts_rounded,
      title: "Scrobbling",
      subtitle: "Send what you play to ListenBrainz.",
      mobileTitle: "Scrobbling",
      mobileSubtitle: switch (app.scrobbler.state) {
        ScrobbleState.disconnected => "Off",
        ScrobbleState.connected => "ListenBrainz: ${app.scrobbler.username}",
        ScrobbleState.needsSignIn => "Connect ListenBrainz again",
      },
      body: ScrobblingControls(app.scrobbler),
    );

class ScrobblingControls extends StatefulWidget {
  const ScrobblingControls(this.scrobbler, {super.key});

  final Scrobbler scrobbler;

  @override
  State<ScrobblingControls> createState() => _ScrobblingControlsState();
}

class _ScrobblingControlsState extends State<ScrobblingControls> {
  final _token = TextEditingController();
  bool _connecting = false;
  String? _error;

  Scrobbler get _scrobbler => widget.scrobbler;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await _scrobbler.connect(_token.text);
      _token.clear();
    } on Object catch (error) {
      _error = error is FormatException ? error.message : failureMessage(error);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _scrobbler,
    builder: (context, _) {
      final state = _scrobbler.state;
      final pending = _scrobbler.pending;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (state == ScrobbleState.connected) ...[
            Text(
              "Connected as ${_scrobbler.username}.",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            _note(
              context,
              pending == 0
                  ? "Every listen has been sent."
                  : "${plural(pending, "listen")} waiting to be sent"
                        "${_scrobbler.waiting ? "; Melody will try again soon" : ""}.",
            ),
            if (_scrobbler.lastError case final error?)
              _note(context, "Last attempt: $error"),
          ] else ...[
            if (state == ScrobbleState.needsSignIn)
              Text(
                "ListenBrainz no longer accepts the token for "
                "${_scrobbler.username}. Paste a new one; "
                "${plural(pending, "listen")} will be sent once it works.",
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else
              _note(
                context,
                "Paste the user token from your ListenBrainz settings "
                "(listenbrainz.org/settings). Songs count once you've heard "
                "half of them or four minutes, and wait here while you're "
                "offline.",
              ),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_connecting,
              decoration: InputDecoration(
                labelText: "ListenBrainz user token",
                errorText: _error,
              ),
              onSubmitted: (_) => _connect(),
            ),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (state != ScrobbleState.connected)
                FilledButton(
                  onPressed: _connecting ? null : _connect,
                  child: Text(_connecting ? "Checking…" : "Connect"),
                ),
              if (state != ScrobbleState.disconnected)
                OutlinedButton(
                  onPressed: () => _scrobbler.disconnect(),
                  child: const Text("Disconnect"),
                ),
              if (state == ScrobbleState.connected && pending > 0)
                TextButton(
                  onPressed: _scrobbler.sendPending,
                  child: const Text("Send now"),
                ),
            ],
          ),
        ],
      );
    },
  );
}
