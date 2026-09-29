// The bookshelf against the south wall (world/bookshelf.ts): a tall wooden case, five shelves packed
// with books of every size and color (a few leaning over, a stack lying flat, a plant and a globe
// among them), and a "Docs" sign along its top. E at it opens the project's Markdown to read
// (ui/bookshelf.dart).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'parts.dart';

const _spines = [
  '#b5413b',
  '#2a6f97',
  '#2d6a4f',
  '#e9c46a',
  '#6a4c93',
  '#f4a261',
  '#264653',
  '#ef476f',
  '#8ecae6',
  '#fffaf3',
];
const int _shelves = 5;

/// The case's boards, how far the shelves sit off the floor, and how thick they are.
const double _side = 0.05;
const double _base = 0.1;
const double _board = 0.03;

Collider bookshelfCollider() => Collider(
  minX: Bookshelf.x - Bookshelf.width / 2 - 0.04,
  maxX: Bookshelf.x + Bookshelf.width / 2 + 0.04,
  minZ: Bookshelf.z - Bookshelf.depth / 2 - 0.03,
  maxZ: Floor.maxZ,
  top: Bookshelf.height + 0.07,
);

({Node group, Interactable interactable}) buildBookshelf() {
  const w = Bookshelf.width, d = Bookshelf.depth, h = Bookshelf.height;
  // Seeded, so the shelf looks the same in every browser.
  var seed = 20250928;
  double rand() => (seed = (seed * 16807) % 2147483647) / 2147483647;
  String pick(List<String> xs) => xs[(rand() * xs.length).floor()];

  // Built facing +z, back against z = -d/2.
  final parts = Node(name: 'bookshelf-parts');
  final wood = tc('#9c6644');
  final woodDark = tc('#7f5539');
  void add(double bw, double bh, double bd, Material mat, double x, double y, double z) =>
      parts.add(mesh(box(bw, bh, bd), mat, x, y, z));
  add(w, h, 0.03, woodDark, 0, h / 2, -d / 2 + 0.015);
  for (final sx in [-1, 1]) {
    add(_side, h, d, wood, sx * (w / 2 - _side / 2), h / 2, 0);
  }
  // A crown over the top and a kick board at the foot.
  add(w + 0.08, 0.07, d + 0.05, wood, 0, h + 0.035, 0.01);
  add(w - 2 * _side, _base, d - 0.03, woodDark, 0, _base / 2, -0.015);

  const inner = w - 2 * _side;
  const bay = (h - _base - _board) / _shelves;
  const front = d / 2 - 0.02;
  // Round to the millimetre, so the books share a few geometries instead of each its own.
  double mm(double v) => (v * 1000).round() / 1000;
  for (var s = 0; s < _shelves; s++) {
    final floor = _base + s * bay + _board;
    add(inner, _board, d - 0.03, wood, 0, floor - _board / 2, -0.015);
    const room = bay - _board - 0.04;
    var x = -inner / 2 + 0.02;
    const end = inner / 2 - 0.02;
    // Now and then something that isn't a book: a globe on one shelf, a little plant on another.
    String? ornament = s == 1
        ? 'globe'
        : s == 3
        ? 'plant'
        : null;
    final ornamentAt = -inner / 2 + inner * (0.5 + rand() * 0.2);
    while (x < end - 0.03) {
      if (ornament != null && x >= ornamentAt) {
        if (ornament == 'globe') {
          parts.add(mesh(cyl(0.06, 0.08, 0.03, 12), woodDark, x + 0.13, floor + 0.015, 0));
          parts.add(mesh(cyl(0.01, 0.01, 0.07, 6), woodDark, x + 0.13, floor + 0.06, 0));
          parts.add(mesh(sphere(0.11, 14, 10), tc('#4cc9f0'), x + 0.13, floor + 0.18, 0));
          parts.add(mesh(sphere(0.075, 10, 8), tc('#80b918'), x + 0.16, floor + 0.21, 0.05));
        } else {
          parts.add(mesh(cyl(0.07, 0.055, 0.12, 10), tc('#e76f51'), x + 0.11, floor + 0.06, 0.02));
          parts.add(mesh(sphere(0.1, 10, 8), tc('#52b788'), x + 0.11, floor + 0.19, 0.02));
        }
        ornament = null;
        x += 0.28;
        continue;
      }
      // A stack lying flat, once in a while.
      if (rand() < 0.07 && end - x > 0.32) {
        var y = floor;
        final n = 2 + (rand() * 3).floor();
        for (var i = 0; i < n; i++) {
          final t = mm(0.04 + rand() * 0.03);
          final bw = mm(0.22 + rand() * 0.08);
          add(
            bw,
            t,
            mm(0.18 + rand() * 0.06),
            tc(pick(_spines)),
            x + 0.15 + (rand() - 0.5) * 0.03,
            y + t / 2,
            front - 0.13,
          );
          y += t;
        }
        x += 0.32;
        continue;
      }
      final t = mm(0.035 + rand() * 0.04);
      final bh = mm(math.min(room, room * (0.62 + rand() * 0.38)));
      final bd = mm(0.19 + rand() * 0.08);
      if (x + t > end) break;
      // The last one or two in a row lean over on their neighbour when there's room.
      final lean = end - x < 0.24 && end - x > 0.14 && rand() < 0.6;
      final mat = tc(pick(_spines));
      if (lean) {
        final g = Node(name: 'leaning');
        g.add(mesh(box(t, bh, bd), mat, t / 2, bh / 2, 0));
        parts.add(place(g, x: x + 0.01, y: floor, z: front - bd / 2, rot: euler(0, 0, -0.32)));
        break;
      }
      add(t, bh, bd, mat, x + t / 2, floor + bh / 2, front - bd / 2);
      // A band across some spines, near the top.
      if (rand() < 0.35) add(t + 0.004, 0.018, bd + 0.004, tc('#e9c46a'), x + t / 2, floor + bh * 0.82, front - bd / 2);
      x += t + (rand() < 0.1 ? 0.012 : 0.002);
    }
  }
  final group = Node(name: 'bookshelf');
  group.add(mergeByMaterial(parts));

  // A sign along the crown.
  group.add(place(textPlane('📚 Docs', const TextOpts(size: 40, bg: '#fffaf3')), y: h + 0.3, z: 0.02));

  // Built facing +z; it stands against the south wall facing into the room (-z).
  group.position = vm.Vector3(Bookshelf.x, 0, Bookshelf.z);
  group.rotation = yaw(math.pi);
  final it = Interactable(kind: InteractKind.bookshelf, x: Bookshelf.x, z: Bookshelf.z - 1.2, radius: 1.6);
  tagInteract(group, it);
  return (group: group, interactable: it);
}
