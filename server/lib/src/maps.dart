// The building's map pick and the maps of your own. Port of src/server/maps.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// The most custom maps read, and the biggest file that's read as one.
const maxMapFiles = 24;
const maxMapBytes = 256 * 1024;

/// The building's map (the office, the castle, or one of your own), picked in ⚙️ Settings by anyone
/// and kept in .agent-office/map.json. Everyone's on the same one. Maps of your own are JSON files in
/// .agent-office/maps/ (see docs/maps.md), read again whenever someone looks at the list.
class Maps {
  Maps(String dataDir, {int Function()? now})
    : _file = p.join(dataDir, 'map.json'),
      _dir = p.join(dataDir, 'maps'),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _restore();
    reload();
  }

  final String _file;
  final String _dir;
  final int Function() _now;
  ({String pick, String by, int at})? _saved;
  List<CustomMap> _custom = [];

  /// What the folder looked like when it was last read: each file's name, size and mtime.
  String _stamp = '';

  /// The folder custom maps go in.
  String get folder => _dir;

  MapState state() {
    final pick = this.pick();
    final s = _saved;
    // Who picked it, while it's what they picked (not the office, while their map won't load).
    final mine = s != null && s.pick == pick;
    return MapState(pick: pick, custom: List.unmodifiable(_custom), by: mine ? s.by : null, at: mine ? s.at : null);
  }

  /// The map everyone's on: the one picked, while it's there to be had.
  String pick() {
    final p = _saved?.pick;
    return p != null && p.isNotEmpty && isMapChoice(p, _custom) ? p : officeMap;
  }

  /// Where everything is on the building's map.
  MapPlan plan() => planOf(pick(), _custom);

  /// False when there's no such map (or it won't load). Read the folder first ([reload]), so a map just added counts.
  bool set(String pick, String by) {
    if (!isMapChoice(pick, _custom)) return false;
    _saved = (pick: pick, by: by, at: _now());
    _persist();
    return true;
  }

  /// Reads the custom maps again; true if anything in the folder changed.
  bool reload() {
    var names = <String>[];
    var extra = <String>[];
    try {
      names = Directory(_dir).listSync().map((e) => p.basename(e.path)).where((f) => f.endsWith('.json')).toList()
        ..sort();
      extra = names.length > maxMapFiles ? names.sublist(maxMapFiles) : [];
      if (names.length > maxMapFiles) names = names.sublist(0, maxMapFiles);
    } catch (_) {
      // no folder: no maps of your own
    }
    final stats = [
      for (final f in names)
        () {
          try {
            final s = File(p.join(_dir, f)).statSync();
            if (s.type == FileSystemEntityType.notFound) return (f: f, size: -1, mtime: 0);
            return (f: f, size: s.size, mtime: s.modified.millisecondsSinceEpoch);
          } catch (_) {
            return (f: f, size: -1, mtime: 0);
          }
        }(),
    ];
    final stamp = jsonEncode([
      [
        for (final s in stats) {'f': s.f, 'size': s.size, 'mtime': s.mtime},
      ],
      extra,
    ]);
    if (stamp == _stamp) return false;
    _stamp = stamp;
    final files = [
      for (final s in stats)
        () {
          if (s.size > maxMapBytes) return (file: s.f, json: null, error: "it's over ${maxMapBytes ~/ 1024} KB");
          try {
            return (file: s.f, json: jsonDecode(File(p.join(_dir, s.f)).readAsStringSync()) as Object?, error: null);
          } on FormatException catch (e) {
            return (file: s.f, json: null, error: "it isn't valid JSON (${e.message})");
          } catch (e) {
            return (file: s.f, json: null, error: "it isn't valid JSON ($e)");
          }
        }(),
    ];
    final checked = checkCustomMaps([
      for (final f in files)
        if (f.error == null) (file: f.file, json: f.json),
    ]);
    _custom = [
      for (final f in files)
        f.error != null ? CustomMap(file: f.file, error: f.error) : checked.firstWhere((c) => c.file == f.file),
      for (final f in extra) CustomMap(file: f, error: 'only the first $maxMapFiles maps in the folder are read'),
    ];
    return true;
  }

  void _restore() {
    try {
      final s = jsonDecode(File(_file).readAsStringSync());
      if (s is! Map || s['pick'] is! String) return;
      final by = s['by'], at = s['at'];
      _saved = (pick: s['pick'] as String, by: by is String ? by : 'someone', at: at is num ? at.toInt() : 0);
    } catch (_) {
      // never set: the office
    }
  }

  void _persist() {
    try {
      final s = _saved;
      writePrivateFile(_file, jsonPretty(s == null ? {} : {'pick': s.pick, 'by': s.by, 'at': s.at}));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}
