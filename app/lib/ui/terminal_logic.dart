// The parts of the terminal window that are decisions rather than widgets: who sizes the shared
// PTY, reading the xterm buffer the way shared/search.dart does, and finding a link under a click.
// No browser imports, so it is tested on the VM.

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:xterm/xterm.dart' as x;

import 'package:office_shared/protocol.dart';
import 'package:office_shared/search.dart';

import 'provider.dart';

/// A search hit to scroll to once the terminal has loaded (see search.dart): `needle` is what was
/// searched for, as a searchKey, and `row` how many rows from the bottom of the worker's terminal
/// the line was (TerminalFind.fromEnd in the old client).
typedef TerminalFind = ({int row, String needle});

typedef TermSize = ({int cols, int rows});

/// What the window should do about its size: resize the local terminal, and maybe tell the PTY.
typedef SizeDecision = ({TermSize? resizeTo, TermSize? send});

/// Sizes the shared PTY to this window. Typing always claims it (latest typist wins); merely
/// opening or resizing the window only does when nobody else is watching, so a phone that is just
/// looking doesn't reflow the terminal under whoever is working.
class TermSizePolicy {
  /// The size this window last asked the PTY for ('' when it follows someone else's).
  String lastSent = '';

  SizeDecision decide({
    required bool typing,
    required WorkerInfo? w,
    required TermSize fit,
    required TermSize current,
  }) {
    if (!typing && (w?.viewers.length ?? 0) > 1) {
      if (w != null && (w.cols != current.cols || w.rows != current.rows)) {
        return (resizeTo: (cols: w.cols, rows: w.rows), send: null);
      }
      return (resizeTo: null, send: null);
    }
    final key = '${fit.cols}x${fit.rows}';
    TermSize? send;
    if (w != null && (w.cols != fit.cols || w.rows != fit.rows) && key != lastSent) {
      lastSent = key;
      send = fit;
    }
    return (resizeTo: fit.cols != current.cols || fit.rows != current.rows ? fit : null, send: send);
  }

  /// Someone else resized the shared PTY (the latest typist wins): follow it so this view renders
  /// correctly. Typing here fits the terminal back to this window and reclaims the size.
  TermSize? follow(WorkerInfo w, TermSize current) {
    final pty = '${w.cols}x${w.rows}';
    if (pty != '${current.cols}x${current.rows}' && pty != lastSent) {
      lastSent = '';
      return (cols: w.cols, rows: w.rows);
    }
    return null;
  }
}

/// The header title: provider, name, what it's on, and its worktree branch.
String terminalTitle(WorkerInfo w, ProjectInfo? project) => [
  if (w.kind == WorkerKind.agent) engineLabel(w, project),
  w.name,
  if (w.title != null && w.title!.isNotEmpty) w.title!,
  if (w.worktree != null) '🌿 ${w.worktree!.branch}',
  if (w.repos?.isNotEmpty ?? false)
    '🗂️ ${[w.worktree?.path.split(RegExp(r'[\\/]')).last, ...w.repos!.map((r) => r.name)].nonNulls.join(' + ')}',
].join(' · ');

/// A row of the xterm buffer as xterm.js's translateToString gives it: blank cells are spaces,
/// the second half of a wide character is skipped.
String lineText(x.BufferLine line, [bool trimRight = false]) {
  final b = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final cp = line.getCodePoint(i);
    final width = line.getWidth(i);
    if (cp == 0) {
      if (width != 0 || i == 0 || line.getWidth(i - 1) != 2) b.write(' ');
    } else {
      b.writeCharCode(cp);
    }
  }
  final s = b.toString();
  return trimRight ? s.trimRight() : s;
}

class _Line implements BufferLineLike {
  _Line(this.line);
  final x.BufferLine line;

  @override
  bool get isWrapped => line.isWrapped;

  @override
  String translateToString([bool trimRight = false]) => lineText(line, trimRight);
}

/// The terminal's buffer as shared/search.dart reads it.
class XtermBuffer implements BufferLike {
  XtermBuffer(this.buffer);
  final x.Buffer buffer;

  @override
  int get length => buffer.lines.length;

  @override
  BufferLineLike? getLine(int y) => y >= 0 && y < buffer.lines.length ? _Line(buffer.lines[y]) : null;
}

/// The web-links addon's link pattern.
final _url = RegExp(r'''(https?|HTTPS?):[/]{2}[^\s"'!*(){}|\\\^<>`]*[^\s"':,.!?{}|\\\^~\[\]`()<>]''');

/// The URL under column [col] of row [row], following the line across wrapped rows.
String? urlAt(BufferLike buf, int row, int col) {
  final here = buf.getLine(row);
  if (here == null) return null;
  var start = row;
  while (start > 0 && buf.getLine(start)!.isWrapped) {
    start--;
  }
  final text = StringBuffer();
  var at = -1;
  for (var y = start; y < buf.length; y++) {
    final line = buf.getLine(y)!;
    if (y > start && !line.isWrapped) break;
    final t = line.translateToString(false);
    if (y == row) at = text.length + col;
    text.write(t);
  }
  if (at < 0) return null;
  for (final m in _url.allMatches(text.toString())) {
    if (at >= m.start && at < m.end) return m.group(0);
  }
  return null;
}

bool _pathChar(String c) => !RegExp(r'''[\s"'<>(){}\[\]`|]''').hasMatch(c);

/// The file path under column [col] of row [row] (one starting with `/` or `~/`), as candidates to try,
/// longest first. Claude Code breaks a long path onto the next line itself, indented, so the path is
/// followed back up and down across such breaks: the line above ending in a path, the one below
/// starting with the rest of it. Which one is real only the office can tell (it has the files), so
/// the shorter readings come too. Empty when there's no path there.
List<String> pathsAt(BufferLike buf, int row, int col) {
  String? text(int y) => buf.getLine(y)?.translateToString(false);
  final here = text(row);
  if (here == null || col < 0 || col >= here.length || !_pathChar(here[col])) return const [];
  var s = col, e = col;
  while (s > 0 && _pathChar(here[s - 1])) {
    s--;
  }
  while (e < here.length && _pathChar(here[e])) {
    e++;
  }
  final parts = <String>[here.substring(s, e)];
  var at = parts.length - 1; // where the token under the pointer is in [parts]
  // Up: this piece starts its line (only indent before it), and the line above ends in a path.
  var y = row, start = s;
  final upMost = row - 4;
  while (y > upMost) {
    final line = text(y)!;
    final wrapped = buf.getLine(y)!.isWrapped;
    if (!wrapped && line.substring(0, start).trim().isNotEmpty) break;
    final up = text(y - 1)?.trimRight();
    if (up == null || up.isEmpty) break;
    var us = up.length;
    while (us > 0 && _pathChar(up[us - 1])) {
      us--;
    }
    final prev = up.substring(us);
    if (prev.isEmpty || !prev.contains('/')) break;
    parts.insert(0, prev);
    at++;
    y--;
    start = us;
  }
  // Down: this piece ends its line, and the line below starts (after its indent) with more of it.
  y = row;
  var end = e;
  final downMost = row + 4;
  while (y < downMost) {
    final line = text(y)!;
    if (line.substring(end).trim().isNotEmpty) break;
    final down = text(y + 1);
    if (down == null) break;
    var ds = 0;
    while (ds < down.length && down[ds] == ' ') {
      ds++;
    }
    if (ds >= down.length || !_pathChar(down[ds])) break;
    var de = ds;
    while (de < down.length && _pathChar(down[de])) {
      de++;
    }
    parts.add(down.substring(ds, de));
    y++;
    end = de;
  }
  final out = <String>[];
  void add(String p) {
    final t = p.replaceFirst(RegExp(r'[.,:;!?]+$'), '');
    if ((t.startsWith('/') || t.startsWith('~/')) && t.length > 1 && !out.contains(t)) out.add(t);
  }

  // Longest first: everything joined, then dropping pieces from the ends, the token alone last.
  for (var len = parts.length; len >= 1; len--) {
    for (var from = 0; from + len <= parts.length; from++) {
      if (from <= at && at < from + len) add(parts.sublist(from, from + len).join());
    }
  }
  return out;
}

// ---- Who's in the terminal ---------------------------------------------------------------------

/// How long someone shows as typing after the last word from their keyboard (they send one about every second).
const int kTypingShowsMs = 2500;

/// "Sam is typing…", "Sam and Ada are typing…", "Sam and 2 others are typing…".
String typingLine(List<String> names) {
  if (names.length == 1) return '${names[0]} is typing…';
  if (names.length == 2) return '${names[0]} and ${names[1]} are typing…';
  return '${names[0]} and ${names.length - 1} others are typing…';
}

/// Up to two letters for someone's face: "Sam" -> "S", "Ada Lovelace" -> "AL".
String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  String first(String? w) => w == null || w.isEmpty ? '' : String.fromCharCode(w.runes.first).toUpperCase();
  final s = words.isEmpty ? '' : first(words.first) + (words.length > 1 ? first(words.last) : '');
  return s.isEmpty ? '?' : s;
}

/// One face in the terminal's header.
typedef TermViewer = ({String name, String color, bool you, bool typing});

/// Everyone in the terminal, one face per person however many windows they have it open in, you
/// first. [typing] holds the viewer ids typing now.
List<TermViewer> viewersOf(List<String> viewerIds, Map<String, PeerInfo> peers, String? you, Set<String> typing) {
  final byName = <String, TermViewer>{};
  for (final id in viewerIds) {
    final p = peers[id];
    if (p == null) continue;
    final v = byName[p.name] ?? (name: p.name, color: p.color, you: false, typing: false);
    byName[p.name] = (name: v.name, color: v.color, you: v.you || id == you, typing: v.typing || typing.contains(id));
  }
  final list = byName.values.toList();
  // A stable sort: you first, the rest in the order they came.
  return [...list.where((v) => v.you), ...list.where((v) => !v.you)];
}

/// Whether this is a Mac (or an iPad), where ⌘ is the editing modifier. On the web Flutter reads it off the browser.
bool get isMacKeyboard => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;

/// The editing keys people expect from their own terminal ("Natural Text Editing" in iTerm2, and what VS
/// Code's terminal sends), which the terminal leaves out (termkeys.ts): it sends a plain backspace for ⌘⌫
/// and Ctrl+⌫, a plain Enter for Shift+Enter, and nothing at all for ⌘← / ⌘→. Returns the bytes to send
/// instead, or null to let the terminal handle the key. Every one is a readline control key that Claude
/// Code, Codex, OpenCode and bash all understand:
///
/// - Shift+Enter → Ctrl+J, a new line in the agents' prompts (Enter, like before, in a shell)
/// - Ctrl+⌫ → Ctrl+W, delete the word before the cursor (⌥⌫ already does, as Esc ⌫)
/// - ⌘⌫ → Ctrl+U, delete to the start of the line; ⌘⌦ → Ctrl+K, to the end
/// - ⌘← / ⌘→ → Ctrl+A / Ctrl+E, jump to the start / end of the line
///
/// [key] is the DOM key name: Enter, Backspace, Delete, ArrowLeft, ArrowRight.
String? naturalKey(
  String key, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
  required bool mac,
}) {
  final mods = '${ctrl ? 'C' : ''}${alt ? 'A' : ''}${shift ? 'S' : ''}${meta ? 'M' : ''}';
  final cmd = mac ? 'M' : null;
  switch (key) {
    case 'Enter':
      return mods == 'S' ? '\n' : null;
    case 'Backspace':
      if (mods == 'C') return '\x17';
      return mods == cmd ? '\x15' : null;
    case 'Delete':
      return mods == cmd ? '\x0b' : null;
    case 'ArrowLeft':
      return mods == cmd ? '\x01' : null;
    case 'ArrowRight':
      return mods == cmd ? '\x05' : null;
  }
  return null;
}

/// Whether Ctrl plus the key typing [character] at [physical] is Ctrl+[want] ('[' or ']'): by the character,
/// or by the key's place for keyboards where [ and ] take AltGr or are other letters (ü, å), but not where
/// that key types something else ASCII (Ctrl + + zooms in on a German keyboard).
bool ctrlBracket(String want, {required String? character, required bool atBracketKey}) {
  if (character == want) return true;
  if (!atBracketKey) return false;
  final c = character ?? '';
  return !(c.length == 1 && c.codeUnitAt(0) >= 0x20 && c.codeUnitAt(0) <= 0x7e);
}

final _escMention = RegExp(r'\besc(ape)?\b(?!\s+(to\s+)?interrupt)', caseSensitive: false);

/// Whether the program in the terminal says Esc does something right now, like Claude's /skills menu
/// ("Esc to close") or a question ("Esc to cancel"), apart from interrupting it while it works. [lines] are
/// the rows on screen.
bool screenMentionsEsc(Iterable<String> lines) => lines.any(_escMention.hasMatch);

/// The tip when Esc left a terminal whose program wanted one.
String escLeftTip(String name) =>
    'Esc left the terminal. To send $name an Esc (to close a menu), use ⎋ Esc at the top or Ctrl+[';

/// The mouse handler for workers' terminals: the xterm package's, except for the wheel. That package
/// reports a wheel notch as buttons 68/69 (which a program reads as Shift + wheel) and at the pointer's
/// place in the window rather than in the terminal, so a full-screen program that scrolls itself
/// (Claude Code's no-flicker mode: alternate screen + mouse reporting) ignored it and its window
/// couldn't be scrolled. Here a notch is 64 up / 65 down (66/67 sideways), at the cell [cellAt] says the
/// pointer is over.
class WheelMouseHandler implements x.TerminalMouseHandler {
  WheelMouseHandler(this.cellAt);

  /// The cell under the pointer (0-based), or null when it isn't known.
  final x.CellOffset? Function() cellAt;

  @override
  String? call(x.TerminalMouseEvent event) {
    if (!event.button.isWheel) return x.defaultMouseHandler(event);
    final mode = event.state.mouseMode;
    if (mode == x.MouseMode.none || mode == x.MouseMode.clickOnly) return null;
    if (event.buttonState != x.TerminalMouseButtonState.down) return null;
    final at = cellAt() ?? event.position;
    return wheelReport(
      switch (event.button) {
        x.TerminalMouseButton.wheelUp => 64,
        x.TerminalMouseButton.wheelDown => 65,
        x.TerminalMouseButton.wheelLeft => 66,
        _ => 67,
      },
      at.x.clamp(0, event.state.viewWidth - 1),
      at.y.clamp(0, event.state.viewHeight - 1),
      event.state.mouseReportMode,
    );
  }
}

/// A wheel notch ([code] 64-67) at cell ([col], [row]), 0-based, as a terminal reports it in [mode].
String wheelReport(int code, int col, int row, x.MouseReportMode mode) {
  final cx = col + 1, cy = row + 1;
  return switch (mode) {
    x.MouseReportMode.sgr => '\x1b[<$code;$cx;${cy}M',
    x.MouseReportMode.urxvt => '\x1b[${32 + code};$cx;${cy}M',
    x.MouseReportMode.normal || x.MouseReportMode.utf =>
      '\x1b[M${String.fromCharCode(32 + code)}${String.fromCharCode(32 + cx)}${String.fromCharCode(32 + cy)}',
  };
}
