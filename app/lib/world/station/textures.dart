// The pictures the station's surfaces are painted with: the hull's panelling, the deck's plating,
// the solar wings' cells, the stripes round its doors, and what its displays show. The planets
// outside are in planets.dart. A port of world/station/textures.ts (and the painters in shell.ts and
// airlock.ts).
//
// The toon shader samples its pictures as they are (no sRGB decode), so what's painted for a toon
// material is painted in linear colours (linColor); the displays and the stripes are unlit, painted
// as is.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../ui/theme.dart' show kFallback;
import '../office/geo.dart' show linColor;
import '../toon.dart' show hex;
import 'kit.dart' show seeded, shade;

typedef Painter = void Function(Canvas g);

Paint _fill(Color c) => Paint()..color = c;

/// The hull's panelling: big pale panels with seams between, a rivet at every corner, and the odd vent
/// or hatch. One tile is 3 m square (512 px).
Painter hullPanels(String color) => (g) {
  const s = 512.0;
  final rand = seeded(42);
  Color c(double k) => linColor(shade(color, k));
  g.drawRect(const Rect.fromLTWH(0, 0, s, s), _fill(c(0)));
  // Two rows of panels a tile, the lower row's joints half a panel along from the upper's.
  const rows = 2, cols = 2;
  for (var r = 0; r < rows; r++) {
    for (var col = 0; col < cols; col++) {
      const w = s / cols, h = s / rows;
      final x = col * w + (r.isOdd ? w / 2 : 0);
      final y = r * h;
      for (final dx in const [0.0, -s]) {
        g.drawRect(Rect.fromLTWH(x + dx + 3, y + 3, w - 6, h - 6), _fill(c((rand() - 0.5) * 0.035)));
        // A lighter edge along the top of each panel, a darker one along the bottom: it's pressed, not flat.
        g.drawRect(Rect.fromLTWH(x + dx + 3, y + 3, w - 6, 3), _fill(c(0.05)));
        g.drawRect(Rect.fromLTWH(x + dx + 3, y + h - 6, w - 6, 3), _fill(c(-0.07)));
      }
    }
  }
  final seam = _fill(c(-0.2));
  for (var r = 0; r < rows; r++) {
    g.drawRect(Rect.fromLTWH(0, r * (s / rows) - 1.5, s, 3), seam);
    for (var col = 0; col < cols; col++) {
      g.drawRect(
        Rect.fromLTWH(col * (s / cols) + (r.isOdd ? s / cols / 2 : 0) - 1.5, r * (s / rows), 3, s / rows),
        seam,
      );
    }
  }
  g.drawRect(const Rect.fromLTWH(0, s - 1.5, s, 3), seam);
  // Rivets down the joints.
  final rivet = _fill(c(-0.26));
  for (var r = 0; r < rows; r++) {
    for (var col = 0; col < cols; col++) {
      final x = col * (s / cols) + (r.isOdd ? s / cols / 2 : 0);
      for (var k = 1; k < 6; k++) {
        for (final side in const [-9.0, 9.0]) {
          g.drawCircle(Offset((x + side + s) % s, r * (s / rows) + k * (s / rows) / 6), 2.2, rivet);
        }
      }
    }
  }
  // A vent, and a little hatch with a label.
  final dark = _fill(c(-0.3));
  for (var i = 0; i < 6; i++) {
    g.drawRect(Rect.fromLTWH(60, 60 + i * 9.0, 70, 4), dark);
  }
  g.drawRect(
    const Rect.fromLTWH(340, 330, 90, 56),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = c(-0.22),
  );
  g.drawRect(const Rect.fromLTWH(346, 336, 22, 8), _fill(linColor('#d9822b')));
  g.drawRect(const Rect.fromLTWH(374, 337, 44, 3), dark);
  g.drawRect(const Rect.fromLTWH(374, 344, 30, 3), dark);
};

/// The deck's plating: dark square plates, a tread pressed into each, a bolt at every corner. One tile
/// is 2 m square (512 px).
Painter deckPlates(String color) => (g) {
  const s = 512.0;
  final rand = seeded(7);
  const n = 2;
  const w = s / n;
  Color c(double k) => linColor(shade(color, k));
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      g.drawRect(Rect.fromLTWH(i * w, j * w, w, w), _fill(c((rand() - 0.5) * 0.04)));
      // Tread: short bars, turned on every other plate.
      final tread = _fill(c(0.045));
      final turned = (i + j).isOdd;
      for (var a = 0; a < 6; a++) {
        for (var b = 0; b < 6; b++) {
          final x = i * w + 30 + a * 36 + (b.isOdd ? 12 : 0);
          final y = j * w + 30 + b * 36;
          g.drawRect(turned ? Rect.fromLTWH(x, y, 5, 18) : Rect.fromLTWH(x, y, 18, 5), tread);
        }
      }
      final bolt = _fill(c(-0.12));
      for (final (x, y) in const [(10.0, 10.0), (w - 10, 10.0), (10.0, w - 10), (w - 10, w - 10)]) {
        g.drawCircle(Offset(i * w + x, j * w + y), 3.5, bolt);
      }
    }
  }
  final seam = _fill(c(-0.14));
  for (var i = 0; i <= n; i++) {
    g.drawRect(Rect.fromLTWH(i * w - 2, 0, 4, s), seam);
    g.drawRect(Rect.fromLTWH(0, i * w - 2, s, 4), seam);
  }
};

/// The ceiling: panels between the ribs, darker than the walls. One tile is 3 m square (256 px).
Painter ceilingPanels(String color) => (g) {
  const s = 256.0;
  Color c(double k) => linColor(shade(color, k));
  g.drawRect(const Rect.fromLTWH(0, 0, s, s), _fill(c(0)));
  final dark = _fill(c(-0.08));
  g.drawRect(const Rect.fromLTWH(0, 0, s, 4), dark);
  g.drawRect(const Rect.fromLTWH(0, 0, 4, s), dark);
  g.drawRect(const Rect.fromLTWH(s / 2 - 2, 0, 4, s), dark);
  final light = _fill(c(0.04));
  g.drawRect(const Rect.fromLTWH(4, 4, s / 2 - 6, 3), light);
  g.drawRect(const Rect.fromLTWH(s / 2 + 2, 4, s / 2 - 6, 3), light);
};

/// Deep blue cells in a gold frame: a solar panel (256 px square, for a toon material).
void solarCells(Canvas g) {
  g.drawRect(const Rect.fromLTWH(0, 0, 256, 256), _fill(linColor('#c9a23a')));
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 4; j++) {
      g.drawRect(
        Rect.fromLTWH(6 + i * 41.3, 6 + j * 61.5, 38.5, 58.5),
        _fill(linColor((i + j).isOdd ? '#16306b' : '#1b3a80')),
      );
    }
  }
  final line = Paint()
    ..color = const Color.fromRGBO(150, 190, 255, 0.35)
    ..strokeWidth = 1;
  for (var y = 12.0; y < 256; y += 10) {
    g.drawLine(Offset(6, y), Offset(250, y), line);
  }
}

/// Stripes across a 256 by 32 strip, [a] and [b] (unlit: painted as is).
Painter stripes(String a, String b) => (g) {
  g.drawRect(const Rect.fromLTWH(0, 0, 256, 32), _fill(hex(a)));
  final p = _fill(hex(b));
  for (var x = -32.0; x < 256; x += 32) {
    g.drawPath(
      Path()
        ..moveTo(x, 32)
        ..lineTo(x + 16, 32)
        ..lineTo(x + 32, 0)
        ..lineTo(x + 16, 0)
        ..close(),
      p,
    );
  }
};

/// Yellow and black stripes: mind the door.
final Painter hazard = stripes('#f2c230', '#1b212b');

/// Red and white stripes: this door opens on nothing.
final Painter danger = stripes('#f4f4f4', '#d7263d');

const List<String> _readouts = [
  'ORBIT 412 KM',
  'O₂ 98.6%',
  'HULL OK',
  'PRESSURE 101 kPa',
  'SOLAR 84 kW',
  'CREW ABOARD',
  'AIRLOCK SEALED',
  'COMMS LINKED',
  'THRUST STANDBY',
  'GRAVITY 1.0 G',
];

/// A display's telemetry, [w] by [h] pixels: a graph, a row of bars, a dial and a few read-outs, in
/// [ink] on the dark. [seed] gives each display its own.
Painter telemetry(int seed, int w, int h, String ink) => (g) {
  final rand = seeded(seed * 97 + 13);
  final W = w.toDouble(), H = h.toDouble();
  final inkC = hex(ink);
  g.drawRect(Rect.fromLTWH(0, 0, W, H), _fill(hex('#071018')));
  final grid = Paint()
    ..color = const Color.fromRGBO(120, 190, 230, 0.13)
    ..strokeWidth = 1;
  for (var x = 0.0; x < W; x += 32) {
    g.drawLine(Offset(x, 0), Offset(x, H), grid);
  }
  for (var y = 0.0; y < H; y += 32) {
    g.drawLine(Offset(0, y), Offset(W, y), grid);
  }
  // A graph across the top half.
  final graph = Path();
  var y = H * 0.3;
  for (var x = 16.0; x < W * 0.62; x += 14) {
    y = math.min(H * 0.5, math.max(H * 0.12, y + (rand() - 0.5) * H * 0.14));
    if (x == 16) {
      graph.moveTo(x, y);
    } else {
      graph.lineTo(x, y);
    }
  }
  g.drawPath(
    graph,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = inkC,
  );
  // Bars along the bottom.
  for (var i = 0; i < 9; i++) {
    final bh = (0.15 + rand() * 0.25) * H;
    final c = i % 4 == 3 ? hex('#ffb347') : inkC;
    g.drawRect(Rect.fromLTWH(16 + i * (W * 0.065), H - 18 - bh, W * 0.045, bh), _fill(c.withValues(alpha: 0.85)));
  }
  // A dial, top right: an orbit with a blip on it.
  final cx = W * 0.82, cy = H * 0.32, r = math.min(W, H) * 0.2;
  final ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..color = inkC;
  g.drawCircle(Offset(cx, cy), r, ring);
  g.save();
  g.translate(cx, cy);
  g.rotate(-0.4);
  g.drawOval(
    Rect.fromCenter(center: Offset.zero, width: r * 2.5, height: r * 0.9),
    ring..color = inkC.withValues(alpha: 0.5),
  );
  g.restore();
  final a = rand() * math.pi * 2;
  g.drawCircle(
    Offset(
      cx + math.cos(a) * r * 1.25 * math.cos(-0.4) - math.sin(a) * r * 0.45 * math.sin(-0.4),
      cy + math.cos(a) * r * 1.25 * math.sin(-0.4) + math.sin(a) * r * 0.45 * math.cos(-0.4),
    ),
    6,
    _fill(hex('#ffb347')),
  );
  // Read-outs down the right.
  for (var i = 0; i < 3; i++) {
    final tp = TextPainter(
      text: TextSpan(
        text: _readouts[(rand() * _readouts.length).floor()],
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: kFallback,
          fontSize: (H * 0.075).roundToDouble(),
          fontWeight: FontWeight.w700,
          color: inkC,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(g, Offset(W * 0.64, H * (0.64 + i * 0.12) - tp.height / 2));
  }
};
