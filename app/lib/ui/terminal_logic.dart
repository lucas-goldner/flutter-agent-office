// The parts of the terminal window that are decisions rather than widgets: who sizes the shared
// PTY, reading the xterm buffer the way shared/search.dart does, and finding a link under a click.
// No browser imports, so it is tested on the VM.

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

  SizeDecision decide({required bool typing, required WorkerInfo? w, required TermSize fit, required TermSize current}) {
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
  if (w.kind == WorkerKind.agent) providerLabel(w.provider, project),
  w.name,
  if (w.title != null && w.title!.isNotEmpty) w.title!,
  if (w.worktree != null) '🌿 ${w.worktree!.branch}',
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
