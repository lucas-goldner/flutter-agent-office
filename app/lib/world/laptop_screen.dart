// A worker's terminal painted onto a laptop screen: a port of paintScreen in world/laptop.ts.
// Shared by the 3D laptops (through a widget texture) and the HUD previews. Pure Dart and dart:ui,
// so it runs (and is tested) on the VM too.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../shared/protocol.dart';
import '../state/screen_state.dart';

/// The terminals' colours: the terminal window's xterm theme and the laptop screens both use it.
abstract final class TermTheme {
  static const background = Color(0xFF1E1F2E);
  static const foreground = Color(0xFFE6E6F0);
  static const cursor = Color(0xFFFFD166);
  static const selectionBackground = Color(0xFF44475A);
  static const black = Color(0xFF282A36);
  static const red = Color(0xFFFF5C7A);
  static const green = Color(0xFF7CF29A);
  static const yellow = Color(0xFFFFD166);
  static const blue = Color(0xFF6CB6FF);
  static const magenta = Color(0xFFD69CFF);
  static const cyan = Color(0xFF72DDF7);
  static const white = Color(0xFFE6E6F0);
  static const brightBlack = Color(0xFF6C7086);
  static const brightRed = Color(0xFFFF8FA3);
  static const brightGreen = Color(0xFFA6F4B8);
  static const brightYellow = Color(0xFFFFE29A);
  static const brightBlue = Color(0xFF9CCFFF);
  static const brightMagenta = Color(0xFFE5C1FF);
  static const brightCyan = Color(0xFFA5ECFB);
  static const brightWhite = Color(0xFFFFFFFF);
}

/// The bundled monospace face (JetBrains Mono), then DejaVu Sans Mono and two Noto symbol subsets
/// for the box drawing, spinners and marks TUIs use that it lacks. No system font on the web.
const kMonoFont = 'JetBrainsMono';
const kMonoFallback = ['DejaVuSansMono', 'NotoSansSymbols2Term', 'NotoSansSymbolsTerm'];

const _base16 = [
  TermTheme.black,
  TermTheme.red,
  TermTheme.green,
  TermTheme.yellow,
  TermTheme.blue,
  TermTheme.magenta,
  TermTheme.cyan,
  TermTheme.white,
  TermTheme.brightBlack,
  TermTheme.brightRed,
  TermTheme.brightGreen,
  TermTheme.brightYellow,
  TermTheme.brightBlue,
  TermTheme.brightMagenta,
  TermTheme.brightCyan,
  TermTheme.brightWhite,
];

/// The xterm 256-colour palette: the theme's 16, the 6x6x6 cube, then 24 greys.
final List<Color> termPalette = () {
  final p = [..._base16];
  const steps = [0, 95, 135, 175, 215, 255];
  for (var r = 0; r < 6; r++) {
    for (var g = 0; g < 6; g++) {
      for (var b = 0; b < 6; b++) {
        p.add(Color.fromARGB(255, steps[r], steps[g], steps[b]));
      }
    }
  }
  for (var i = 0; i < 24; i++) {
    final v = 8 + i * 10;
    p.add(Color.fromARGB(255, v, v, v));
  }
  return p;
}();

/// A run's colour: -1 is [fallback], 0..255 the palette, and [rgbFlag] | 0xRRGGBB true colour.
Color resolveColor(int c, Color fallback) {
  if (c < 0) return fallback;
  if (c >= rgbFlag) return Color(0xFF000000 | (c & 0xFFFFFF));
  return c < termPalette.length ? termPalette[c] : fallback;
}

/// What painting a run comes to: its foreground and (optional) background, after inverse.
({Color fg, Color? bg}) runColors(Run r) {
  var fg = resolveColor(r.fg, TermTheme.foreground);
  Color? bg = r.bg < 0 ? null : resolveColor(r.bg, TermTheme.background);
  if (r.flags & flagInverse != 0) {
    final tmp = fg;
    fg = bg ?? TermTheme.background;
    bg = tmp;
  }
  return (fg: fg, bg: bg);
}

int _runLen(List<Run>? runs) => runs == null ? 0 : runs.fold(0, (n, r) => n + r.text.runes.length);

const _charWidth = 0.6;
const _lineHeight = 1.25;
const _minZoomRows = 12;
const _minZoomCols = 56;

typedef ScreenWindow = ({int top, int rows, int cols, int first, int last});

/// The part of a terminal worth showing on a small laptop. Keep the usual recent rows, then add
/// surrounding rows for its natural character aspect ratio to use the available canvas.
ScreenWindow activeWindow(ScreenState s, double width, double height, int preferredRows) {
  var first = -1;
  var last = -1;
  var cols = _minZoomCols;
  for (var y = 0; y < s.rows; y++) {
    final runs = s.lines[y];
    if (runs == null || !runs.any((r) => r.text.trim().isNotEmpty || r.bg != -1)) continue;
    if (first < 0) first = y;
    last = y;
    cols = math.max(cols, _runLen(runs));
  }
  cols = math.min(s.cols, cols);
  // A natural terminal cell is about .6 characters wide by 1.25 characters high. Add enough
  // surrounding rows for a wide PTY to use the laptop's height without vertically stretching glyphs.
  final aspectRows = ((height * _charWidth * cols) / (width * _lineHeight)).ceil();
  final rows = math.min(s.rows, math.max(_minZoomRows, math.max(preferredRows, aspectRows)));
  final top = last < 0 ? 0 : math.max(0, math.min(last + 1 - rows, s.rows - rows));
  final contentFirst = first < 0 ? top : math.max(top, first);
  final contentLast = last < 0 ? top : math.min(top + rows - 1, last);
  return (top: top, rows: rows, cols: cols, first: contentFirst, last: contentLast);
}

/// One drawing step of a screen, as [screenOps] lays them out: a filled rect, or a run of text
/// whose top-left is at `at`.
sealed class ScreenOp {
  const ScreenOp();
}

class FillOp extends ScreenOp {
  const FillOp(this.rect, this.color);
  final Rect rect;
  final Color color;
}

class TextOp extends ScreenOp {
  const TextOp(this.text, this.at, this.fontSize, this.color, {this.bold = false, this.alpha = 1, this.center = false});
  final String text;

  /// Top-left of the text box, or its centre when [center].
  final Offset at;
  final double fontSize;
  final Color color;
  final bool bold;
  final double alpha;
  final bool center;
}

/// The screen laid out as fills and texts, in paint order (see [paintScreen]).
List<ScreenOp> screenOps(Size size, ScreenState? s, {String? placeholder, int zoomRows = 0}) {
  final w = size.width;
  final h = size.height;
  final ops = <ScreenOp>[FillOp(Offset.zero & size, TermTheme.background)];
  if (s == null) {
    ops.add(TextOp(placeholder ?? 'booting…', Offset(w / 2, h / 2), (h / 12).roundToDouble(), TermTheme.brightBlack, bold: true, center: true));
    return ops;
  }
  final pad = w * 0.02;
  final win = zoomRows > 0 ? activeWindow(s, w - pad * 2, h - pad * 2, zoomRows) : (top: 0, rows: s.rows, cols: s.cols, first: 0, last: s.rows - 1);
  final cellW = (w - pad * 2) / win.cols;
  final cellH = (h - pad * 2) / win.rows;
  final fontSize = math.max(4.0, math.min(cellW / _charWidth, cellH / _lineHeight));
  final charW = fontSize * _charWidth;
  final lineH = fontSize * _lineHeight;
  final gridW = win.cols * charW;
  final contentRows = math.max(1, win.last - win.first + 1);
  final gridH = contentRows * lineH;
  final left = pad + (w - pad * 2 - gridW) / 2;
  final top = pad + (h - pad * 2 - gridH) / 2;
  for (var y = 0; y < win.rows; y++) {
    final runs = s.lines[win.top + y];
    if (runs == null) continue;
    var x = 0;
    final py = top + (win.top + y - win.first) * lineH;
    for (final r in runs) {
      final len = r.text.runes.length;
      final (:fg, :bg) = runColors(r);
      final px = left + x * charW;
      if (bg != null) ops.add(FillOp(Rect.fromLTWH(px, py, len * charW + 0.5, lineH + 0.5), bg));
      if (r.text.trim().isNotEmpty) {
        ops.add(TextOp(r.text, Offset(px, py + (lineH - fontSize) / 2), fontSize, fg, bold: r.bold, alpha: r.dim ? 0.55 : 1));
      }
      x += len;
    }
  }
  return ops;
}

/// Paints a terminal screen onto a canvas. [zoomRows] > 0 zooms onto the active part, as the 3D
/// laptops do (22); 0 shows the whole screen.
void paintScreen(Canvas c, Size size, ScreenState? s, {String? placeholder, int zoomRows = 0}) {
  for (final op in screenOps(size, s, placeholder: placeholder, zoomRows: zoomRows)) {
    switch (op) {
      case FillOp(:final rect, :final color):
        c.drawRect(rect, Paint()..color = color);
      case TextOp():
        _drawText(c, op);
    }
  }
}

void _drawText(Canvas c, TextOp op) {
  final style = ui.TextStyle(
    color: op.alpha < 1 ? op.color.withValues(alpha: op.alpha) : op.color,
    fontFamily: kMonoFont,
    fontFamilyFallback: kMonoFallback,
    fontSize: op.fontSize,
    fontWeight: op.bold ? FontWeight.w700 : FontWeight.w400,
    height: 1,
  );
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(maxLines: 1))
    ..pushStyle(style)
    ..addText(op.text);
  // A wide finite box: left-aligned text in an infinite one lays out fine, centred text doesn't.
  final p = b.build()..layout(const ui.ParagraphConstraints(width: 1e5));
  final at = op.center ? op.at - Offset(p.maxIntrinsicWidth / 2, p.height / 2) : op.at;
  c.drawParagraph(p, at);
}

/// The canvas size of a laptop screen (its texture in the 3D office).
const kLaptopScreenSize = Size(1024, 680);

/// A laptop screen as a widget, for the lead's 3D surface or a HUD preview. Repaints when the
/// screen's version (or the placeholder) changes.
class LaptopScreen extends StatelessWidget {
  const LaptopScreen({super.key, this.screen, this.placeholder, this.zoomRows = 22});

  final ScreenState? screen;
  final String? placeholder;
  final int zoomRows;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: kLaptopScreenSize,
      painter: LaptopScreenPainter(screen, placeholder: placeholder, zoomRows: zoomRows),
    ),
  );
}

class LaptopScreenPainter extends CustomPainter {
  LaptopScreenPainter(this.screen, {this.placeholder, this.zoomRows = 22}) : version = screen?.version ?? -1;

  final ScreenState? screen;
  final String? placeholder;
  final int zoomRows;

  /// The screen's version when this painter was made: ScreenState changes in place.
  final int version;

  @override
  void paint(Canvas canvas, Size size) => paintScreen(canvas, size, screen, placeholder: placeholder, zoomRows: zoomRows);

  @override
  bool shouldRepaint(LaptopScreenPainter old) =>
      !identical(old.screen, screen) || old.version != version || old.placeholder != placeholder || old.zoomRows != zoomRows;
}
