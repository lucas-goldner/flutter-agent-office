// A floor's dungeon. Port of src/server/jail.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// How many prisoners are kept by name: the ones from before them are only a count, bones on the heap.
const maxPrisoners = 200;

/// A floor's dungeon (see MapPlan.sendHome): every worker sent home on a map that keeps them, for
/// good, first to last: locked up in the castle's cells, or adrift outside the station's airlock
/// (it's one list, so they're in whichever the building's map has). The map works out how far each has
/// wasted away from when it went; this only remembers who and when. Saved in .agent-office/jail.json.
class Jail {
  Jail(String dataDir, {int Function()? now})
    : _file = p.join(dataDir, 'jail.json'),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _load();
  }

  final String _file;
  final int Function() _now;
  List<Prisoner> _prisoners = [];
  int _bones = 0;

  JailState state() => JailState(prisoners: List.unmodifiable(_prisoners), bones: _bones);

  /// Locks a worker up, as of now.
  JailState add({required String id, required String name, required String color, int? workedMs}) {
    _prisoners = [
      for (final q in _prisoners)
        if (q.id != id) q,
      Prisoner(
        id: id,
        name: name,
        color: color,
        at: _now(),
        workedMs: workedMs != null && workedMs > 0 ? workedMs : null,
      ),
    ];
    final over = _prisoners.length - maxPrisoners;
    if (over > 0) {
      _prisoners.removeRange(0, over);
      _bones += over;
    }
    _save();
    return state();
  }

  void _load() {
    final f = File(_file);
    if (!f.existsSync()) return;
    try {
      final s = jsonDecode(f.readAsStringSync());
      if (s is! Map) return;
      final raw = s['prisoners'];
      final ok = [
        if (raw is List)
          for (final q in raw)
            if (q is Map &&
                q['id'] is String &&
                q['name'] is String &&
                q['color'] is String &&
                q['at'] is num &&
                (q['at'] as num).isFinite)
              q,
      ];
      final kept = ok.length > maxPrisoners ? ok.sublist(ok.length - maxPrisoners) : ok;
      _prisoners = [
        for (final q in kept)
          Prisoner(
            id: _cut(q['id'] as String, 64),
            name: _cut(q['name'] as String, 64),
            color: _cut(q['color'] as String, 32),
            at: (q['at'] as num).toInt(),
            workedMs: q['workedMs'] is num && (q['workedMs'] as num).isFinite && (q['workedMs'] as num) > 0
                ? (q['workedMs'] as num).toInt()
                : null,
          ),
      ];
      final bones = s['bones'];
      _bones = bones is int && bones > 0
          ? bones
          : (bones is double && bones == bones.truncateToDouble() && bones > 0 ? bones.toInt() : 0);
    } catch (_) {
      // a broken file just means an empty dungeon
    }
  }

  void _save() {
    try {
      writePrivateFile(
        _file,
        jsonPretty({
          'prisoners': [for (final q in _prisoners) q.toJson()],
          'bones': _bones,
        }),
      );
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// JS's String.slice(0, max) on UTF-16 code units.
String _cut(String s, int max) => s.length > max ? s.substring(0, max) : s;
