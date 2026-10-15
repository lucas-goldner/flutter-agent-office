// The 2D office's live layer (👾 2D view): the floor plan (pixel_map.dart) scaled up crisply, and on
// it the people as 16-bit sprites (sprites.dart) — you, everyone else on the floor, each worker at its desk
// with how it's doing over its head — the dog, where you're walking to, and what's under the mouse. It paints a [MapScene], a snapshot of the office
// taken each frame, so it can be drawn (and tested) without the 3D office.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:office_shared/avatar.dart';

import 'pixel_map.dart';
import 'sprites.dart';

/// Someone on the map: a person, a worker at its desk, or you.
class MapPerson {
  const MapPerson({
    required this.x,
    required this.z,
    required this.look,
    required this.shirt,
    this.name = '',
    this.facing = 0,
    this.walking = false,
    this.sitting = false,
    this.status,
    this.me = false,
  });

  final double x;
  final double z;
  final Look look;
  final Color shirt;
  final String name;

  /// Which way they face (radians, 0 = +z, toward the bottom of the map).
  final double facing;
  final bool walking;
  final bool sitting;

  /// A worker's state, for the bubble over its head.
  final MapStatus? status;
  final bool me;
}

/// What a worker's bubble says.
enum MapStatus { starting, idle, working, needsInput, done, off }

/// Something you can use, under the mouse.
class MapHover {
  const MapHover({required this.x, required this.z, required this.radius, required this.title});
  final double x;
  final double z;
  final double radius;
  final String title;
}

/// A name tag over something you can use; under the mouse it opens up with what its hint says.
class MapLabel {
  const MapLabel({
    required this.x,
    required this.z,
    required this.text,
    this.id = 0,
    this.detail,
    this.action,
    this.below = false,
  });

  /// Hung under the point instead of over it (a worker south of its desk: under its feet).
  final bool below;

  /// Where it's pinned: the top middle of the thing (meters).
  final double x;
  final double z;
  final String text;

  /// Which one it is, for telling a click on it apart.
  final int id;

  /// Opened up (hovered): the full title and its asides, and what a click does.
  final List<String>? detail;
  final String? action;
}

/// The office as the map draws it this frame.
class MapScene {
  const MapScene({
    this.people = const [],
    this.heading,
    this.dog,
    this.hover,
    this.labels = const [],
    this.signs = const [],
    this.t = 0,
  });

  /// The signs hung over desks (L in 3D): where each hangs, and its board's color. Their words are
  /// name tags (in [labels]).
  final List<({double x, double z, Color color})> signs;

  /// The name tags over everything you can use.
  final List<MapLabel> labels;

  final List<MapPerson> people;

  /// Where you're walking to.
  final ({double x, double z})? heading;
  final ({double x, double z})? dog;
  final MapHover? hover;

  /// Seconds, for blinking and bobbing.
  final double t;
}

/// How the map sits in a [size] view: its scale, and where its top-left corner is.
({double scale, Offset origin}) mapFit(Size size, {double top = 0}) {
  final w = MapBounds.width.toDouble(), h = MapBounds.height.toDouble();
  final avail = Size(size.width, math.max(1, size.height - top));
  var scale = math.min(avail.width / w, avail.height / h);
  // Whole pixels when there's room for it: every map pixel the same size on screen.
  if (scale >= 2) scale = scale.floorToDouble();
  final origin = Offset(
    ((size.width - w * scale) / 2).roundToDouble(),
    (top + (avail.height - h * scale) / 2).roundToDouble(),
  );
  return (scale: scale, origin: origin);
}

/// Hex to color, for the wire's colors.
Color mapColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? const Color(0xFF888888) : Color(0xFF000000 | v);
}

/// Where the map is on the page: page pixels per map pixel, and where its top-left corner is.
class MapView {
  const MapView(this.scale, this.origin);
  final double scale;
  final Offset origin;

  /// Page pixels to a meter.
  double get perMeter => scale * kPx;

  /// A floor point on the page.
  Offset toPage(double x, double z) => origin + mapPoint(x, z) * scale;

  /// The floor point under a page point.
  ({double x, double z}) toFloor(Offset p) => floorPoint((p - origin) / scale);
}

class OfficeMapPainter extends CustomPainter {
  OfficeMapPainter({required this.map, required this.scene, this.top = 0, this.view, super.repaint});

  /// The floor plan, drawn once (pixel_map.dart), or null while it's being made.
  ui.Image? map;
  final MapScene Function() scene;

  /// Room left at the top for the office's bar.
  final double top;

  /// Where the map is on a page this size (zoomed and panned); the whole floor, fitted, without it.
  final MapView Function(Size size)? view;

  final Map<String, TextPainter> _names = {};

  /// Where each label was drawn last frame (page pixels) and its [MapLabel.id], topmost last.
  final List<(Rect, int)> labelHits = [];
  final SpriteBook _sprites = SpriteBook();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Pal.outside);
    final v =
        view?.call(size) ??
        (() {
          final f = mapFit(size, top: top);
          return MapView(f.scale, f.origin);
        })();
    final s = scene();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(v.origin.dx, v.origin.dy);
    canvas.scale(v.scale);
    if (map != null) canvas.drawImage(map!, Offset.zero, Paint()..filterQuality = FilterQuality.none);
    final px = Pixels(canvas);

    // The signs over the desks: a board on its two wires, in its color.
    for (final g in s.signs) {
      px.blockAt(g.x, g.z, 1.3, 0.22, g.color, shadow: false);
    }

    // What's under the mouse: a ring round where you'd stand to use it.
    final h = s.hover;
    if (h != null) _ring(px, h.x, h.z, math.max(0.5, h.radius * 0.6), const Color(0xCCFFFFFF));

    // Where you're walking to: a marker that pulses.
    final head = s.heading;
    if (head != null) {
      final o = mapPoint(head.x, head.z);
      final r = 2 + ((s.t * 4) % 2).floor();
      for (final (dx, dy) in [(-r, -r), (r, -r), (-r, r), (r, r), (0, 0)]) {
        px.dot(o.dx + dx, o.dy + dy, Pal.yellow, 2);
      }
    }

    // People, workers and the dog as 16-bit sprites on the map's own pixels, back to front so the
    // nearer ones (lower on the map) draw over.
    final people = [...s.people]..sort((a, b) => a.z.compareTo(b.z));
    final dog = s.dog;
    final things = <(double, void Function())>[
      for (final p in people) (p.z, () => _person(canvas, p, s.t)),
      if (dog != null) (dog.z, () => _dog(canvas, dog.x, dog.z, s.t)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, draw) in things) {
      draw();
    }
    // Bubbles over the workers that you'd come over for, and your arrow.
    for (final p in people) {
      final o = mapPoint(p.x, p.z);
      final st = p.status;
      if (st == MapStatus.needsInput || st == MapStatus.done || st == MapStatus.working) {
        final bob = st == MapStatus.needsInput && (s.t * 4).floor().isEven ? 1 : 0;
        drawSprite(canvas, _sprites.bubble(st!, dots: 1 + (s.t * 3).floor() % 3), o.dx, o.dy - 23 - bob);
      }
      if (p.me) drawSprite(canvas, _sprites.marker(), o.dx, o.dy - 23 - ((s.t * 3).floor() % 2));
    }
    canvas.restore();

    // Names at the page's resolution, once you're close enough for them to fit.
    for (final p in people) {
      final feet = v.toPage(p.x, p.z);
      // Workers have their tags (MapLabel) instead.
      if (p.me || (p.name.isNotEmpty && p.status == null)) {
        _name(canvas, p, feet + const Offset(0, 2));
      }
    }
    _labels(canvas, s.labels, v, size);
    if (h != null && h.title.isNotEmpty && !s.labels.any((l) => l.detail != null)) {
      _tip(canvas, h.title, v.toPage(h.x, h.z) - Offset(0, 0.5 * v.perMeter), size);
    }
  }

  void _person(Canvas canvas, MapPerson p, double t) {
    final o = mapPoint(p.x, p.z);
    final st = p.status;
    if (st != null) {
      // A worker: bouncing while it works, hopping when it needs you, blinking now and then.
      final phase = (p.x * 7 + p.z * 3) % 5;
      final lift = switch (st) {
        MapStatus.working => ((t + phase) * 8).floor() % 2,
        MapStatus.needsInput => ((t + phase) * 5).floor() % 3 == 0 ? 3 : 0,
        _ => 0,
      };
      final blink = ((t + phase) % 4.0) < 0.15;
      final lit = st == MapStatus.needsInput ? (t * 6).floor().isEven : true;
      drawSprite(canvas, _sprites.worker(p.shirt, st, blink: blink, lit: lit), o.dx, o.dy - lift);
      return;
    }
    final back = math.cos(p.facing) < -0.3;
    final step = p.walking ? 1 + (t * 8).floor() % 2 : 0;
    drawSprite(
      canvas,
      _sprites.person(p.look, p.shirt, back: back, step: step, sitting: p.sitting),
      o.dx,
      o.dy - (step == 1 ? 1 : 0),
    );
  }

  final Map<int, double> _dogLastX = {};
  bool _dogLeft = false;

  void _dog(Canvas canvas, double x, double z, double t) {
    final last = _dogLastX[0];
    final moving = last != null && (x - last).abs() > 0.002;
    if (last != null && (x - last).abs() > 0.01) _dogLeft = x < last;
    _dogLastX[0] = x;
    final o = mapPoint(x, z);
    drawSprite(canvas, _sprites.dog(step: moving ? 1 + (t * 8).floor() % 2 : 0, left: _dogLeft), o.dx, o.dy);
  }

  void _ring(Pixels px, double x, double z, double r, Color color) {
    final o = mapPoint(x, z);
    final rp = r * kPx;
    for (var a = 0.0; a < math.pi * 2; a += 1 / rp) {
      px.dot(o.dx + math.cos(a) * rp, o.dy + math.sin(a) * rp, color);
    }
  }

  void _name(Canvas canvas, MapPerson p, Offset o) {
    final key = '${p.me}|${p.name}';
    final tp = _names.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: p.me ? 'You' : p.name,
          style: TextStyle(
            fontFamily: 'Nunito',
            fontFamilyFallback: const ['Twemoji'],
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 0, offset: Offset(1, 1))],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 120),
    );
    tp.paint(canvas, Offset(o.dx - tp.width / 2, o.dy));
  }

  /// The name tags, 16-bit style: a dark box with a lit top-left edge and a shadowed foot, a little
  /// tail down to what it names. The open one (under the mouse) draws last, over the others.
  void _labels(Canvas canvas, List<MapLabel> labels, MapView v, Size size) {
    labelHits.clear();
    final placed = <Rect>[];
    final order = [...labels]..sort((a, b) => (a.detail != null ? 1 : 0) - (b.detail != null ? 1 : 0));
    for (final l in order) {
      final o = v.toPage(l.x, l.z);
      // Zoomed in, what's off the page has no tag on it.
      if (o.dx < -20 || o.dy < -20 || o.dx > size.width + 20 || o.dy > size.height + 40) continue;
      final open = l.detail != null;
      final title = _text(open && l.detail!.isNotEmpty ? l.detail!.first : l.text, open ? 13 : 10.5, Colors.white);
      final lines = [
        if (open)
          for (final d in l.detail!.skip(1)) _text(d, 11, const Color(0xFFCED4DA)),
        if (open && l.action != null) _text(l.action!, 11, const Color(0xFFFFD166)),
      ];
      final padX = open ? 8.0 : 5.0, padY = open ? 5.0 : 2.0;
      var w = title.width;
      var h = title.height;
      for (final t in lines) {
        w = math.max(w, t.width);
        h += t.height + 1;
      }
      final box = Rect.fromLTWH(
        (o.dx - w / 2 - padX).roundToDouble(),
        (l.below ? o.dy + 6 : o.dy - 6 - h - padY * 2).roundToDouble(),
        (w + padX * 2).roundToDouble(),
        (h + padY * 2).roundToDouble(),
      );
      // Kept on the page, and nudged up off any tag already there (the open one goes on top as it is).
      var r = box.shift(
        Offset(-math.min(0.0, box.left - 4) - math.max(0.0, box.right - size.width + 4), -math.min(0.0, box.top - 4)),
      );
      if (!open) {
        for (var tries = 0; tries < 4 && placed.any((q) => q.overlaps(r.inflate(1))); tries++) {
          final hit = placed.firstWhere((q) => q.overlaps(r.inflate(1)));
          r = r.shift(Offset(0, l.below ? hit.bottom - r.top + 3 : hit.top - r.bottom - 3));
        }
        placed.add(r);
      }
      final p = Paint()..isAntiAlias = false;
      canvas.drawRect(r.shift(const Offset(2, 2)), p..color = const Color(0x6610102A));
      canvas.drawRect(r.inflate(1), p..color = const Color(0xFF0B0B16));
      canvas.drawRect(r, p..color = open ? const Color(0xF02B2D5A) : const Color(0xE61A1A3A));
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width, 1.5), p..color = const Color(0xFF5A5FA8));
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, 1.5, r.height), p..color = const Color(0xFF5A5FA8));
      canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - 1.5, r.width, 1.5), p..color = const Color(0xFF10102A));
      // The tail.
      final tx = o.dx.clamp(r.left + 4, r.right - 4).roundToDouble();
      if (l.below) {
        canvas.drawRect(Rect.fromLTWH(tx - 2, r.top - 3, 4, 2), p..color = const Color(0xFF0B0B16));
        canvas.drawRect(Rect.fromLTWH(tx - 1, r.top - 5, 2, 2), p..color = const Color(0xFF0B0B16));
      } else {
        canvas.drawRect(Rect.fromLTWH(tx - 2, r.bottom, 4, 2), p..color = const Color(0xFF0B0B16));
        canvas.drawRect(Rect.fromLTWH(tx - 1, r.bottom + 2, 2, 2), p..color = const Color(0xFF0B0B16));
      }
      var y = r.top + padY;
      title.paint(canvas, Offset(r.left + padX, y));
      y += title.height + 1;
      for (final t in lines) {
        t.paint(canvas, Offset(r.left + padX, y));
        y += t.height + 1;
      }
      labelHits.add((r.inflate(2), l.id));
    }
  }

  final Map<String, TextPainter> _texts = {};

  TextPainter _text(String text, double size, Color color) {
    if (_texts.length > 400) _texts.clear();
    return _texts.putIfAbsent(
      '$size|${color.toARGB32()}|$text',
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'Nunito',
            fontFamilyFallback: const ['Twemoji'],
            fontSize: size,
            fontWeight: FontWeight.w900,
            color: color,
            shadows: const [Shadow(color: Color(0xFF0B0B16), offset: Offset(1, 1))],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 280),
    );
  }

  void _tip(Canvas canvas, String text, Offset o, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontFamilyFallback: ['Twemoji'],
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 260);
    final r = Rect.fromCenter(center: o - const Offset(0, 14), width: tp.width + 16, height: tp.height + 8);
    final shifted = r.shift(Offset(-math.min(0, r.left - 4) - math.max(0, r.right - size.width + 4), 0));
    canvas.drawRRect(
      RRect.fromRectAndRadius(shifted, const Radius.circular(6)),
      Paint()..color = const Color(0xE62B2D42),
    );
    tp.paint(canvas, Offset(shifted.left + 8, shifted.top + 4));
  }

  @override
  bool shouldRepaint(OfficeMapPainter old) => old.map != map || old.top != top;
}
