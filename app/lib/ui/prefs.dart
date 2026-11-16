import 'package:shared_preferences/shared_preferences.dart';

import '../core/image_pipeline.dart';
import '../core/print_job.dart';

/// Persisted user choices (per device, via shared_preferences).
class Prefs {
  Prefs._(this._raw);
  final SharedPreferencesWithCache _raw;

  /// Integration tests run with `--dart-define=THERMAL_PHOTO_TEST=true` and get
  /// their own key namespace, so they never read or clobber real settings.
  static const testMode = bool.fromEnvironment('THERMAL_PHOTO_TEST');
  static const _prefix = testMode ? 'test.' : '';

  late final _p = _Prefixed(_raw, _prefix);

  static Future<Prefs> load() async =>
      Prefs._(await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions()));

  /// Remove every key of the current namespace (used by tests).
  Future<void> clear() async {
    for (final k in _raw.keys.where((k) => k.startsWith(_prefix)).toList()) {
      if (_prefix.isNotEmpty || !k.startsWith('test.')) await _raw.remove(k);
    }
  }

  String? get profileId => _p.getString('profile');
  set profileId(String? v) => _set('profile', v);

  String? get endpointId => _p.getString('endpoint');
  set endpointId(String? v) => _set('endpoint', v);

  String get host => _p.getString('host') ?? '';
  set host(String v) => _p.setString('host', v);

  PrintSettings get settings => PrintSettings(
        dither: DitherMode.values.asNameMap()[_p.getString('dither')] ?? DitherMode.atkinson,
        brightness: _p.getDouble('brightness') ?? 0,
        contrast: _p.getDouble('contrast') ?? 1,
        gamma: _p.getDouble('gamma') ?? 1.3,
        threshold: _p.getInt('threshold') ?? 128,
        invert: _p.getBool('invert') ?? false,
        rotate90: _p.getBool('rotate90') ?? false,
      );

  set settings(PrintSettings s) {
    _p.setString('dither', s.dither.name);
    _p.setDouble('brightness', s.brightness);
    _p.setDouble('contrast', s.contrast);
    _p.setDouble('gamma', s.gamma);
    _p.setInt('threshold', s.threshold);
    _p.setBool('invert', s.invert);
    _p.setBool('rotate90', s.rotate90);
  }

  JobOptions get job => JobOptions(
        darkness: _p.getDouble('darkness'),
        feedLines: _p.getInt('feedLines') ?? 4,
        cut: _p.getBool('cut') ?? true,
        copies: 1,
      );

  set job(JobOptions j) {
    _set('darkness', j.darkness);
    _p.setInt('feedLines', j.feedLines);
    _p.setBool('cut', j.cut);
  }

  /// Receipt being edited (JSON), restored on start.
  String? get receiptDraft => _p.getString('receipt.draft');
  set receiptDraft(String? v) => _set('receipt.draft', v);

  /// Saved receipts (JSON array, see receipt/editor.dart).
  String? get savedReceipts => _p.getString('receipt.saved');
  set savedReceipts(String? v) => _set('receipt.saved', v);

  /// Desktop: serve the web bridge on 127.0.0.1 (bridge_server.dart).
  bool get bridge => _p.getBool('bridge') ?? !testMode;
  set bridge(bool v) => _p.setBool('bridge', v);

  void _set(String k, Object? v) {
    switch (v) {
      case null:
        _p.remove(k);
      case String s:
        _p.setString(k, s);
      case double d:
        _p.setDouble(k, d);
    }
  }
}

class _Prefixed {
  _Prefixed(this._p, this._x);
  final SharedPreferencesWithCache _p;
  final String _x;

  String? getString(String k) => _p.getString('$_x$k');
  double? getDouble(String k) => _p.getDouble('$_x$k');
  int? getInt(String k) => _p.getInt('$_x$k');
  bool? getBool(String k) => _p.getBool('$_x$k');
  Future<void> setString(String k, String v) => _p.setString('$_x$k', v);
  Future<void> setDouble(String k, double v) => _p.setDouble('$_x$k', v);
  Future<void> setInt(String k, int v) => _p.setInt('$_x$k', v);
  Future<void> setBool(String k, bool v) => _p.setBool('$_x$k', v);
  Future<void> remove(String k) => _p.remove('$_x$k');
}
