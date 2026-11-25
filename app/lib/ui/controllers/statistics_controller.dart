import "dart:async";

import "package:flutter/foundation.dart";

import "../../application/listening.dart";
import "../../core/errors.dart" show failureMessage;
import "../app_state.dart";

/// The statistics view's state: which period it shows, and what it read.
///
/// Statistics are read in a background isolate (`loadListeningStats`), only
/// while a view shows them; a new listen marks them stale and reloads them
/// if one does.
class StatisticsController extends ChangeNotifier {
  StatisticsController(this.app, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final MelodyApp app;
  final DateTime Function() _clock;

  StatsPeriod period = StatsPeriod.week;

  /// How many periods back from the current one; 0 is this week or month.
  int offset = 0;

  ListeningStats? stats;
  bool loading = false;
  String? error;
  bool _stale = true;
  int _request = 0;
  bool _disposed = false;

  StatsRange get range => StatsRange.of(period, _clock(), offset: offset);

  /// Loads the statistics if they are not current. Views call it when
  /// they open.
  void show() {
    if (_stale || stats?.range != range) unawaited(load());
  }

  void setPeriod(StatsPeriod value) {
    if (value == period) return;
    period = value;
    offset = 0;
    unawaited(load());
  }

  /// Moves [by] periods back (positive) or forward; never past the current.
  void move(int by) {
    final next = (offset + by).clamp(0, 1 << 20).toInt();
    if (next == offset) return;
    offset = next;
    unawaited(load());
  }

  /// A listen just counted.
  void listened() {
    _stale = true;
    if (hasListeners) unawaited(load());
  }

  Future<void> load() async {
    final request = ++_request;
    final range = this.range;
    loading = true;
    error = null;
    _notify();
    try {
      final result = await loadListeningStats(
        app.services.store.path,
        range,
        now: _clock(),
      );
      if (request != _request || _disposed) return;
      stats = result;
      _stale = false;
    } on Object catch (failure) {
      if (request != _request || _disposed) return;
      error = failureMessage(failure);
    } finally {
      if (request == _request && !_disposed) {
        loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
