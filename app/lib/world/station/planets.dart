// The pictures of what's outside the station's windows (see space.dart): the Earth by day and by night
// and its clouds, the Moon, a ringed giant and a red planet, the stars and the Sun's glare. They're
// drawn the way a map of the world is, longitude across and latitude down. A port of
// world/station/planets.ts. They're for unlit materials, so they're painted as is (in sRGB).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../toon.dart' show hex;
import 'kit.dart' show seeded;
import 'textures.dart' show Painter;

typedef _Coast = List<(double, double)>;

/// The world's coastlines, roughly: enough to know it by from orbit.
const List<_Coast> _lands = [
  // North and Central America, from Alaska round by the Arctic coast, down the east, and back up the west.
  [
    (-165, 62),
    (-162, 68),
    (-156, 71),
    (-140, 70),
    (-120, 70),
    (-100, 69),
    (-90, 70),
    (-82, 66),
    (-78, 62),
    (-70, 60),
    (-64, 60),
    (-56, 53),
    (-64, 48),
    (-66, 44),
    (-70, 42),
    (-75, 38),
    (-77, 34),
    (-81, 31),
    (-80, 26),
    (-82, 29),
    (-85, 30),
    (-90, 29),
    (-94, 29),
    (-97, 26),
    (-97, 21),
    (-94, 18),
    (-90, 19),
    (-87, 21),
    (-88, 16),
    (-84, 15),
    (-83, 11),
    (-80, 9),
    (-78, 8),
    (-80, 7),
    (-84, 9),
    (-87, 13),
    (-92, 15),
    (-96, 16),
    (-102, 18),
    (-106, 22),
    (-110, 26),
    (-113, 30),
    (-117, 33),
    (-121, 36),
    (-124, 41),
    (-124, 47),
    (-128, 51),
    (-134, 57),
    (-141, 60),
    (-150, 60),
    (-155, 58),
    (-160, 56),
    (-164, 58),
  ],
  // Greenland.
  [(-52, 82), (-30, 83), (-20, 78), (-22, 70), (-40, 65), (-44, 60), (-52, 65), (-55, 70), (-60, 76)],
  // South America.
  [
    (-78, 8),
    (-72, 12),
    (-62, 10),
    (-52, 5),
    (-50, 0),
    (-44, -2),
    (-35, -6),
    (-37, -12),
    (-39, -18),
    (-42, -23),
    (-48, -27),
    (-53, -33),
    (-57, -37),
    (-62, -40),
    (-65, -46),
    (-68, -52),
    (-72, -53),
    (-74, -46),
    (-73, -38),
    (-71, -30),
    (-70, -20),
    (-76, -14),
    (-81, -6),
    (-80, 0),
    (-78, 3),
  ],
  // Africa, and Madagascar.
  [
    (-17, 15),
    (-16, 22),
    (-10, 29),
    (-6, 35),
    (3, 37),
    (10, 37),
    (11, 33),
    (20, 32),
    (25, 32),
    (32, 31),
    (35, 24),
    (38, 18),
    (43, 12),
    (51, 11),
    (48, 4),
    (42, -2),
    (40, -10),
    (40, -16),
    (35, -22),
    (33, -27),
    (28, -33),
    (20, -35),
    (17, -30),
    (14, -22),
    (12, -14),
    (13, -6),
    (9, 0),
    (9, 4),
    (4, 6),
    (-4, 5),
    (-8, 4),
    (-13, 8),
    (-17, 12),
  ],
  [(49, -12), (50, -16), (47, -25), (44, -22), (44, -16)],
  // Europe and Asia, from Iberia round by the Arctic to the Pacific, and back along the south.
  [
    (-9, 37),
    (-9, 43),
    (-1, 44),
    (-4, 48),
    (3, 51),
    (8, 54),
    (12, 56),
    (5, 59),
    (6, 62),
    (14, 68),
    (25, 71),
    (40, 67),
    (45, 68),
    (60, 69),
    (70, 73),
    (90, 76),
    (105, 78),
    (112, 74),
    (130, 72),
    (150, 71),
    (170, 70),
    (180, 66),
    (172, 61),
    (163, 59),
    (156, 51),
    (142, 54),
    (135, 54),
    (140, 48),
    (130, 42),
    (128, 36),
    (126, 35),
    (122, 39),
    (118, 38),
    (121, 31),
    (119, 25),
    (110, 21),
    (108, 17),
    (109, 11),
    (105, 9),
    (100, 13),
    (99, 8),
    (103, 2),
    (101, 3),
    (98, 8),
    (98, 15),
    (94, 17),
    (91, 22),
    (87, 21),
    (80, 15),
    (80, 9),
    (77, 8),
    (73, 17),
    (72, 21),
    (67, 24),
    (61, 25),
    (57, 26),
    (56, 27),
    (51, 28),
    (48, 30),
    (51, 25),
    (56, 24),
    (59, 22),
    (55, 17),
    (45, 13),
    (43, 13),
    (39, 21),
    (35, 28),
    (35, 32),
    (36, 36),
    (30, 36),
    (27, 37),
    (26, 40),
    (29, 41),
    (23, 40),
    (23, 37),
    (21, 39),
    (19, 42),
    (13, 45),
    (12, 44),
    (18, 40),
    (16, 38),
    (12, 42),
    (9, 44),
    (3, 43),
    (0, 39),
    (-2, 37),
    (-5, 36),
  ],
  // Britain, Japan, and the islands between Asia and Australia.
  [(-5, 50), (1, 51), (0, 54), (-2, 56), (-3, 58), (-6, 57), (-5, 54), (-3, 53), (-5, 52)],
  [(130, 32), (135, 34), (140, 36), (141, 40), (142, 44), (144, 43), (141, 37), (136, 33)],
  [(95, 5), (104, -5), (106, -6), (100, 2)],
  [(109, 1), (114, 5), (118, 4), (117, -3), (111, -3)],
  [(131, -1), (141, -3), (150, -7), (146, -9), (138, -8), (132, -4)],
  // Australia and New Zealand.
  [
    (114, -22),
    (122, -18),
    (129, -15),
    (131, -12),
    (136, -12),
    (137, -16),
    (141, -14),
    (142, -11),
    (146, -19),
    (153, -26),
    (153, -31),
    (150, -37),
    (144, -39),
    (138, -35),
    (135, -35),
    (131, -32),
    (124, -33),
    (115, -34),
    (114, -28),
  ],
  [(173, -35), (178, -38), (175, -41), (168, -46), (167, -45), (172, -41)],
];

/// Where it's dry: the Sahara, Arabia, the middle of Asia, the south-west of North America, Australia's
/// middle, the Kalahari, Patagonia. (lon, lat, rx, ry)
const List<(double, double, double, double)> _deserts = [
  (8, 23, 28, 8),
  (46, 23, 9, 7),
  (62, 40, 14, 6),
  (100, 41, 14, 5),
  (-110, 33, 8, 6),
  (132, -25, 13, 6),
  (20, -24, 6, 5),
  (-68, -42, 4, 8),
];

/// Where the lights are thickest at night. (lon, lat, rx, ry, how many)
const List<(double, double, double, double, int)> _cities = [
  (-82, 39, 14, 9, 150),
  (-118, 36, 5, 5, 40),
  (10, 49, 16, 8, 190),
  (78, 22, 9, 10, 130),
  (114, 31, 9, 10, 170),
  (138, 36, 4, 4, 60),
  (-47, -22, 6, 5, 50),
  (31, 30, 3, 4, 30),
  (28, -27, 4, 3, 22),
  (107, -6, 5, 3, 30),
  (147, -35, 5, 4, 26),
  (-99, 20, 4, 3, 26),
  (37, 55, 6, 3, 30),
  (5, 8, 6, 3, 28),
];

Paint _fill(Color c) => Paint()..color = c;

Color _rgba(num r, num g, num b, double a) =>
    Color.fromRGBO(r.round().clamp(0, 255), g.round().clamp(0, 255), b.round().clamp(0, 255), a.clamp(0.0, 1.0));

/// The world's land on a [w] by [h] map.
Path _land(double w, double h) {
  final p = Path();
  for (final coast in _lands) {
    for (var i = 0; i < coast.length; i++) {
      final (lon, lat) = coast[i];
      final x = (lon + 180) / 360 * w, y = (90 - lat) / 180 * h;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    p.close();
  }
  return p;
}

/// An ice cap's ragged edge across a [w] wide map, round latitude [lat].
void _ice(Canvas g, double w, double h, double lat, bool south, double Function() rand, Color color) {
  final p = Path()..moveTo(0, south ? h : 0);
  for (var x = 0.0; x <= w; x += w / 48) {
    final wob = math.sin(x / w * math.pi * 6) * 2.5 + (rand() - 0.5) * 3;
    p.lineTo(x, (90 - (south ? -1 : 1) * (lat + wob)) / 180 * h);
  }
  p
    ..lineTo(w, south ? h : 0)
    ..close();
  g.drawPath(p, _fill(color));
}

void _ellipse(Canvas g, double x, double y, double rx, double ry, double rot, Paint paint) {
  g.save();
  g.translate(x, y);
  g.rotate(rot);
  g.drawOval(Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2), paint);
  g.restore();
}

/// The Earth by day: blue seas, green and tan land, white at the poles.
Painter earthDay(int wi, int hi) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(11);
  g.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, h),
        [hex('#0b2f6b'), hex('#1458b8'), hex('#0b2f6b')],
        [0, 0.5, 1],
      ),
  );
  // Shallows round the coasts.
  final land = _land(w, h);
  g.drawPath(
    land,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = w / 230
      ..color = const Color.fromRGBO(90, 190, 235, 0.55),
  );
  // The land, greener toward the equator, greyer and then white toward the poles.
  const stops = [
    (90, '#eef4f8'),
    (76, '#dfe8ea'),
    (68, '#8f9f7c'),
    (55, '#3f7d46'),
    (38, '#62a34b'),
    (24, '#8fae55'),
    (8, '#2f8c3e'),
    (-8, '#2f8c3e'),
    (-24, '#8fae55'),
    (-40, '#62a34b'),
    (-56, '#8f9f7c'),
  ];
  g.drawPath(
    land,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, h),
        [for (final (_, c) in stops) hex(c)],
        [for (final (lat, _) in stops) (90 - lat) / 180],
      ),
  );
  // Only over the land from here on: the deserts, and a mottle of darker and lighter ground.
  g.save();
  g.clipPath(land);
  for (final (lon, lat, rx, ry) in _deserts) {
    final big = math.max(rx, ry);
    final r = big / 360 * w;
    g.save();
    g.translate((lon + 180) / 360 * w, (90 - lat) / 180 * h);
    // A round patch, squashed to the desert's shape.
    g.scale(rx / big, ry / big);
    g.drawRect(
      Rect.fromLTWH(-r, -r, 2 * r, 2 * r),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          r,
          [
            const Color.fromRGBO(214, 186, 120, 0.95),
            const Color.fromRGBO(206, 176, 112, 0.7),
            const Color.fromRGBO(206, 176, 112, 0),
          ],
          [0, 0.7, 1],
        ),
    );
    g.restore();
  }
  for (var i = 0; i < 900; i++) {
    final c = rand() < 0.5 ? const Color.fromRGBO(20, 60, 30, 0.16) : const Color.fromRGBO(190, 210, 140, 0.13);
    _ellipse(
      g,
      rand() * w,
      rand() * h,
      (2 + rand() * 9) * (w / 1024),
      (1.5 + rand() * 5) * (w / 1024),
      rand() * 3,
      _fill(c),
    );
  }
  g.restore();
  // The ice: Antarctica, and the Arctic's floes.
  _ice(g, w, h, 70, true, rand, hex('#f2f6fa'));
  _ice(g, w, h, 80, false, rand, const Color.fromRGBO(240, 246, 250, 0.85));
};

/// The Earth by night: the lights of its cities, where there's land, on nothing (see-through), so
/// they can go over the day side's picture.
Painter earthNight(int wi, int hi) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(23);
  g.save();
  g.clipPath(_land(w, h));
  void dot(double lon, double lat, double size, double alpha) {
    final c = _rgba(255, 190 + (rand() * 50).floor(), 110 + (rand() * 60).floor(), alpha);
    g.drawCircle(Offset((lon + 180) / 360 * w, (90 - lat) / 180 * h), size * (w / 1024), _fill(c));
  }

  // A scatter everywhere people live, and thick where the cities are.
  for (var i = 0; i < 1100; i++) {
    dot(-180 + rand() * 360, -55 + rand() * 120, 0.5 + rand() * 0.9, 0.25 + rand() * 0.4);
  }
  for (final (lon, lat, rx, ry, n) in _cities) {
    for (var i = 0; i < n; i++) {
      final a = rand() * math.pi * 2;
      final r = math.sqrt(rand());
      dot(lon + math.cos(a) * r * rx, lat + math.sin(a) * r * ry, 0.6 + rand() * 1.3, 0.5 + rand() * 0.5);
    }
  }
  g.restore();
};

/// JavaScript's Math.imul: a 32-bit multiply, the same on the web as natively.
int _imul(int a, int b) {
  final ah = (a >> 16) & 0xffff, al = a & 0xffff;
  final bh = (b >> 16) & 0xffff, bl = b & 0xffff;
  return (al * bl + ((((ah * bl + al * bh) & 0xffff) << 16))) & 0xffffffff;
}

/// Smooth noise in space, [seed]'s own: 0–1 at (x, y, z), a few octaves of it summed.
double Function(double x, double y, double z) _fbm(int seed) {
  double hash(int x, int y, int z) {
    var n = (_imul(x, 374761393) ^ _imul(y, 668265263) ^ _imul(z, 1013904223) ^ seed) & 0xffffffff;
    n = _imul(n ^ (n >>> 13), 1274126177);
    return ((n ^ (n >>> 16)) & 0xffffffff) / 4294967296;
  }

  double ease(double t) => t * t * (3 - 2 * t);
  double mix(double a, double b, double t) => a + (b - a) * t;
  double noise(double x, double y, double z) {
    final xi = x.floor(), yi = y.floor(), zi = z.floor();
    final u = ease(x - xi), v = ease(y - yi), s = ease(z - zi);
    double at(int dz) => mix(
      mix(hash(xi, yi, zi + dz), hash(xi + 1, yi, zi + dz), u),
      mix(hash(xi, yi + 1, zi + dz), hash(xi + 1, yi + 1, zi + dz), u),
      v,
    );
    return mix(at(0), at(1), s);
  }

  return (x, y, z) {
    var sum = 0.0, amp = 0.5;
    for (var o = 0; o < 4; o++) {
      sum += noise(x, y, z) * amp;
      x *= 2.03;
      y *= 2.03;
      z *= 2.03;
      amp *= 0.5;
    }
    return sum / 0.9375;
  };
}

/// The Earth's clouds, white where there are any (and see-through where there aren't): swirls, drawn
/// on the globe itself so they meet round the back and at the poles.
Future<ui.Image> earthClouds(int w, int h) {
  final n = _fbm(5), warp = _fbm(9);
  final px = Uint8List(w * h * 4);
  for (var j = 0; j < h; j++) {
    final lat = (0.5 - (j + 0.5) / h) * math.pi;
    final cl = math.cos(lat), y = math.sin(lat);
    for (var i = 0; i < w; i++) {
      final lon = (i + 0.5) / w * math.pi * 2;
      final x = cl * math.cos(lon), z = cl * math.sin(lon);
      // Stretched along the latitudes, and pulled about a little, the way weather is.
      final k = warp(x * 2 + 7, y * 2, z * 2) - 0.5;
      final v = n(x * 3.1 + k * 1.6, y * 6.2 + k * 0.8, z * 3.1 - k * 1.6);
      final c = ((v - 0.5) / 0.22).clamp(0.0, 1.0);
      final p = (j * w + i) * 4;
      // Premultiplied, as the engine takes its pixels: white, as see-through as there's little cloud.
      px[p] = px[p + 1] = px[p + 2] = px[p + 3] = (c * c * (3 - 2 * c) * 255).round();
    }
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// The Earth by day with its [clouds] over it, and their shadows on the ground under them.
Painter earthWithClouds(int w, int h, ui.Image clouds) => (g) {
  earthDay(w, h)(g);
  final src = Rect.fromLTWH(0, 0, clouds.width.toDouble(), clouds.height.toDouble());
  final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  g.drawImageRect(
    clouds,
    src,
    dst.shift(Offset(w * 0.004, h * 0.003)),
    Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = const ColorFilter.mode(Color.fromRGBO(0, 0, 0, 0.3), BlendMode.srcIn),
  );
  g.drawImageRect(
    clouds,
    src,
    dst,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = const Color.fromRGBO(255, 255, 255, 0.92),
  );
};

/// The Moon: pale grey, its dark seas and its craters.
Painter moonFace(int wi, int hi) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(31);
  g.drawRect(Rect.fromLTWH(0, 0, w, h), _fill(hex('#c9c8c2')));
  for (var i = 0; i < 14; i++) {
    _ellipse(
      g,
      rand() * w,
      h * (0.25 + rand() * 0.5),
      (0.03 + rand() * 0.07) * w,
      (0.04 + rand() * 0.08) * h,
      rand() * 3,
      _fill(const Color.fromRGBO(120, 122, 128, 0.5)),
    );
  }
  for (var i = 0; i < 70; i++) {
    final x = rand() * w, y = rand() * h, r = (0.004 + rand() * 0.014) * w;
    g.drawCircle(Offset(x, y), r, _fill(const Color.fromRGBO(95, 96, 102, 0.55)));
    g.drawCircle(Offset(x - r * 0.25, y - r * 0.25), r * 0.6, _fill(const Color.fromRGBO(235, 234, 228, 0.6)));
  }
};

/// A giant's bands of cloud, in [colors] from pole to pole, with a storm or two turning in them.
Painter bands(int wi, int hi, List<String> colors, int seed) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(seed);
  const n = 22;
  g.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, h),
        [for (var i = 0; i <= n; i++) hex(colors[(rand() * colors.length).floor()])],
        [for (var i = 0; i <= n; i++) i / n],
      ),
  );
  for (var i = 0; i < 5; i++) {
    final c = Color.fromRGBO(255, 245, 225, 0.25 + rand() * 0.3);
    _ellipse(
      g,
      rand() * w,
      h * (0.25 + rand() * 0.5),
      (0.02 + rand() * 0.04) * w,
      (0.012 + rand() * 0.02) * h,
      0,
      _fill(c),
    );
  }
};

/// A dry red world: rust, darker country here and there, and ice at its poles.
Painter redPlanet(int wi, int hi) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(57);
  g.drawRect(Rect.fromLTWH(0, 0, w, h), _fill(hex('#b8563b')));
  for (var i = 0; i < 60; i++) {
    final c = rand() < 0.6 ? const Color.fromRGBO(110, 45, 30, 0.35) : const Color.fromRGBO(225, 150, 105, 0.3);
    _ellipse(g, rand() * w, rand() * h, (0.02 + rand() * 0.09) * w, (0.02 + rand() * 0.06) * h, rand() * 3, _fill(c));
  }
  g.drawRect(Rect.fromLTWH(0, 0, w, h * 0.06), _fill(hex('#f3ece6')));
  g.drawRect(Rect.fromLTWH(0, h * 0.95, w, h * 0.05), _fill(hex('#f3ece6')));
};

/// A giant's rings, from their inner edge (left) to their outer: bright bands, gaps between.
Painter rings(int wi, int hi) => (g) {
  final rand = seeded(77);
  for (var x = 0; x < wi; x++) {
    final t = x / wi;
    // A wide gap two thirds of the way out, and thin ones all the way across.
    final gap = (t - 0.62).abs() < 0.035 ? 0.08 : 1.0;
    final a = ((0.35 + 0.5 * rand()) * gap * math.pow(math.sin(t * math.pi), 0.4)).clamp(0.0, 1.0);
    final tint = 200 + (rand() * 40).floor();
    g.drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 1, hi.toDouble()),
      _fill(_rgba(tint + 10, tint - 8, tint - 50, a.toDouble())),
    );
  }
};

/// The sky all round: the Milky Way across it, and a few clouds of glowing gas.
Painter starfield(int wi, int hi) => (g) {
  final w = wi.toDouble(), h = hi.toDouble();
  final rand = seeded(99);
  g.drawRect(Rect.fromLTWH(0, 0, w, h), _fill(hex('#02030a')));
  // Where the Milky Way runs: a great circle, tilted, which on this map is a wave.
  double band(double x) => h / 2 + math.sin(x / w * math.pi * 2 + 1.1) * h * 0.24;
  void blob(double x, double y, double r, Color color, {BlendMode mode = BlendMode.plus}) {
    final p = Paint()
      ..blendMode = mode
      ..shader = ui.Gradient.radial(Offset(x, y), r, [color, color.withValues(alpha: 0)]);
    // Drawn again off each side, so nothing stops at the seam.
    for (final dx in [-w, 0.0, w]) {
      g.save();
      g.translate(dx, 0);
      g.drawRect(Rect.fromLTWH(x - r, y - r, 2 * r, 2 * r), p);
      g.restore();
    }
  }

  for (var i = 0; i < 150; i++) {
    final x = rand() * w;
    final y = band(x) + (rand() + rand() - 1) * h * 0.07;
    final r = (0.03 + rand() * 0.06) * h;
    blob(x, y, r, _rgba(90 + rand() * 50, 100 + rand() * 40, 150 + rand() * 60, 0.035 + rand() * 0.04));
  }
  for (final (x, y, r, c) in const [
    (0.14, 0.34, 0.2, Color.fromRGBO(120, 50, 170, 0.2)),
    (0.2, 0.42, 0.13, Color.fromRGBO(210, 70, 130, 0.14)),
    (0.47, 0.7, 0.18, Color.fromRGBO(30, 130, 150, 0.17)),
    (0.66, 0.26, 0.16, Color.fromRGBO(60, 80, 190, 0.18)),
    (0.86, 0.6, 0.15, Color.fromRGBO(160, 60, 110, 0.13)),
  ]) {
    blob(x * w, y * h, r * h, c);
  }
  // Dust lanes down the middle of the Milky Way.
  for (var i = 0; i < 40; i++) {
    final x = rand() * w;
    blob(
      x,
      band(x) + (rand() - 0.5) * h * 0.03,
      (0.012 + rand() * 0.025) * h,
      const Color.fromRGBO(2, 3, 10, 0.5),
      mode: BlendMode.srcOver,
    );
  }
  // The Milky Way's own stars, too many and too faint to tell apart: a grain along it. (The ones you
  // can tell apart are drawn sharp, in space.dart.)
  for (var i = 0; i < 4200; i++) {
    final x = rand() * w;
    final b = 120 + rand() * 110;
    final c = _rgba(b, b, math.min(255, b + 25), 0.1 + rand() * 0.16);
    g.drawCircle(Offset(x, band(x) + (rand() + rand() + rand() - 1.5) * h * 0.1), 1.1, _fill(c));
  }
};

/// The Sun's glare: white-hot in the middle, a warm halo round it, and rays across (on nothing).
Painter sunGlare(int si) => (g) {
  final s = si.toDouble(), c = s / 2;
  g.drawRect(
    Rect.fromLTWH(0, 0, s, s),
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(c, c),
        c,
        const [
          Color.fromRGBO(255, 255, 255, 1),
          Color.fromRGBO(255, 252, 235, 1),
          Color.fromRGBO(255, 236, 180, 0.75),
          Color.fromRGBO(255, 200, 120, 0.2),
          Color.fromRGBO(255, 170, 90, 0.05),
          Color.fromRGBO(255, 160, 80, 0),
        ],
        const [0, 0.07, 0.12, 0.3, 0.6, 1],
      ),
  );
  for (var i = 0; i < 6; i++) {
    g.save();
    g.translate(c, c);
    g.rotate(i * math.pi / 6 + 0.2);
    final strong = i % 3 == 0;
    g.drawRect(
      Rect.fromLTWH(-c, -s * (strong ? 0.008 : 0.004), s, s * (strong ? 0.016 : 0.008)),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          Offset(-c, 0),
          Offset(c, 0),
          [
            const Color.fromRGBO(255, 230, 190, 0),
            Color.fromRGBO(255, 240, 210, strong ? 0.42 : 0.18),
            const Color.fromRGBO(255, 230, 190, 0),
          ],
          [0, 0.5, 1],
        ),
    );
    g.restore();
  }
};
