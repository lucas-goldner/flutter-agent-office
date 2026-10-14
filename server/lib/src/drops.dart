import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'secrets.dart' show chmodPrivate;

// Files dropped or pasted into a worker's terminal from a browser (see office_shared's drops.dart),
// kept in .agent-office/drops/<worker id>/ so the program there can open them by path. They go with
// the worker. Ported from src/server/drops.ts.

/// The name ending a picture dropped without one gets, so the agent can tell it's a picture.
const _pictureExt = {'image/png': '.png', 'image/jpeg': '.jpg', 'image/gif': '.gif', 'image/webp': '.webp'};

final _workerId = RegExp(r'^[\w-]{1,64}$');
final _rng = Random.secure();

class DropStore {
  DropStore(String dataDir) : _dir = p.join(dataDir, 'drops');

  final String _dir;

  /// Keeps a file dropped into a worker's terminal; where it is now, or null if it couldn't be.
  String? save(String workerId, String name, String type, Uint8List body) {
    final dir = _folder(workerId);
    if (dir == null) return null;
    try {
      final d = Directory(dir);
      if (!d.existsSync()) {
        d.createSync(recursive: true);
        chmodPrivate(dir, '700');
      }
      final rand = [for (var i = 0; i < 4; i++) _rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      final file = File(p.join(dir, '$rand-${dropName(name, type)}'));
      if (file.existsSync()) return null; // 'wx': never overwrite
      // Made empty and private before the bytes go in.
      file.createSync(exclusive: true);
      chmodPrivate(file.path, '600');
      file.writeAsBytesSync(body, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  void remove(String workerId) {
    final dir = _folder(workerId);
    try {
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {
      // already gone
    }
  }

  /// Deletes what was dropped for workers that are no longer at a desk.
  void prune(Set<String> keep) {
    try {
      for (final e in Directory(_dir).listSync()) {
        final id = p.basename(e.path);
        if (!keep.contains(id)) remove(id);
      }
    } catch (_) {
      // no folder yet
    }
  }

  String? _folder(String workerId) => _workerId.hasMatch(workerId) ? p.join(_dir, workerId) : null;
}

// NFKD with the marks taken off, for the letters a European file name has (Dart has no Unicode
// normalization of its own); anything else that isn't a word character becomes a dash anyway.
const _foldFrom =
    'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöùúûüýÿĀāĂăĄąĆćĈĉĊċČčĎďĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĨĩĪīĬĭĮįİĴĵĶķ'
    'ĹĺĻļĽľŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſ';
const _foldTo =
    'AAAAAACEEEEIIIINOOOOOUUUUYaaaaaaceeeeiiiinooooouuuuyyAaAaAaCcCcCcCcDdEeEeEeEeEeGgGgGgGgHhIiIiIiIiIJjKk'
    'LlLlLlNnNnNnOoOoOoRrRrRrSsSsSsSsTtTtUuUuUuUuUuUuWwYyYZzZzZzs';
final Map<int, String> _fold = {
  for (var i = 0; i < _foldFrom.length; i++) _foldFrom.codeUnitAt(i): _foldTo[i],
  0x132: 'IJ',
  0x133: 'ij',
};
final _marks = RegExp(r'\p{M}', unicode: true);

String _stripMarks(String s) {
  final b = StringBuffer();
  for (final r in s.replaceAll(_marks, '').runes) {
    b.write(_fold[r] ?? String.fromCharCode(r));
  }
  return b.toString();
}

/// A dropped file's name, safe to type into a terminal: its letters and digits kept, anything else a
/// dash, and a picture's name ending added when it came without one (a pasted screenshot can).
String dropName(String name, String type) {
  final base = name.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  var ext = dot > 0 ? base.substring(dot).toLowerCase().replaceAll(RegExp(r'[^.a-z0-9]'), '') : '';
  if (ext.length > 12) ext = ext.substring(0, 12);
  var stem = _stripMarks(
    dot > 0 ? base.substring(0, dot) : base,
  ).replaceAll(RegExp(r'[^\w.-]+'), '-').replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80);
  final picture = _pictureExt[type.split(';').first.trim().toLowerCase()] ?? '';
  return '${stem.isEmpty ? 'file' : stem}${ext.length > 1 ? ext : picture}';
}
