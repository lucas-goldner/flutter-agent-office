// The building's holiday theme. Port of src/server/theme.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// How often 'auto' looks at the calendar again, so October 1st turns the pumpkins on by itself.
const _check = Duration(minutes: 10);

/// The building's holiday theme (Halloween, Christmas, none, or whichever the calendar says), picked
/// in ⚙️ Settings by anyone and kept in .agent-office/theme.json. Everyone sees the same one.
class Themes {
  /// [utcOffset] is the office's clock, in minutes east of UTC (the sky's), for what day it is there.
  Themes(String dataDir, this._utcOffset, this._onState, {int Function()? now})
    : _path = p.join(dataDir, 'theme.json'),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _restore();
    _told = jsonEncode(state().toJson());
  }

  final String _path;
  final int Function() _utcOffset;
  final void Function(ThemeState state) _onState;
  final int Function() _now;
  ({ThemePick pick, String by, int at})? _saved;
  Timer? _timer;
  String _told = '';

  void start() => _timer = Timer.periodic(_check, (_) => emit());

  void stop() => _timer?.cancel();

  ThemeState state() {
    final pick = _saved?.pick ?? ThemePick.auto;
    return ThemeState(pick: pick, active: activeTheme(pick, _now(), _utcOffset()), by: _saved?.by, at: _saved?.at);
  }

  void set(ThemePick pick, String by) {
    _saved = (pick: pick, by: by, at: _now());
    _persist();
    emit();
  }

  /// Tells everyone, when something changed: the pick, or the calendar under 'auto' (or the office's clock moved it).
  void emit() {
    final s = state();
    final key = jsonEncode(s.toJson());
    if (key == _told) return;
    _told = key;
    _onState(s);
  }

  void _restore() {
    try {
      final s = jsonDecode(File(_path).readAsStringSync());
      final pick = s is Map ? ThemePick.tryParse(s['pick']) : null;
      if (pick == null) return;
      final by = s['by'], at = s['at'];
      _saved = (pick: pick, by: by is String ? by : 'someone', at: at is num ? at.toInt() : 0);
    } catch (_) {
      // never set: it follows the calendar
    }
  }

  void _persist() {
    try {
      final s = _saved;
      writePrivateFile(_path, jsonPretty(s == null ? {} : {'pick': s.pick.wire, 'by': s.by, 'at': s.at}));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}
