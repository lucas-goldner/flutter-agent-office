// 16-bit art for the 2D office (👾), in the Mega Drive's manner (Sonic 1): every color snapped to
// the console's 512, each material shaded in a short ramp whose shadows lean blue and highlights
// yellow, dark outlines round every shape, light from the top left. [SpriteGrid] rasterizes the
// people, workers and the dog into pixel images with that shading.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show HSVColor;

/// The Mega Drive's DAC levels: 3 bits a channel.
const List<int> _levels = [0, 52, 87, 116, 144, 172, 206, 255];

int _snap(int v) {
  var best = 0;
  for (final l in _levels) {
    if ((l - v).abs() < (best - v).abs()) best = l;
  }
  return best;
}

final Map<int, Color> _mdCache = {};

/// [c] as the Mega Drive would show it (alpha kept).
Color md(Color c) {
  final key = c.toARGB32();
  return _mdCache.putIfAbsent(key, () {
    final a = (key >> 24) & 0xFF, r = (key >> 16) & 0xFF, g = (key >> 8) & 0xFF, b = key & 0xFF;
    return Color.fromARGB(a, _snap(r), _snap(g), _snap(b));
  });
}

final Map<int, List<Color>> _ramps = {};

/// Five shades of [base], darkest first: [0] outline, [1] shadow, [2] the color, [3] light, [4] shine.
/// Shadows turn toward blue and grow richer, lights toward yellow and paler, as pixel artists shade.
List<Color> ramp(Color base) => _ramps.putIfAbsent(base.toARGB32(), () {
  final hsv = HSVColor.fromColor(base);
  Color step(double dv, double ds, double towardHue, double amount) {
    var h = hsv.hue;
    final diff = ((towardHue - h + 540) % 360) - 180;
    h = (h + diff * amount + 360) % 360;
    final v = (hsv.value + dv).clamp(0.0, 1.0);
    final s = (hsv.saturation + ds).clamp(0.0, 1.0);
    return md(HSVColor.fromAHSV(hsv.alpha, h, hsv.saturation < 0.08 ? hsv.saturation : s, v).toColor());
  }

  return [
    step(-0.62, 0.2, 250, 0.3),
    step(-0.26, 0.12, 250, 0.15),
    md(base),
    step(0.14, -0.1, 55, 0.12),
    step(0.3, -0.25, 55, 0.25),
  ];
});

/// The light: from the top left, a little in front.
const _lx = -0.55, _ly = -0.62, _lz = 0.56;

/// Which shade of a ramp a surface facing (nx, ny, nz) gets.
int litShade(double nx, double ny, double nz) {
  final d = nx * _lx + ny * _ly + nz * _lz;
  if (d > 0.86) return 4;
  if (d > 0.5) return 3;
  if (d > 0.1) return 2;
  return 1;
}

/// A small pixel image drawn shape by shape, then outlined and turned into an image.
class SpriteGrid {
  SpriteGrid(this.w, this.h) : _c = List.filled(w * h, null), _base = List.filled(w * h, null);

  final int w, h;
  final List<Color?> _c;
  final List<Color?> _base;

  bool _in(int x, int y) => x >= 0 && y >= 0 && x < w && y < h;

  Color? at(int x, int y) => _in(x, y) ? _c[y * w + x] : null;

  /// One pixel, of material [base] (its outline is that ramp's darkest).
  void set(int x, int y, Color c, [Color? base]) {
    if (!_in(x, y)) return;
    _c[y * w + x] = md(c);
    _base[y * w + x] = base ?? c;
  }

  void clear(int x, int y) {
    if (!_in(x, y)) return;
    _c[y * w + x] = null;
    _base[y * w + x] = null;
  }

  /// An ellipse shaded as a ball (or a bean) lit from the top left.
  void ball(double cx, double cy, double rx, double ry, Color base) {
    final r = ramp(base);
    for (var y = (cy - ry).floor(); y <= (cy + ry).ceil(); y++) {
      for (var x = (cx - rx).floor(); x <= (cx + rx).ceil(); x++) {
        final nx = (x + 0.5 - cx) / rx, ny = (y + 0.5 - cy) / ry;
        final d = nx * nx + ny * ny;
        if (d > 1) continue;
        set(x, y, r[litShade(nx, ny, math.sqrt(1 - d))], base);
      }
    }
  }

  /// A box from (x0, y0) to (x1, y1) inclusive, lit at its top and left edges, shadowed at its foot.
  void box(int x0, int y0, int x1, int y1, Color base, {bool flat = false}) {
    final r = ramp(base);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        var s = 2;
        if (!flat) {
          if (y == y0 || x == x0) s = 3;
          if (y == y1 || x == x1) s = 1;
        }
        set(x, y, r[s], base);
      }
    }
  }

  /// Every empty pixel touching a shape becomes that shape's darkest shade: the dark outline.
  void outline() {
    final add = <(int, int, Color)>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (_c[y * w + x] != null) continue;
        for (final (dx, dy) in const [(0, 1), (0, -1), (1, 0), (-1, 0)]) {
          final b = _in(x + dx, y + dy) ? _base[(y + dy) * w + x + dx] : null;
          if (b != null) {
            add.add((x, y, ramp(b)[0]));
            break;
          }
        }
      }
    }
    for (final (x, y, c) in add) {
      _c[y * w + x] = c;
    }
  }

  /// The pixels as an image, [w] × [h].
  Image toImage() {
    final rec = PictureRecorder();
    final canvas = Canvas(rec);
    final p = Paint()..isAntiAlias = false;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final c = _c[y * w + x];
        if (c != null) canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), p..color = c);
      }
    }
    return rec.endRecording().toImageSync(w, h);
  }
}
