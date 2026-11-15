import 'package:shared_preferences/shared_preferences.dart';

import '../core/image_pipeline.dart';
import '../core/print_job.dart';

/// Persisted user choices (per device, via shared_preferences).
class Prefs {
  Prefs._(this._p);
  final SharedPreferencesWithCache _p;

  static Future<Prefs> load() async =>
      Prefs._(await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions()));

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
