import 'dart:convert';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart' show ChatLine, logicalLines, searchKey, snippet;
import 'package:path/path.dart' as p;

import 'headless.dart';

/// How many chat lines the office keeps, across restarts.
const int chatKeep = 1000;

/// The office chat, kept in .agent-office/chat.jsonl (a line per message) so a restart doesn't wipe it.
class ChatLog {
  ChatLog(String dataDir) : _file = p.join(dataDir, 'chat.jsonl') {
    _load();
  }

  List<ChatLine> _lines = [];
  final String _file;

  /// Lines in the file. It only grows between rewrites, which trim it back to [chatKeep].
  int _fileLines = 0;

  List<ChatLine> recent(int n) => _lines.sublist(n >= _lines.length ? 0 : _lines.length - n);

  void add(ChatLine line) {
    _lines.add(line);
    if (_lines.length > chatKeep) _lines.removeRange(0, _lines.length - chatKeep);
    if (_fileLines >= chatKeep * 2) return _rewrite();
    try {
      _append('${jsonEncode(line.toJson())}\n');
      _fileLines++;
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  /// Lines whose text or sender holds `needle` (a searchKey), newest first.
  ({List<ChatLine> hits, bool more}) search(String needle, int limit) {
    final hits = <ChatLine>[];
    for (var i = _lines.length - 1; i >= 0; i--) {
      final l = _lines[i];
      if (!searchKey('${l.name}: ${l.text}').contains(needle)) continue;
      if (hits.length == limit) return (hits: hits, more: true);
      hits.add(l);
    }
    return (hits: hits, more: false);
  }

  void _append(String text) {
    final f = File(_file);
    final fresh = !f.existsSync();
    f.writeAsStringSync(text, mode: FileMode.append, flush: false);
    if (fresh) chmodSync(_file, 0x180); // 0600
  }

  void _load() {
    final f = File(_file);
    if (!f.existsSync()) return;
    List<String> raw;
    try {
      raw = f.readAsStringSync().split('\n').where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return;
    }
    for (final s in raw) {
      try {
        final l = jsonDecode(s);
        if (l is! Map<String, dynamic>) continue;
        final text = l['text'], name = l['name'], at = l['at'];
        if (text is! String || name is! String || at is! num) continue;
        final from = l['from'], color = l['color'];
        _lines.add(
          ChatLine(
            from: from is String ? from : '',
            name: name,
            color: color is String ? color : '#4f86f7',
            text: text,
            at: at.toInt(),
            account: l['account'] == true ? true : null,
          ),
        );
      } catch (_) {
        // a torn last line (the office died mid-write) is skipped
      }
    }
    _fileLines = raw.length;
    if (_lines.length > chatKeep || _lines.length != raw.length) {
      _lines = _lines.sublist(_lines.length > chatKeep ? _lines.length - chatKeep : 0);
      _rewrite();
    }
  }

  void _rewrite() {
    try {
      _write(_file, _lines.map((l) => '${jsonEncode(l.toJson())}\n').join());
      _fileLines = _lines.length;
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// Each worker's latest terminal output, kept in `.agent-office/scrollback/<worker id>.ansi` across restarts.
class ScrollbackStore {
  ScrollbackStore(String dataDir) : _dir = p.join(dataDir, 'scrollback');

  final String _dir;

  void save(String workerId, String data) {
    final file = _fileFor(workerId);
    if (file == null) return;
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        chmodSync(_dir, 0x1c0); // 0700
      }
      if (data.isNotEmpty) {
        _write(file, data);
      } else {
        _remove(file);
      }
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  String? load(String workerId) {
    final file = _fileFor(workerId);
    try {
      return file != null && File(file).existsSync() ? File(file).readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  void remove(String workerId) {
    final file = _fileFor(workerId);
    try {
      if (file != null) _remove(file);
    } catch (_) {
      // already gone
    }
  }

  /// Deletes what's kept for workers that are no longer at a desk.
  void prune(Set<String> keep) {
    try {
      for (final f in Directory(_dir).listSync()) {
        final name = p.basename(f.path);
        if (name.endsWith('.ansi') && !keep.contains(name.substring(0, name.length - '.ansi'.length))) _remove(f.path);
      }
    } catch (_) {
      // no folder yet
    }
  }

  static final _id = RegExp(r'^[\w-]{1,64}$');

  String? _fileFor(String workerId) => _id.hasMatch(workerId) ? p.join(_dir, '$workerId.ansi') : null;
}

/// A terminal's last [maxLines] lines as escape codes that redraw them, colors and all, ending with
/// the cursor just after the last one. A full-screen program's screen (the alternate buffer) is
/// added as plain text, since it is not part of the scrollback.
String terminalTail(HeadlessTerminal term, int maxLines) {
  final buf = term.normal;
  var last = buf.length - 1;
  while (last >= 0 && (buf.getLine(last)?.translateToString(true) ?? '').isEmpty) {
    last--;
  }
  var out = '';
  if (last >= 0) {
    var start = last - maxLines + 1 < 0 ? 0 : last - maxLines + 1;
    // Don't start halfway through a line the terminal wrapped.
    while (start > 0 && buf.getLine(start)!.isWrapped) {
      start--;
    }
    out = '${term.serializeRange(start, last)}\x1b[0m';
  }
  if (term.isAlt) {
    final screen = logicalLines(term.alternate).map((l) => l.text.trimRight()).toList();
    while (screen.isNotEmpty && screen.last.isEmpty) {
      screen.removeLast();
    }
    if (screen.isNotEmpty) out += '${out.isNotEmpty ? '\r\n' : ''}${screen.join('\r\n')}';
  }
  return out;
}

/// A terminal line that matched a search: its text cut down around the match, its row, and how
/// many rows its buffer had (so the browser's copy can find it again).
typedef TerminalSearchHit = ({String text, int row, int rows});

/// The lines of a worker's terminal holding `needle` (a searchKey), newest first, one per distinct
/// line: a full-screen program's screen first, then the scrollback.
({List<TerminalSearchHit> hits, bool more}) searchTerminal(HeadlessTerminal term, String needle, int limit) {
  final buffers = term.isAlt ? [term.alternate, term.normal] : [term.normal];
  final seen = <String>{};
  final hits = <TerminalSearchHit>[];
  for (final buf in buffers) {
    final lines = logicalLines(buf);
    for (var i = lines.length - 1; i >= 0; i--) {
      final key = searchKey(lines[i].text);
      // A TUI redraws the same line over and over (a status bar, a prompt box): show it once.
      if (!key.contains(needle) || seen.contains(key)) continue;
      if (hits.length == limit) return (hits: hits, more: true);
      seen.add(key);
      hits.add((text: snippet(lines[i].text, needle), row: lines[i].row, rows: buf.length));
    }
  }
  return (hits: hits, more: false);
}

/// Writes a file owner-only, whole: to `<file>.tmp`, then renamed over it.
void _write(String file, String data) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(data, flush: true);
  chmodSync(tmp, 0x180); // 0600
  File(tmp).renameSync(file);
}

void _remove(String file) {
  final f = File(file);
  if (f.existsSync()) f.deleteSync();
}
