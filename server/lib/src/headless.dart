// A worker's screen, kept on the server: what @xterm/headless and its SerializeAddon were for the
// Node server, on top of the vendored xterm.dart core (package:xterm_core).
//
// The PTY host keeps one per terminal (so the next office gets the scrollback back), and the office
// keeps one per worker: it reads Claude's progress reports and title off it, draws the laptop
// screens from it (snapshotScreen), and hands a browser opening the terminal a snapshot of it
// (serialize) to replay into its own terminal.

import 'package:office_shared/shared.dart'
    show BufferLike, BufferLineLike, Run, ScreenMsg, flagBold, flagDim, flagInverse, rgbFlag;
import 'package:xterm_core/xterm_core.dart';

/// Lines a terminal keeps above its screen.
const int scrollback = 3000;

/// A terminal with no view: output goes in, the screen and scrollback can be read back out.
class HeadlessTerminal {
  HeadlessTerminal({required int cols, required int rows, this.scrollbackLines = scrollback})
    // xterm.dart counts the screen in maxLines; it also starts at 24 rows before the resize.
    : term = Terminal(maxLines: scrollbackLines + rows < 24 ? 24 : scrollbackLines + rows) {
    term.onTitleChange = (title) => onTitleChange?.call(title);
    term.onPrivateOSC = _osc;
    term.resize(cols, rows);
  }

  final Terminal term;
  final int scrollbackLines;

  /// The program set the window title (OSC 0 / 2).
  void Function(String title)? onTitleChange;

  /// OSC 9;4 progress (Claude Code emits it): 0 = idle, anything else = busy.
  void Function(bool busy)? onProgress;

  int get cols => term.viewWidth;
  int get rows => term.viewHeight;

  /// A full-screen program has switched to the alternate screen.
  bool get isAlt => term.isUsingAltBuffer;

  TermBuffer get normal => TermBuffer(term.mainBuffer);
  TermBuffer get alternate => TermBuffer(term.altBuffer);
  TermBuffer get active => TermBuffer(term.buffer);

  /// Parses [data] onto the screen. Unlike xterm.js this is synchronous: once it returns, the
  /// screen shows everything written so far.
  void write(String data) => term.write(data);

  void resize(int cols, int rows) => term.resize(cols, rows);

  /// Marks the normal buffer's cursor line, to find it again as lines scroll (xterm.js's
  /// registerMarker(0)).
  TermMarker registerMarker() {
    final buf = term.mainBuffer;
    return TermMarker._(buf.lines[buf.absoluteCursorY].createAnchor(0));
  }

  /// Nothing to release (xterm.js needed dispose); kept so callers read the same.
  void dispose() {
    onTitleChange = null;
    onProgress = null;
  }

  void _osc(String code, List<String> args) {
    if (code != '9' || args.isEmpty || args[0] != '4') return;
    final state = args.length > 1 && args[1].isNotEmpty ? args[1].codeUnitAt(0) : 0;
    if (state >= 0x30 && state <= 0x39) onProgress?.call(state != 0x30);
  }

  // ---------------------------------------------------------------------------------------------
  // Serializing: escape codes that redraw the terminal in a fresh one.

  /// The screen and up to [scrollback] lines above it, colors, modes and cursor and all, like
  /// SerializeAddon's `serialize({ scrollback })`. A full-screen program's alternate screen comes
  /// after the normal buffer, switched to as the program did.
  String serialize({int? scrollback}) {
    final out = StringBuffer();
    final main = term.mainBuffer;
    final start = scrollback == null ? 0 : (main.height - rows - scrollback).clamp(0, main.height);
    final sgr = _Sgr(out);
    _rows(main, start, main.height - 1, out, sgr);
    sgr.reset();
    if (isAlt) {
      // The normal screen's cursor is saved by the switch and comes back when the program exits.
      out.write('\x1b[${main.cursorY + 1};${main.cursorX + 1}H');
      out.write('\x1b[?1049h\x1b[H');
      final alt = term.altBuffer;
      _rows(alt, alt.height - rows, alt.height - 1, out, sgr);
      sgr.reset();
    }
    final buf = term.buffer;
    if (buf.marginTop != 0 || buf.marginBottom != rows - 1) {
      out.write('\x1b[${buf.marginTop + 1};${buf.marginBottom + 1}r');
    }
    out.write(_modes());
    final top = term.originMode ? buf.marginTop : 0;
    out.write('\x1b[${buf.cursorY - top + 1};${buf.cursorX + 1}H');
    // What the program prints next carries on in the style it last set.
    final c = term.cursor;
    if (c.foreground != 0 || c.background != 0 || c.attrs != 0) {
      out.write(_Sgr.codes(c.foreground, c.background, c.attrs));
    }
    return out.toString();
  }

  /// Normal-buffer rows [start]..[end] (inclusive), without modes or cursor: the cursor ends just
  /// after the last row's text. SerializeAddon's `serialize({ range, excludeAltBuffer, excludeModes })`.
  String serializeRange(int start, int end) {
    final out = StringBuffer();
    final sgr = _Sgr(out);
    _rows(term.mainBuffer, start, end, out, sgr);
    return out.toString();
  }

  void _rows(Buffer buf, int start, int end, StringBuffer out, _Sgr sgr) {
    var prevWide = false;
    for (var y = start; y <= end && y < buf.height; y++) {
      final line = buf.lines[y];
      if (y > start && !line.isWrapped) {
        // Blank cells after a line end take the background of the style in force: none.
        sgr.reset();
        out.write('\r\n');
      }
      final wrapsOn = y + 1 < buf.height && y < end && buf.lines[y + 1].isWrapped;
      final width = line.length < cols ? line.length : cols;
      // A row the next one wraps on from is written out in full, so it wraps the same way.
      final len = wrapsOn ? width : _trimmedLength(line, width);
      for (var x = 0; x < len; x++) {
        final cp = line.getCodePoint(x);
        final placeholder = cp == 0 && (x > 0 ? line.getWidth(x - 1) == 2 : prevWide);
        if (placeholder) continue; // the right half of a wide character, redrawn by writing it
        sgr.set(line.getForeground(x), line.getBackground(x), line.getAttributes(x));
        out.writeCharCode(cp == 0 ? 0x20 : cp);
      }
      prevWide = width > 0 && line.getWidth(width - 1) == 2;
    }
  }

  static int _trimmedLength(BufferLine line, int width) {
    for (var x = width - 1; x >= 0; x--) {
      final cp = line.getCodePoint(x);
      if (cp != 0 && cp != 0x20) return x + 1;
      if (line.getBackground(x) != 0) return x + 1;
      if (line.getAttributes(x) & (CellAttr.inverse | CellAttr.underline | CellAttr.strikethrough) != 0) return x + 1;
    }
    return 0;
  }

  String _modes() {
    final t = term;
    final out = StringBuffer();
    if (t.insertMode) out.write('\x1b[4h');
    if (t.cursorKeysMode) out.write('\x1b[?1h');
    if (t.originMode) out.write('\x1b[?6h');
    if (!t.autoWrapMode) out.write('\x1b[?7l');
    if (!t.cursorVisibleMode) out.write('\x1b[?25l');
    if (t.appKeypadMode) out.write('\x1b=');
    switch (t.mouseMode) {
      case MouseMode.none:
        break;
      case MouseMode.clickOnly:
        out.write('\x1b[?9h');
      case MouseMode.upDownScroll:
        out.write('\x1b[?1000h');
      case MouseMode.upDownScrollDrag:
        out.write('\x1b[?1002h');
      case MouseMode.upDownScrollMove:
        out.write('\x1b[?1003h');
    }
    switch (t.mouseReportMode) {
      case MouseReportMode.normal:
        break;
      case MouseReportMode.utf:
        out.write('\x1b[?1005h');
      case MouseReportMode.sgr:
        out.write('\x1b[?1006h');
      case MouseReportMode.urxvt:
        out.write('\x1b[?1015h');
    }
    if (t.reportFocusMode) out.write('\x1b[?1004h');
    if (t.bracketedPasteMode) out.write('\x1b[?2004h');
    return out.toString();
  }

  // ---------------------------------------------------------------------------------------------
  // The laptop screens.

  /// The screen as styled runs, for the laptops on the desks: every row when [last] doesn't have
  /// one per row (a keyframe), else only the rows that changed since [last], which is updated.
  /// Null when nothing changed.
  ScreenFrame? snapshotScreen(List<String> last) {
    final buf = term.buffer;
    final full = last.length != rows;
    final lines = <int, List<Run>>{};
    var changed = false;
    if (last.length > rows) last.removeRange(rows, last.length);
    while (last.length < rows) {
      last.add('');
    }
    for (var y = 0; y < rows; y++) {
      final runs = <_RunBuilder>[];
      final line = buf.lines[buf.scrollBack + y];
      final width = line.length < cols ? line.length : cols;
      for (var x = 0; x < width; x++) {
        final cp = line.getCodePoint(x);
        if (cp == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
        final ch = cp == 0 ? ' ' : String.fromCharCode(cp);
        final fg = _runColor(line.getForeground(x));
        final bg = _runColor(line.getBackground(x));
        final a = line.getAttributes(x);
        final flags =
            (a & CellAttr.bold != 0 ? flagBold : 0) |
            (a & CellAttr.inverse != 0 ? flagInverse : 0) |
            (a & CellAttr.faint != 0 ? flagDim : 0);
        final cur = runs.isEmpty ? null : runs.last;
        if (cur != null && cur.fg == fg && cur.bg == bg && cur.flags == flags) {
          cur.text.write(ch);
        } else {
          runs.add(_RunBuilder(fg, bg, flags)..text.write(ch));
        }
      }
      // Trim trailing default-styled whitespace to keep frames small.
      final built = [for (final r in runs) Run(r.text.toString(), r.fg, r.bg, r.flags)];
      while (built.isNotEmpty) {
        final r = built.last;
        if (r.bg != -1 || r.flags & flagInverse != 0) break;
        final trimmed = r.text.replaceFirst(RegExp(r'\s+$'), '');
        if (trimmed.isNotEmpty) {
          built[built.length - 1] = Run(trimmed, r.fg, r.bg, r.flags);
          break;
        }
        built.removeLast();
      }
      final key = [for (final r in built) '${r.fg},${r.bg},${r.flags},${r.text}'].join('\x00');
      if (full || last[y] != key) {
        lines[y] = built;
        last[y] = key;
        changed = true;
      }
    }
    if (!changed) return null;
    return ScreenFrame(cols: cols, rows: rows, lines: lines, full: full, cursor: (buf.cursorX, buf.cursorY));
  }

  /// The text on screen, leaving out rows above buffer row [from] (of the active buffer).
  String screenText([int from = 0]) {
    final buf = term.buffer;
    final out = <String>[];
    final first = from - buf.scrollBack;
    for (var y = first < 0 ? 0 : first; y < rows; y++) {
      out.add(_lineText(buf.lines[buf.scrollBack + y], true));
    }
    return out.join('\n');
  }

  /// -1 default, 0..255 palette (the 16 named colors are its first 16), or [rgbFlag] | rgb.
  static int _runColor(int color) {
    final type = color & CellColor.typeMask;
    final value = color & CellColor.valueMask;
    if (type == CellColor.rgb) return rgbFlag | value;
    if (type == CellColor.named || type == CellColor.palette) return value;
    return -1;
  }
}

/// A frame for the laptop screens: [ScreenMsg] without the worker.
class ScreenFrame {
  const ScreenFrame({
    required this.cols,
    required this.rows,
    required this.lines,
    required this.full,
    required this.cursor,
  });

  final int cols;
  final int rows;
  final Map<int, List<Run>> lines;
  final bool full;
  final (int, int) cursor;

  ScreenMsg toMsg(String workerId) =>
      ScreenMsg(workerId: workerId, cols: cols, rows: rows, lines: lines, full: full, cursor: cursor);
}

class _RunBuilder {
  _RunBuilder(this.fg, this.bg, this.flags);
  final int fg;
  final int bg;
  final int flags;
  final text = StringBuffer();
}

/// A line in the buffer that follows it as it scrolls; [line] is -1 once it has scrolled off the top.
class TermMarker {
  TermMarker._(this._anchor);
  final CellAnchor _anchor;

  int get line => _anchor.attached ? _anchor.line!.index : -1;

  void dispose() => _anchor.dispose();
}

/// A buffer as the search reads it (see office_shared's search.dart).
class TermBuffer implements BufferLike {
  TermBuffer(this.buffer);
  final Buffer buffer;

  @override
  int get length => buffer.height;

  @override
  TermLine? getLine(int y) => y >= 0 && y < buffer.height ? TermLine(buffer.lines[y], buffer.viewWidth) : null;
}

class TermLine implements BufferLineLike {
  TermLine(this.line, this.cols);
  final BufferLine line;
  final int cols;

  @override
  bool get isWrapped => line.isWrapped;

  @override
  String translateToString([bool trimRight = false]) => _lineText(line, trimRight, cols);
}

/// A row's text like xterm.js's translateToString: an empty cell is a space, the right half of a
/// wide character nothing, and trimming drops the empty cells at the end (not written spaces).
String _lineText(BufferLine line, bool trimRight, [int? cols]) {
  var end = cols == null || line.length < cols ? line.length : cols;
  if (trimRight) {
    while (end > 0 && line.getCodePoint(end - 1) == 0 && !(end > 1 && line.getWidth(end - 2) == 2)) {
      end--;
    }
  }
  final out = StringBuffer();
  for (var x = 0; x < end; x++) {
    final cp = line.getCodePoint(x);
    if (cp == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
    out.writeCharCode(cp == 0 ? 0x20 : cp);
  }
  return out.toString();
}

/// Tracks the style in force while serializing, and writes SGR only when a cell's differs.
class _Sgr {
  _Sgr(this.out);
  final StringBuffer out;
  int _fg = 0, _bg = 0, _attrs = 0;

  void set(int fg, int bg, int attrs) {
    if (fg == _fg && bg == _bg && attrs == _attrs) return;
    out.write(codes(fg, bg, attrs));
    _fg = fg;
    _bg = bg;
    _attrs = attrs;
  }

  void reset() {
    if (_fg == 0 && _bg == 0 && _attrs == 0) return;
    out.write('\x1b[0m');
    _fg = _bg = _attrs = 0;
  }

  static String codes(int fg, int bg, int attrs) {
    final p = <Object>[0];
    if (attrs & CellAttr.bold != 0) p.add(1);
    if (attrs & CellAttr.faint != 0) p.add(2);
    if (attrs & CellAttr.italic != 0) p.add(3);
    if (attrs & CellAttr.underline != 0) p.add(4);
    if (attrs & CellAttr.blink != 0) p.add(5);
    if (attrs & CellAttr.inverse != 0) p.add(7);
    if (attrs & CellAttr.invisible != 0) p.add(8);
    if (attrs & CellAttr.strikethrough != 0) p.add(9);
    _color(fg, 30, 90, 38, p);
    _color(bg, 40, 100, 48, p);
    return '\x1b[${p.join(';')}m';
  }

  static void _color(int color, int base, int bright, int extended, List<Object> p) {
    final type = color & CellColor.typeMask;
    final v = color & CellColor.valueMask;
    if (type == CellColor.named && v < 8) {
      p.add(base + v);
    } else if (type == CellColor.named && v < 16) {
      p.add(bright + v - 8);
    } else if (type == CellColor.named || type == CellColor.palette) {
      p.add('$extended;5;$v');
    } else if (type == CellColor.rgb) {
      p.add('$extended;2;${(v >> 16) & 0xff};${(v >> 8) & 0xff};${v & 0xff}');
    }
  }
}
