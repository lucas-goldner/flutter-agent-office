// Canvas-2D style drawing for the office's little screens (the boss's Minesweeper, the arcade
// cabinet): text lined up on its middle like `textBaseline = 'middle'`, cut short to fit, and
// rounded boxes. The same painter draws the texture on the monitor in the office and the screen
// you play on up close.

import 'package:flutter/painting.dart';

import 'theme.dart' show kFallback, kFont;

enum TextAlignX { left, center, right }

/// A hex colour ('#rrggbb') or 'rgba(r, g, b, a)' as a [Color].
Color css(String s) {
  if (s.startsWith('#')) return Color(0xFF000000 | int.parse(s.substring(1), radix: 16));
  final m = RegExp(r'rgba?\(([^)]*)\)').firstMatch(s);
  if (m == null) return const Color(0xFF000000);
  final p = m.group(1)!.split(',').map((v) => double.parse(v.trim())).toList();
  return Color.fromARGB(
    ((p.length > 3 ? p[3] : 1) * 255).round(),
    p[0].round(),
    p[1].round(),
    p[2].round(),
  );
}

class Pen {
  Pen(this.canvas);

  final Canvas canvas;

  TextStyle style(double size, {FontWeight weight = FontWeight.w400, Color color = const Color(0xFFFFFFFF), List<Shadow>? shadows}) =>
      TextStyle(
        fontFamily: kFont,
        fontFamilyFallback: kFallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1,
        shadows: shadows,
      );

  TextPainter layout(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();

  double measure(String text, TextStyle style) => layout(text, style).width;

  /// Draws [text] with its middle on [y], lined up on [x] by [align].
  void text(String text, double x, double y, TextStyle style, {TextAlignX align = TextAlignX.center}) {
    final tp = layout(text, style);
    final left = switch (align) {
      TextAlignX.left => x,
      TextAlignX.center => x - tp.width / 2,
      TextAlignX.right => x - tp.width,
    };
    tp.paint(canvas, Offset(left, y - tp.height / 2));
    tp.dispose();
  }

  /// [text], cut short with … to fit in [width] in [style].
  String fit(String text, double width, TextStyle style) {
    if (measure(text, style) <= width) return text;
    var s = text;
    while (s.length > 1 && measure('$s…', style) > width) {
      s = s.substring(0, s.length - 1);
    }
    return '$s…';
  }

  void rect(double x, double y, double w, double h, Color color) =>
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), Paint()..color = color);

  void roundRect(double x, double y, double w, double h, double r, Color color) =>
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)), Paint()..color = color);

  void strokeRect(double x, double y, double w, double h, Color color, double width) => canvas.drawRect(
    Rect.fromLTWH(x, y, w, h),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color,
  );

  void line(double x0, double y0, double x1, double y1, Color color, double width, {StrokeCap cap = StrokeCap.butt}) =>
      canvas.drawLine(
        Offset(x0, y0),
        Offset(x1, y1),
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = cap,
      );
}
