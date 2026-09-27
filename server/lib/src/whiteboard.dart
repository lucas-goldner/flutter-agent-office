import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart' hide Whiteboard;
import 'package:path/path.dart' as p;

/// How long after the last stroke the drawing is written to disk.
const Duration _saveDelay = Duration(milliseconds: 2000);

/// Deleted elements are kept this long, so the deletion reaches anyone who still has them.
const int _tombstoneMs = 7 * 24 * 3600000;

/// What `apply` made of a batch of changes.
class Applied {
  const Applied({required this.accepted, this.error});

  /// The changes that went in, to pass on to everyone else.
  final List<WbElement> accepted;

  /// Why some didn't, when the board is full.
  final String? error;
}

/// A floor's whiteboard: the Excalidraw elements everyone drew, merged by version the way
/// Excalidraw's live collaboration merges them, and the pictures on it. Kept in the floor's
/// .agent-office/whiteboard folder: elements.json, and a file per picture under files/.
class Whiteboard {
  Whiteboard(String dataDir)
    : _dir = p.join(dataDir, 'whiteboard'),
      _filesDir = p.join(dataDir, 'whiteboard', 'files') {
    _load();
  }

  final Map<String, WbElement> _elements = {};

  /// Each element's size as JSON, to keep the board under [wbMaxBytes].
  final Map<String, int> _sizes = {};
  int _bytes = 0;

  /// Pictures on disk, by id, with their size.
  final Map<String, int> _files = {};
  int _fileBytes = 0;
  final String _dir;
  final String _filesDir;
  Timer? _saveTimer;

  /// Every element, deleted ones too, bottom of the stack first.
  List<WbElement> scene() => _elements.values.toList()..sort(byIndex);

  /// Whether anything is drawn on it.
  bool get empty => _elements.values.every((e) => e.isDeleted);

  /// Takes in someone's changes: each element that's newer than the board's copy replaces it.
  Applied apply(Object? raw) {
    final accepted = <WbElement>[];
    String? error;
    for (final item in raw is List ? raw : const []) {
      final el = checkElement(item);
      if (el == null) continue;
      final had = _elements[el.id];
      if (!newer(el, had)) continue;
      final size = jsonEncode(el.raw).length;
      if (size > wbMaxElementBytes) {
        error = 'That drawing is too big for the whiteboard. Try it in smaller pieces.';
        continue;
      }
      if (had == null && _elements.length >= wbMaxElements) _forgetDeleted(1);
      if (_bytes - (_sizes[el.id] ?? 0) + size > wbMaxBytes) _forgetDeleted(null);
      if ((had == null && _elements.length >= wbMaxElements) || _bytes - (_sizes[el.id] ?? 0) + size > wbMaxBytes) {
        error = 'The whiteboard is full. Clear some of it to draw more.';
        continue;
      }
      _put(el, size);
      accepted.add(el);
    }
    if (accepted.isNotEmpty) _saveSoon();
    return Applied(accepted: accepted, error: error);
  }

  /// A picture on the board, from disk.
  WbFile? file(String id) {
    if (!_files.containsKey(id)) return null;
    try {
      return checkFile(jsonDecode(File(p.join(_filesDir, '$id.json')).readAsStringSync())).file;
    } catch (_) {
      return null;
    }
  }

  /// Keeps a picture someone put on the board. A picture with the same id is already there: it's the same picture.
  /// Returns why it couldn't, if it couldn't.
  String? addFile(Object? raw) {
    final checked = checkFile(raw);
    final f = checked.file;
    if (f == null) return checked.error;
    if (_files.containsKey(f.id)) return null;
    final json = jsonEncode(f.toJson());
    if (_fileBytes + json.length > wbMaxFilesBytes) _forgetUnusedFiles();
    if (_fileBytes + json.length > wbMaxFilesBytes) {
      return 'The whiteboard has too many pictures on it. Delete some first.';
    }
    try {
      _mkdirPrivate(_filesDir);
      _writePrivate(p.join(_filesDir, '${f.id}.json'), json, aside: false);
    } catch (_) {
      return "Couldn't save the picture on the office's machine";
    }
    _files[f.id] = json.length;
    _fileBytes += json.length;
    return null;
  }

  /// Writes the drawing to disk now, if it has changed since.
  void flush() {
    final t = _saveTimer;
    if (t == null) return;
    t.cancel();
    _saveTimer = null;
    _save();
  }

  void _put(WbElement el, int size) {
    _bytes += size - (_sizes[el.id] ?? 0);
    _elements[el.id] = el;
    _sizes[el.id] = size;
  }

  void _drop(String id) {
    _bytes -= _sizes[id] ?? 0;
    _elements.remove(id);
    _sizes.remove(id);
  }

  /// Makes room by forgetting up to `n` deleted elements (all of them when null), the longest-deleted first.
  void _forgetDeleted(int? n) {
    final gone = _elements.values.where((e) => e.isDeleted).toList()
      ..sort((a, b) => (a.updated ?? 0) - (b.updated ?? 0));
    for (final e in n == null ? gone : gone.take(n)) {
      _drop(e.id);
    }
  }

  /// Pictures that no element shows any more, deleted elements included (an undo can bring those back).
  void _forgetUnusedFiles() {
    final used = {
      for (final e in _elements.values)
        if (e.fileId != null && e.fileId!.isNotEmpty) e.fileId!,
    };
    for (final entry in [..._files.entries]) {
      final id = entry.key;
      final size = entry.value;
      if (used.contains(id)) continue;
      try {
        File(p.join(_filesDir, '$id.json')).deleteSync();
      } catch (_) {
        continue;
      }
      _files.remove(id);
      _fileBytes -= size;
    }
  }

  void _saveSoon() {
    _saveTimer ??= Timer(_saveDelay, () {
      _saveTimer = null;
      _save();
    });
  }

  void _save() {
    try {
      _mkdirPrivate(_dir);
      // Written aside and moved into place, so a crash mid-write can't leave half a drawing.
      _writePrivate(p.join(_dir, 'elements.json'), jsonEncode([for (final e in scene()) e.raw]));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _load() {
    final file = File(p.join(_dir, 'elements.json'));
    if (file.existsSync()) {
      try {
        final saved = jsonDecode(file.readAsStringSync());
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final item in saved is List ? saved : const []) {
          final el = checkElement(item);
          if (el == null || (el.isDeleted && now - (el.updated ?? 0) > _tombstoneMs)) continue;
          _put(el, jsonEncode(el.raw).length);
        }
      } catch (_) {
        // a broken file just means a clean board
      }
    }
    try {
      for (final entry in Directory(_filesDir).listSync()) {
        final name = p.basename(entry.path);
        if (!name.endsWith('.json')) continue;
        final size = entry.statSync().size;
        _files[name.substring(0, name.length - 5)] = size;
        _fileBytes += size;
      }
    } catch (_) {
      // no pictures yet
    }
    _forgetUnusedFiles();
  }
}

/// Makes [dir] (and its parents) if it isn't there, readable by this user only.
void _mkdirPrivate(String dir) {
  final d = Directory(dir);
  if (d.existsSync()) return;
  d.createSync(recursive: true);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['700', dir]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
}

/// Writes [text] to [file] readable by this user only; with [aside], to `<file>.tmp` first and then
/// moved into place.
void _writePrivate(String file, String text, {bool aside = true}) {
  final to = aside ? '$file.tmp' : file;
  File(to).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', to]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  if (aside) File(to).renameSync(file);
}
