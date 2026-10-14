// The castle's pictures: stone, flagstones and boards to tile over its walls, floors and roof,
// stained glass for its windows, and the banners, painted in a floor's colors. A port of
// world/castle/textures.ts. The stones keep their own LCG (seeded), not the shared rng, so every
// browser sees the same ones.
//
// The toon shader samples its pictures as they are (no sRGB decode), so what's painted for a toon
// material is painted in linear colours (linColor); the glass is unlit, painted as is.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart' show Texture2D;
import 'package:office_shared/floors.dart';

import '../../ui/theme.dart' show kFallback, kFont;
import '../office/geo.dart' show linColor;
import '../office/parts.dart' show canvasTexture;
import '../toon.dart' show hex;
import 'kit.dart' show seeded, shade;

typedef Painter = void Function(Canvas g);

Paint _fill(Color c) => Paint()..color = c;

/// Courses of dressed stone, with mortar between. One tile is 4 m wide and 2 m high (512 by 256).
Painter ashlar(String color, int seed) => (g) {
  final rand = seeded(seed);
  g.drawRect(const Rect.fromLTWH(0, 0, 512, 256), _fill(linColor(shade(color, -0.12))));
  for (var row = 0; row < 4; row++) {
    final off = row.isOdd ? 64.0 : 0.0;
    for (var col = -1; col < 5; col++) {
      final x = col * 128 + off;
      g.drawRect(Rect.fromLTWH(x + 3, row * 64 + 3, 122, 58), _fill(linColor(shade(color, (rand() - 0.5) * 0.09))));
      g.drawRect(Rect.fromLTWH(x + 3, row * 64 + 3, 122, 6), _fill(const Color(0x0FFFFFFF)));
    }
  }
};

/// Big worn flagstones, 2 m a tile (512 square for 4 m).
Painter flagstones(String color) => (g) {
  final rand = seeded(7);
  g.drawRect(const Rect.fromLTWH(0, 0, 512, 512), _fill(linColor(shade(color, -0.14))));
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      final off = r.isOdd ? 64.0 : 0.0;
      g.drawRect(
        Rect.fromLTWH(c * 128 + off + 4, r * 128 + 4, 120, 120),
        _fill(linColor(shade(color, (rand() - 0.5) * 0.1))),
      );
      if (off > 0) {
        g.drawRect(Rect.fromLTWH(-64 + 4, r * 128 + 4, 120, 120), _fill(linColor(shade(color, (rand() - 0.5) * 0.1))));
      }
    }
  }
};

/// Dark boards, for the roof's underside (256 square).
Painter boards(String color) => (g) {
  g.drawRect(const Rect.fromLTWH(0, 0, 256, 256), _fill(linColor(shade(color, -0.08))));
  final rand = seeded(3);
  for (var i = 0; i < 8; i++) {
    g.drawRect(Rect.fromLTWH(i * 32 + 1, 0, 30, 256), _fill(linColor(shade(color, (rand() - 0.5) * 0.08))));
  }
};

const List<String> _glass = ['#b3261e', '#1f4fb4', '#d9a520', '#2e8b57', '#6a2c91', '#d8631c', '#1b7a8c'];

/// Stained glass: a diamond lattice of colored panes in lead, and a bright roundel in the middle.
Painter stainedGlass(int seed, double w, double h) => (g) {
  final rand = seeded(seed);
  g.drawRect(Rect.fromLTWH(0, 0, w, h), _fill(hex('#1b1612')));
  final cell = w / 5;
  for (var y = -cell; y < h + cell; y += cell / 2) {
    for (var x = -cell; x < w + cell; x += cell) {
      final cx = x + ((y / (cell / 2)).round() % 2) * cell / 2;
      final c = hex(_glass[(rand() * _glass.length).floor()]);
      final alpha = 0.75 + rand() * 0.25;
      final path = Path()
        ..moveTo(cx, y - cell / 2 + 3)
        ..lineTo(cx + cell / 2 - 3, y)
        ..lineTo(cx, y + cell / 2 - 3)
        ..lineTo(cx - cell / 2 + 3, y)
        ..close();
      g.drawPath(path, _fill(c.withValues(alpha: alpha)));
    }
  }
  // A roundel: a gold ring, a star in it.
  final r = w * 0.3;
  final ink = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 8
    ..color = hex('#1b1612');
  final centre = Offset(w / 2, h * 0.42);
  g.drawCircle(centre, r, _fill(hex('#f2d06b')));
  g.drawCircle(centre, r, ink);
  final star = Path();
  for (var i = 0; i < 10; i++) {
    final a = i / 10 * math.pi * 2 - math.pi / 2;
    final rr = i.isOdd ? r * 0.42 : r * 0.85;
    final p = Offset(w / 2 + math.cos(a) * rr, h * 0.42 + math.sin(a) * rr);
    i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
  }
  star.close();
  g.drawPath(star, _fill(hex(_glass[(rand() * 3).floor()])));
  g.drawPath(star, ink);
};

/// A rose window: petals of glass round a gold heart, spokes of stone between them (512 square).
void roseGlass(Canvas g) {
  const s = 512.0;
  const c = s / 2;
  g.drawRect(const Rect.fromLTWH(0, 0, s, s), _fill(hex('#1b1612')));
  final rand = seeded(11);
  for (var ring = 3; ring >= 1; ring--) {
    final n = ring * 8;
    for (var i = 0; i < n; i++) {
      final color = hex(_glass[(i + ring) % _glass.length]).withValues(alpha: 0.8 + rand() * 0.2);
      final rr = ring / 3 * c - 6;
      final a0 = i / n * math.pi * 2 + 0.03, a1 = (i + 1) / n * math.pi * 2 - 0.03;
      final path = Path()
        ..moveTo(c, c)
        ..arcTo(Rect.fromCircle(center: const Offset(c, c), radius: rr), a0, a1 - a0, false)
        ..close();
      g.drawPath(path, _fill(color));
    }
  }
  final ink = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 10
    ..color = hex('#1b1612');
  for (final r in [c / 3, 2 * c / 3]) {
    g.drawCircle(const Offset(c, c), r, ink);
  }
  g.drawCircle(const Offset(c, c), c / 6, _fill(hex('#f2d06b')));
  g.drawCircle(const Offset(c, c), c / 6, ink);
}

/// A banner: its field in [color] with a gold border, a crown, and a word or two at the foot.
void paintBanner(Canvas g, double w, double h, String color, [String? motto]) {
  g.drawRect(Rect.fromLTWH(0, 0, w, h), _fill(linColor(color)));
  final stripe = _fill(linColor(shade(color, -0.12)));
  for (var x = 0.0; x < w; x += 24) {
    g.drawRect(Rect.fromLTWH(x, 0, 10, h), stripe);
  }
  g.drawRect(
    Rect.fromLTWH(w * 0.06, w * 0.06, w * 0.88, h - w * 0.12),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.05
      ..color = linColor('#e8b93a'),
  );
  // The crown.
  final cx = w / 2, cy = h * 0.3, cw = w * 0.52;
  final gold = _fill(linColor('#f2c94c'));
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w * 0.015
    ..color = linColor('#6b4a10');
  final crown = Path()
    ..moveTo(cx - cw / 2, cy + cw * 0.35)
    ..lineTo(cx - cw / 2, cy - cw * 0.15)
    ..lineTo(cx - cw / 4, cy + cw * 0.08)
    ..lineTo(cx, cy - cw * 0.32)
    ..lineTo(cx + cw / 4, cy + cw * 0.08)
    ..lineTo(cx + cw / 2, cy - cw * 0.15)
    ..lineTo(cx + cw / 2, cy + cw * 0.35)
    ..close();
  g.drawPath(crown, gold);
  g.drawPath(crown, edge);
  for (final dx in [-cw / 2, 0.0, cw / 2]) {
    final at = Offset(cx + dx, cy - (dx != 0 ? cw * 0.19 : cw * 0.36));
    g.drawCircle(at, w * 0.035, gold);
    g.drawCircle(at, w * 0.035, edge);
  }
  if (motto != null && motto.isNotEmpty) {
    var size = w * 0.13;
    TextPainter text() => TextPainter(
      text: TextSpan(
        text: motto,
        style: TextStyle(
          fontFamily: kFont,
          fontFamilyFallback: kFallback,
          fontSize: size,
          fontWeight: FontWeight.w900,
          color: linColor('#f7e7b4'),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var tp = text();
    while (tp.width > w * 0.8 && size > 10) {
      size *= 0.9;
      tp = text();
    }
    tp.paint(g, Offset(cx - tp.width / 2, h * 0.62 - tp.height / 2));
  }
}

/// A floor's colors as heraldry: its trim's hue, deep and rich, for the banners and the shields.
String heraldry(FloorPalette p) {
  final hsl = HSLColor.fromColor(hex(p.trim));
  final c = HSLColor.fromAHSL(1, hsl.hue, 0.62, 0.3).toColor();
  int byte(double v) => (v * 255).round().clamp(0, 255);
  return '#${[byte(c.r), byte(c.g), byte(c.b)].map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
}

/// [paint] at [w] by [h] pixels, as a texture.
Future<Texture2D> painted(int w, int h, Painter paint) => canvasTexture(w, h, paint);
