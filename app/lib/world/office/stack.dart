// The floors above and below this one (a port of world/stack.ts): the floor you walk on (planks)
// and the slab under it, the ceiling over it (and the hatches and holes in both), the ladder up the
// west wall, and the fire pole. Every floor is built from the same office, so what's here depends on
// which floor of the building you're on (see [FloorStack.set]). What you bump into is stack_plan.dart's.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard, poles;
import 'package:office_shared/layout.dart' as lay show poles;

import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'parts.dart';
import 'stack_plan.dart';

export 'stack_plan.dart' show StackState;

/// The top of the windows either side of the ladder, where the sign to the floor above hangs.
final double _ladderWindowHead = windows.where((w) => w.wall == Side.west).map((w) => w.y1).reduce(math.max);

/// A hole in a flat surface: a rectangle, or a circle of radius [r] round (x, z).
class _Hole {
  _Hole.rect(PlanRect this.rect) : x = 0, z = 0, r = 0;
  _Hole.circle(this.x, this.z, this.r) : rect = null;

  final PlanRect? rect;
  final double x;
  final double z;
  final double r;

  List<vm.Vector2> outline() {
    final q = rect;
    if (q != null) {
      return [
        vm.Vector2(q.minX, q.minZ),
        vm.Vector2(q.maxX, q.minZ),
        vm.Vector2(q.maxX, q.maxZ),
        vm.Vector2(q.minX, q.maxZ),
      ];
    }
    return [
      for (var i = 0; i < 32; i++)
        vm.Vector2(x + math.cos(i / 32 * math.pi * 2) * r, z + math.sin(i / 32 * math.pi * 2) * r),
    ];
  }
}

double _area(List<vm.Vector2> pts) {
  var a = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

/// A flat rectangle [r] at height [y] with [holes] in it, facing up or down, its uvs [tile] meters a repeat.
Geometry _surface(PlanRect r, List<_Hole> holes, {required bool up, double y = 0, double tile = 1}) {
  var outer = [
    vm.Vector2(r.minX, r.minZ),
    vm.Vector2(r.maxX, r.minZ),
    vm.Vector2(r.maxX, r.maxZ),
    vm.Vector2(r.minX, r.maxZ),
  ];
  if (_area(outer) < 0) outer = outer.reversed.toList();
  final hs = [
    for (final h in holes)
      () {
        final o = h.outline();
        return _area(o) > 0 ? o.reversed.toList() : o;
      }(),
  ];
  final tris = triangulate(outer, hs);
  final all = [...outer, for (final h in hs) ...h];
  final p = <double>[], n = <double>[], uv = <double>[];
  final idx = <int>[];
  for (final v in all) {
    p.addAll([v.x, y, v.y]);
    n.addAll([0, up ? 1 : -1, 0]);
    uv.addAll([(v.x - r.minX) / tile, (r.maxZ - v.y) / tile]);
  }
  for (var i = 0; i < tris.length; i += 3) {
    final a = all[tris[i]], b = all[tris[i + 1]], c = all[tris[i + 2]];
    // (b - a) x (c - a) in (x, y, z) with the points on the plane: its y is dz_ab * dx_ac - dx_ab * dz_ac.
    final ny = (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y);
    if ((ny > 0) == up) {
      idx.addAll([tris[i], tris[i + 1], tris[i + 2]]);
    } else {
      idx.addAll([tris[i], tris[i + 2], tris[i + 1]]);
    }
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList(p),
      normals: Float32List.fromList(n),
      texCoords: Float32List.fromList(uv),
      indices: idx,
    ),
  );
}

/// Ceiling tiles: a light grid, one tile a repeat.
Future<Texture2D> _tileTexture() => canvasTexture(128, 128, (g) {
  g.drawRect(const Rect.fromLTWH(0, 0, 128, 128), fill(linColor('#fbf7ef')));
  final seam = fill(linColor('#e3dccf'));
  g.drawRect(const Rect.fromLTWH(0, 0, 128, 5), seam);
  g.drawRect(const Rect.fromLTWH(0, 0, 5, 128), seam);
  // A few speckles, like the mineral fibre in real tiles.
  final speck = fill(linColor('#efe8dc'));
  for (var i = 0; i < 40; i++) {
    g.drawRect(Rect.fromLTWH(8.0 + (i * 53) % 116, 8.0 + (i * 97) % 116, 3, 2), speck);
  }
});

/// A shaft going on past a hole into the dark, from [from] to [to] (y): its walls fade out the further they go.
Node _shaft({
  required bool round,
  required double half,
  required double from,
  required double to,
  required double cx,
  required double cz,
}) {
  final g = Node(name: 'shaft');
  final seg = round ? 24 : 4;
  final rad = round ? half : half * math.sqrt2;
  final a0 = round ? 0.0 : math.pi / 4;
  const rows = 6;
  final near = linear(hex('#8d7b6a')), far = linear(hex('#141320'));
  final p = <double>[], col = <double>[];
  final idx = <int>[];
  for (var j = 0; j <= rows; j++) {
    // 1 at the hole, 0 at the far end.
    final k = 1 - j / rows;
    final y = from + (to - from) * j / rows;
    final f = math.min(1.0, math.pow(1 - k, 0.7).toDouble());
    final c = near + (far - near) * f;
    for (var i = 0; i <= seg; i++) {
      final a = a0 + i / seg * math.pi * 2;
      p.addAll([cx + math.cos(a) * rad, y, cz + math.sin(a) * rad]);
      col.addAll([c.x, c.y, c.z, 1]);
    }
  }
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < seg; i++) {
      final a = j * (seg + 1) + i, b = a + 1, c = a + seg + 1, d = c + 1;
      // Seen from inside: wound so the face looks in toward the axis.
      for (final (x, y, z) in [(a, b, d), (a, d, c)]) {
        final pa = vm.Vector3(p[x * 3], p[x * 3 + 1], p[x * 3 + 2]);
        final pb = vm.Vector3(p[y * 3], p[y * 3 + 1], p[y * 3 + 2]);
        final pc = vm.Vector3(p[z * 3], p[z * 3 + 1], p[z * 3 + 2]);
        final nrm = (pb - pa).cross(pc - pa);
        final inward = vm.Vector3(cx - pa.x, 0, cz - pa.z);
        if (nrm.dot(inward) >= 0) {
          idx.addAll([x, y, z]);
        } else {
          idx.addAll([x, z, y]);
        }
      }
    }
  }
  final walls = UnlitMaterial()..baseColorFactor = vm.Vector4(1, 1, 1, 1);
  g.add(
    Node(
      mesh: Mesh(
        MeshGeometry.fromMeshData(
          MeshData.build(positions: Float32List.fromList(p), colors: Float32List.fromList(col), indices: idx),
        ),
        walls,
      ),
    ),
  );
  // The far end, facing back up (or down) the shaft.
  final endMat = UnlitMaterial()..baseColorFactor = far;
  final endY = from > to ? math.min(from, to) + 0.01 : math.max(from, to) - 0.01;
  final end = round ? _Hole.circle(cx, cz, half) : _Hole.rect(around(cx, cz, half));
  final pts = end.outline();
  final ep = <double>[];
  for (var i = 1; i < pts.length - 1; i++) {
    final a = pts[0], b = pts[i], c = pts[i + 1];
    final ny = (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y);
    final faceUp = to < from;
    final tri = (ny > 0) == faceUp ? [a, b, c] : [a, c, b];
    for (final v in tri) {
      ep.addAll([v.x, endY, v.y]);
    }
  }
  g.add(Node(mesh: Mesh(geometryFrom(Float32List.fromList(ep)), endMat)));
  return g;
}

/// A trapdoor on a hinge at its room-side edge: [open] swings it up out of the floor, or down out of the ceiling.
class _Trapdoor {
  _Trapdoor(this.down) : pivot = Node(name: down ? 'ceiling-hatch' : 'floor-hatch') {
    const hatch = Ladder.hatch;
    final w = hatch.maxX - hatch.minX - Ladder.slot;
    final d = hatch.maxZ - hatch.minZ;
    pivot.position = vm.Vector3(hatch.maxX, down ? wallHeight : 0, (hatch.minZ + hatch.maxZ) / 2);
    final lid = Node(name: 'lid');
    const t = 0.06;
    // Flush with the floor (a touch proud of it, so it reads as a hatch), or with the ceiling.
    lid.add(
      mesh(
        box(w - 0.02, t, d - 0.02),
        tc(down ? '#f3eee4' : '#c98b5a'),
        -w / 2,
        down ? t / 2 : -t / 2 + 0.012,
        0,
        false,
      ),
    );
    // A frame round it, and a ring to pull it by, on the side you see.
    final rim = tc(down ? '#d9cfbe' : '#7a5236');
    final y = down ? -0.012 : 0.022;
    for (final s in [-1, 1]) {
      lid.add(mesh(box(w - 0.02, 0.025, 0.05), rim, -w / 2, y, s * (d - 0.07) / 2, false));
      lid.add(mesh(box(0.05, 0.025, d - 0.02), rim, -w / 2 + s * (w - 0.07) / 2, y, 0, false));
    }
    lid.add(
      place(
        mesh(torusXY(0.06, 0.012, 6, 16), tc('#adb5bd'), 0, 0, 0, false),
        x: -w + 0.16,
        y: down ? -0.02 : 0.03,
        rot: euler(math.pi / 2),
      ),
    );
    pivot.add(mergeByMaterial(lid));
  }

  final Node pivot;

  /// 0 shut … 1 open.
  double open = 0;
  final bool down;

  void show() => pivot.rotation = euler(0, 0, (down ? 1 : -1) * open * (math.pi / 2 + 0.12));
}

/// What's at one of the pole's spots on this floor.
class _PoleView {
  _PoleView(this.spot, this.index, this.group, this.interactable);

  final PoleSpot spot;
  final int index;
  final Node group;
  final Interactable interactable;

  /// Through the hole below, and up into the ceiling: more of the pole.
  late Node below, above;

  /// Going down: the railing round the hole, and the dark under it.
  late Node down, downShaft;

  /// On the top floor, where it's bolted to the ceiling; on the bottom floor, the mat you land on.
  late Node flange, landing;

  /// Coming down from above: the collar round the hole in the ceiling, and the dark over it.
  late Node collar, upShaft;
  Node? sign;
  String signText = '';
}

/// Someone near the ladder: where, and whether they're on it.
typedef StackPerson = ({double x, double y, double z, bool onLadder});

/// The floor you walk on, the slab under it, the ceiling over it, the ladder and the fire pole.
class FloorStack {
  FloorStack._(this._colliders, this._planks) {
    _build();
  }

  final List<Collider> _colliders;
  final Material _planks;
  final Node group = Node(name: 'stack');
  final List<Interactable> interactables = [];
  StackState state = const StackState();

  /// A hatch just started opening ([open]) or banged shut: 'floor' or 'ceiling'.
  void Function(String where, bool open)? onHatch;

  late final Node _ladder, _ladderBelow, _ladderAbove, _ladderDownShaft, _ladderUpShaft;
  late final Interactable _ladderIt;
  late final _Trapdoor _floorHatch, _ceilingHatch;
  final List<_PoleView> _poles = [];
  final List<Node> _built = [];
  final List<Collider> _mine = [];
  final List<Node> _ladderSigns = [];
  late final Material _tiles, _concrete, _band;

  /// The poles on this floor, when there's another floor for them to go to.
  List<PoleSpot> poles() => state.others ? poles_ : const [];

  /// Whether the poles go on down through holes in this floor (there's a floor below).
  bool polesGoDown() => state.below;

  static const List<PoleSpot> poles_ = lay.poles;

  void _build() {
    _concrete = tc('#d3d6dd');
    _band = tc('#e8a87c');
    final tiles = Toon.create(hex('#ffffff'));
    _tileTexture().then((t) => setToonTexture(tiles, t));
    // Lit from below by the room's lamps, not left in the shade the sun would give it.
    setEmissive(tiles, hex('#6a655d'), 1);
    _tiles = tiles;
    final brass = tc('#f2c14e', emissive: '#3a2a00');
    final red = tc('#e63946');
    final steel = tc('#ffd166');
    final rungMat = tc('#e09f3e');

    // The ladder: steel rails and rungs up the wall, from the floor to the ceiling, and on through the
    // hatches into the shafts when there's a floor there.
    Node ladderPart(double y0, double y1) {
      final g = Node(name: 'ladder-part');
      for (final s in [-1, 1]) {
        g.add(
          mesh(box(0.07, y1 - y0, 0.07), steel, ladderRailX, (y0 + y1) / 2, Ladder.z + s * Ladder.width / 2, false),
        );
      }
      for (var y = ((y0 + 0.15) / 0.3).ceil() * 0.3; y < y1 - 0.05; y += 0.3) {
        g.add(
          place(
            mesh(cyl(0.03, 0.03, Ladder.width, 8), rungMat, 0, 0, 0, false),
            x: ladderRailX,
            y: y,
            z: Ladder.z,
            rot: euler(math.pi / 2),
          ),
        );
      }
      return g;
    }

    final ladder = Node(name: 'ladder');
    final main = ladderPart(0, wallHeight);
    // Brackets holding it off the wall.
    for (var y = 0.9; y < wallHeight - 0.4; y += 1.5) {
      for (final s in [-1, 1]) {
        main.add(mesh(box(0.18, 0.05, 0.05), steel, Floor.minX + 0.08, y, Ladder.z + s * Ladder.width / 2, false));
      }
    }
    // A stripe of hazard paint on the floor in front of it.
    for (var i = 0; i < 5; i++) {
      main.add(
        place(
          mesh(planeXY(0.1, 0.34), tc(i.isOdd ? '#2b2d42' : '#ffd166'), 0, 0, 0, false),
          x: Ladder.hatch.maxX + 0.08,
          y: 0.006,
          z: Ladder.z - 0.4 + i * 0.2,
          rot: euler(-math.pi / 2, 0, 0.6),
        ),
      );
    }
    _ladderBelow = mergeByMaterial(ladderPart(-2.2, 0));
    _ladderAbove = mergeByMaterial(ladderPart(wallHeight, wallHeight + 2.2));
    ladder
      ..add(mergeByMaterial(main))
      ..add(_ladderBelow)
      ..add(_ladderAbove);
    group.add(ladder);
    _ladder = ladder;
    _ladderIt = Interactable(
      kind: InteractKind.ladder,
      x: Ladder.hatch.maxX + 0.2,
      z: Ladder.z,
      radius: 1.3,
      off: true,
    );
    tagInteract(ladder, _ladderIt);
    interactables.add(_ladderIt);

    _floorHatch = _Trapdoor(false);
    _ceilingHatch = _Trapdoor(true);
    group
      ..add(_floorHatch.pivot)
      ..add(_ceilingHatch.pivot);
    final hx = (Ladder.hatch.minX + Ladder.hatch.maxX) / 2, hz = (Ladder.hatch.minZ + Ladder.hatch.maxZ) / 2;
    final hatchHalf = (Ladder.hatch.maxX - Ladder.hatch.minX) / 2;
    _ladderDownShaft = _shaft(round: false, half: hatchHalf, from: 0, to: -2.3, cx: hx, cz: hz);
    _ladderUpShaft = _shaft(round: false, half: hatchHalf, from: wallHeight, to: wallHeight + 2.3, cx: hx, cz: hz);
    group
      ..add(_ladderDownShaft)
      ..add(_ladderUpShaft);

    // The poles: one at each spot, with what goes round it either way.
    for (var index = 0; index < poles_.length; index++) {
      final spot = poles_[index];
      final g = Node(name: 'pole');
      const r = Pole.radius;
      g.add(mesh(cyl(r, r, wallHeight, 14), brass, spot.x, wallHeight / 2, spot.z, false));
      final it = Interactable(kind: InteractKind.pole, pole: index, x: spot.x, z: spot.z, radius: 1.7, off: true);
      final v = _PoleView(spot, index, g, it);
      v.below = mesh(cyl(r, r, 2.3, 14), brass, spot.x, -1.15, spot.z, false);
      v.above = mesh(cyl(r, r, 2.3, 14), brass, spot.x, wallHeight + 1.15, spot.z, false);
      g
        ..add(v.below)
        ..add(v.above);

      // Going down: a railing round three sides of the hole, red with brass caps, open on the fourth.
      final down = Node(name: 'railing');
      const half = Pole.rail, railTop = 1.02;
      void post(double x, double z) {
        down.add(mesh(cyl(0.045, 0.045, railTop, 10), red, x, railTop / 2, z, false));
        down.add(mesh(sphere(0.07, 10, 8), brass, x, railTop + 0.03, z, false));
      }

      // The sides, as (dx0, dz0, dx1, dz1) from the pole, turned so the open one faces `open`.
      final c = math.cos(spot.open).round(), s = math.sin(spot.open).round();
      (double, double) turn(double lx, double lz) => (spot.x + lx * c + lz * s, spot.z - lx * s + lz * c);
      for (final (ax, az, bx, bz) in const [
        (-half, -half, half, -half),
        (-half, -half, -half, half),
        (half, -half, half, half),
      ]) {
        final (x0, z0) = turn(ax, az);
        final (x1, z1) = turn(bx, bz);
        final len = math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0));
        for (final y in [railTop, railTop * 0.55]) {
          down.add(
            place(
              mesh(cyl(0.035, 0.035, len, 8), y == railTop ? brass : red, 0, 0, 0, false),
              x: (x0 + x1) / 2,
              y: y,
              z: (z0 + z1) / 2,
              rot: euler(0, -math.atan2(z1 - z0, x1 - x0), math.pi / 2),
            ),
          );
        }
        post(x0, z0);
        post(x1, z1);
      }
      // The rim of the hole.
      down.add(
        place(
          mesh(torusXY(Pole.hole, 0.035, 6, 32), tc('#2b2d42'), 0, 0, 0, false),
          x: spot.x,
          y: 0.005,
          z: spot.z,
          rot: euler(math.pi / 2),
        ),
      );
      v.down = mergeByMaterial(down);
      g.add(v.down);
      v.downShaft = _shaft(round: true, half: Pole.hole, from: 0, to: -2.3, cx: spot.x, cz: spot.z);
      g.add(v.downShaft);
      // At the top, a brass flange where it's bolted to the ceiling.
      v.flange = mesh(cyl(0.16, 0.2, 0.08, 16), brass, spot.x, wallHeight - 0.04, spot.z, false);
      g.add(v.flange);
      // At the bottom, a fat landing mat.
      final landing = Node(name: 'mat');
      landing.add(mesh(cyl(0.85, 0.9, 0.07, 32), red, spot.x, 0.035, spot.z, false));
      landing.add(
        place(
          mesh(torusXY(0.62, 0.05, 8, 32), tc('#ffd166'), 0, 0, 0, false),
          x: spot.x,
          y: 0.07,
          z: spot.z,
          rot: euler(math.pi / 2),
        ),
      );
      v.landing = mergeByMaterial(landing);
      g.add(v.landing);
      // Coming down from above: a brass collar round the hole it comes out of.
      v.collar = place(
        mesh(torusXY(Pole.hole, 0.06, 8, 32), brass, 0, 0, 0, false),
        x: spot.x,
        y: wallHeight - 0.02,
        z: spot.z,
        rot: euler(math.pi / 2),
      );
      g.add(v.collar);
      v.upShaft = _shaft(round: true, half: Pole.hole, from: wallHeight, to: wallHeight + 2.3, cx: spot.x, cz: spot.z);
      g.add(v.upShaft);
      group.add(g);
      tagInteract(g, it);
      interactables.add(it);
      _poles.add(v);
    }
    set(const StackState());
  }

  Node _take(Node n) {
    _built.add(n);
    group.add(n);
    return n;
  }

  /// The floor you're on: the ladder, the hatches and the poles go where there are floors to go to.
  void set(StackState s) {
    state = s;
    final others = s.others, below = s.below, above = s.above;
    final holes = below ? poles_ : const <PoleSpot>[];
    for (final n in _built) {
      n.detach();
    }
    _built.clear();
    for (final c in _mine) {
      _colliders.remove(c);
    }
    _mine.clear();

    // The floor: planks, with the hatch and the pole's hole cut out when they go somewhere.
    final floorRect = PlanRect(Floor.minX, Floor.maxX, Floor.minZ, Floor.maxZ);
    final floorHoles = [if (below) _Hole.rect(ladderHatch), for (final p in holes) _Hole.circle(p.x, p.z, Pole.hole)];
    _take(mesh(_surface(floorRect, floorHoles, up: true, tile: 6), _planks, 0, 0, 0, false));

    // The slab under it (the garage's ceiling): concrete underneath, a peach band between the floors
    // outside. Where a hole goes through, the garage sees a lid of concrete, not up into the office.
    const bx0 = Floor.minX - wallT, bx1 = Floor.maxX + wallT, bz0 = Floor.minZ - wallT, bz1 = Floor.maxZ + wallT;
    final slabHoles = [
      if (below) _Hole.rect(ladderHatch),
      for (final p in holes) _Hole.circle(p.x, p.z, Pole.hole + 0.02),
    ];
    final slabNode = Node(name: 'slab');
    slabNode.add(
      mesh(_surface(PlanRect(bx0, bx1, bz0, bz1), slabHoles, up: false, y: -slab + 0.005), _concrete, 0, 0, 0, false),
    );
    slabNode.add(
      place(
        boxFaces(bx1 - bx0, slab - 0.01, bz1 - bz0, [_band, _band, null, null, _band, _band]),
        x: (bx0 + bx1) / 2,
        y: -slab / 2 - 0.005,
        z: (bz0 + bz1) / 2,
      ),
    );
    for (final h in slabHoles) {
      final r = h.rect ?? around(h.x, h.z, h.r);
      slabNode.add(
        place(
          mesh(planeXY(r.maxX - r.minX, r.maxZ - r.minZ), _concrete, 0, 0, 0, false),
          x: (r.minX + r.maxX) / 2,
          y: -slab - 0.002,
          z: (r.minZ + r.maxZ) / 2,
          rot: euler(math.pi / 2),
        ),
      );
    }
    _take(slabNode);

    // The ceiling: tiles, wallHeight up, with the hatch and the pole's hole when they come from somewhere.
    final ceilingHoles = [
      if (above) _Hole.rect(ladderHatch),
      if (above)
        for (final p in poles_) _Hole.circle(p.x, p.z, Pole.hole),
    ];
    _take(mesh(_surface(floorRect, ceilingHoles, up: false, y: wallHeight, tile: 1.2), _tiles, 0, 0, 0, false));

    _mine.addAll(stackColliders(s));

    // The ladder, when there's anywhere to climb to.
    _ladder.visible = others;
    _ladderIt.off = !others;
    _ladderBelow.visible = below;
    _ladderAbove.visible = above;
    _floorHatch.pivot.visible = below;
    _ceilingHatch.pivot.visible = above;
    _ladderDownShaft.visible = below;
    _ladderUpShaft.visible = above;
    for (final n in _ladderSigns) {
      n.detach();
    }
    _ladderSigns.clear();
    // Above the window beside it and below its sill, so they cover neither.
    for (final (name, arrow, y) in [(s.up, '⬆', _ladderWindowHead + 0.48), (s.down, '⬇', 0.62)]) {
      if (!others || name == null) continue;
      final text = '🪜 $arrow ${name.length > 22 ? '${name.substring(0, 21)}…' : name}';
      const opts = TextOpts(bg: '#ffd166', size: 44);
      final w = paintText(text, opts).w * kTextScale * 0.7;
      final sign = place(
        textPlane(text, opts),
        x: Floor.minX + 0.02,
        y: y,
        z: Ladder.z + Ladder.width / 2 + 0.15 + w / 2,
        rot: yaw(math.pi / 2),
        scale: 0.7,
      );
      group.add(sign);
      _ladderSigns.add(sign);
    }

    for (final p in _poles) {
      p.group.visible = others;
      p.interactable.off = !others;
      p.down.visible = p.downShaft.visible = p.below.visible = below;
      p.flange.visible = !above;
      p.landing.visible = !below;
      p.collar.visible = p.upShaft.visible = p.above.visible = above;
      final text = below && s.down != null ? '🚒 ⬇ ${s.down}' : '';
      if (text == p.signText) continue;
      p.sign?.detach();
      p.sign = null;
      p.signText = text;
      if (text.isEmpty) continue;
      // Hung on the rail across from the way in, facing it, beside the pole rather than behind it.
      const back = Pole.rail + 0.06, side = Pole.rail * 0.5;
      final c = math.cos(p.spot.open), sn = math.sin(p.spot.open);
      final sign = place(
        textPlane(text, const TextOpts(bg: '#e63946', color: '#ffffff', size: 40, border: '#ffffff')),
        x: p.spot.x - sn * back + c * side,
        y: 0.72,
        z: p.spot.z - c * back - sn * side,
        rot: yaw(p.spot.open),
        scale: 0.6,
      );
      p.sign = sign;
      p.group.add(sign);
    }
    _colliders.addAll(_mine);
  }

  /// Opens the hatches for anyone passing through them (on the ladder, or down in its shaft), and
  /// hides the shafts from anyone looking up from the garage or the street ([eye] is the camera).
  void update(double dt, Iterable<StackPerson> people, vm.Vector3 eye) {
    var floorWant = 0.0, ceilingWant = 0.0;
    for (final p in people) {
      final w = hatchesWanted(p.x, p.y, p.z, onLadder: p.onLadder);
      if (w.floor) floorWant = 1;
      if (w.ceiling) ceilingWant = 1;
    }
    for (final (h, want, where) in [(_floorHatch, floorWant, 'floor'), (_ceilingHatch, ceilingWant, 'ceiling')]) {
      if (!h.pivot.visible || h.open == want) continue;
      if (want > 0 && h.open == 0) onHatch?.call(where, true);
      h.open = want > h.open ? math.min(1, h.open + dt * 4) : math.max(0, h.open - dt * 2.2);
      if (want == 0 && h.open == 0) onHatch?.call(where, false);
      h.show();
    }
    // From the garage or the street (or anywhere outside), the shafts, and the ladder and poles in
    // them, would hang in mid-air under the building or stick up out of its roof.
    final inside =
        eye.x > Floor.minX && eye.x < Floor.maxX && eye.z > Floor.minZ && eye.z < Floor.maxZ && eye.y > -slab;
    _ladderDownShaft.visible = _ladderBelow.visible = inside && _floorHatch.pivot.visible;
    _ladderUpShaft.visible = _ladderAbove.visible = inside && _ceilingHatch.pivot.visible;
    for (final p in _poles) {
      p.downShaft.visible = p.below.visible = inside && p.down.visible;
      p.upShaft.visible = p.above.visible = inside && p.collar.visible;
    }
  }
}

/// The floor (planks in [planks]), the slab under it, the ceiling, the ladder and the fire pole.
/// Their colliders go in [colliders] and change as floors come and go.
FloorStack buildStack(List<Collider> colliders, Material planks) => FloorStack._(colliders, planks);
