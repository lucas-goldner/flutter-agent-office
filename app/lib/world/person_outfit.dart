// A person dressed for a holiday, head to toe (#228), to match the hands you see in first person (see
// hands.dart): for Halloween a warlock's hat and a purple robe with a ragged hem, a sash, dark trousers
// and pointed boots; for Christmas a Santa hat and suit, white fur trim, a black belt with a gold buckle,
// black boots and green mittens. A port of world/character/person-outfit.ts. It goes on over their own
// clothes (each piece a little bigger than what it covers), hung off the parts it moves with: the torso
// and legs (which you see looking down in first person), the arms and the head.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vec;
import 'package:office_shared/protocol.dart' show HolidayTheme;

import 'costumes.dart' show santaHat, warlockHat;
import 'geo.dart';
import 'toon.dart';

/// Where things are on a person (see Person's constructor): the torso's middle, and down an arm or a leg.
const double _torsoY = 0.72;
const double _limbMid = -0.16;
const double _hand = -0.38;
const double _foot = -0.36;

/// A tube, open at both ends, [top] to [bottom] round, its hem cut ragged into [teeth] points.
Node raggedSkirt(double top, double bottom, double height, int teeth, Material mat) {
  final n = teeth * 2;
  final g = GeoData();
  final slope = (bottom - top) / height;
  final rows = <List<int>>[];
  for (var row = 0; row <= 2; row++) {
    final v = row / 2;
    final r = top + (bottom - top) * v;
    final ids = <int>[];
    for (var i = 0; i <= n; i++) {
      final th = i / n * math.pi * 2;
      final s = math.sin(th), c = math.cos(th);
      var y = height / 2 - height * v;
      if (row == 2) {
        final k = ((math.atan2(c * r, s * r) + math.pi) / (math.pi * 2) * n).round();
        y += k.isOdd ? 0.07 : (k % 3 != 0 ? 0.02 : 0);
      }
      ids.add(g.vertex(r * s, y, r * c, s, slope, c));
    }
    rows.add(ids);
  }
  for (var row = 0; row < 2; row++) {
    for (var i = 0; i < n; i++) {
      final a = rows[row][i], b = rows[row + 1][i], c = rows[row + 1][i + 1], d = rows[row][i + 1];
      g.tri(a, b, d);
      g.tri(b, c, d);
    }
  }
  return mesh(g.build(), mat);
}

/// A capsule over a limb, from its pivot down, a little rounder than it.
Node _sleeve(double r, Material mat) => mesh(capsule(r, 0.24, 4, 10), mat, 0, _limbMid, 0);

/// A band round something, [r] round, at [y].
Node _band(double r, double h, Material mat, double y) => mesh(cylinder(r, r, h, 24), mat, 0, y, 0);

/// A ring of fur round something, [r] round, at [y].
Node _fur(double r, double tube, double y) =>
    mesh(torus(r, tube, 8, 24), toon(hex('#fffaf3')), 0, y, 0)..rotation = euler(math.pi / 2, 0, 0);

/// What a person has on for a holiday (see [set]), and taking it off again.
class HolidayOutfit {
  HolidayOutfit({
    required this.head,
    required this.torso,
    required this.armL,
    required this.armR,
    required this.legL,
    required this.legR,
  });

  /// The parts it hangs off. The torso is its own mesh, which slims in first person: what goes round it
  /// goes on it.
  final Node head, torso, armL, armR, legL, legR;
  final List<Node> _parts = [];

  /// What it has on now, piece by piece.
  List<Node> get parts => List.unmodifiable(_parts);

  /// Dresses them for [theme], or back in their own clothes (null).
  void set(HolidayTheme? theme) {
    for (final p in _parts) {
      p.detach();
    }
    _parts.clear();
    if (theme == HolidayTheme.halloween) _warlock();
    if (theme == HolidayTheme.christmas) _santa();
  }

  void _put(Node on, Node o) {
    on.add(o);
    _parts.add(o);
  }

  void _warlock() {
    final robe = toon(hex('#3b1d5a'));
    // Its own material: double-sided, which the shared one for this colour mustn't become.
    final rags = toonUnique(hex('#24123a'))..doubleSided = true;
    _put(head, warlockHat());
    _put(torso, mesh(capsule(0.272, 0.28, 6, 14), robe));
    // The robe's skirt, down to the shins, ragged at the hem.
    _put(torso, raggedSkirt(0.27, 0.36, 0.42, 9, rags)..position = vec.Vector3(0, 0.34 - _torsoY, 0));
    _put(torso, _band(0.28, 0.06, toon(hex('#ff7b00')), 0.6 - _torsoY));
    for (final arm in [armL, armR]) {
      _put(arm, _sleeve(0.09, robe));
      _put(arm, raggedSkirt(0.09, 0.115, 0.1, 5, rags)..position = vec.Vector3(0, _hand + 0.07, 0));
    }
    final black = toon(hex('#1d1d1d'));
    for (final leg in [legL, legR]) {
      _put(leg, _sleeve(0.106, rags));
      // A pointed boot, its toe curled up.
      final boot = Node(name: 'boot')..position = vec.Vector3(0, _foot, 0);
      boot.add(mesh(sphere(0.11, 12, 10), black, 0, 0, 0.02));
      boot.add(mesh(cone(0.06, 0.2, 10), black, 0, 0.03, 0.16)..rotation = euler(math.pi / 2 - 0.35, 0, 0));
      _put(leg, boot);
    }
  }

  void _santa() {
    final red = toon(hex('#d62828'));
    final black = toon(hex('#1d1d1d'));
    _put(head, santaHat());
    _put(torso, mesh(capsule(0.272, 0.28, 6, 14), red));
    // White fur round the jacket's hem and down its front.
    _put(torso, _fur(0.27, 0.05, 0.4 - _torsoY));
    _put(torso, mesh(box(0.08, 0.5, 0.04), toon(hex('#fffaf3')), 0, 0.74 - _torsoY, 0.262));
    _put(torso, _band(0.282, 0.075, black, 0.58 - _torsoY));
    _put(torso, mesh(box(0.11, 0.09, 0.03), toon(hex('#ffd166')), 0, 0.58 - _torsoY, 0.285));
    for (final arm in [armL, armR]) {
      _put(arm, _sleeve(0.09, red));
      _put(arm, _fur(0.09, 0.035, _hand + 0.08));
      _put(arm, mesh(sphere(0.095, 12, 10), toon(hex('#2a9d4b')), 0, _hand, 0));
    }
    for (final leg in [legL, legR]) {
      _put(leg, _sleeve(0.106, red));
      final boot = Node(name: 'boot')..position = vec.Vector3(0, _foot, 0);
      boot.add(mesh(cylinder(0.115, 0.115, 0.16, 14), black, 0, 0.03, 0));
      boot.add(mesh(sphere(0.1, 12, 10), black, 0, -0.03, 0.07));
      _put(leg, boot);
    }
  }
}
