// The back office through the north wall (world/office/wing.ts; see shared layout's Wing), built out a
// row of desks at a time as the floor fills up: the bit of north wall between the gong and the east
// wall, which comes down when the floor's built out, and behind it the bay, a row deeper each time,
// with a pair of desks down the middle of each row, a rug under them, a lamp over them and a window in
// the east wall. The sign that says there's room to grow hangs on whichever wall is at the back.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import 'package:vector_math/vector_math.dart' as vm;

import '../../ui/theme.dart' show kFallback, kFont;
import '../collider.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart' show shadeHeight;
import 'outside.dart' show NightParts;
import 'parts.dart';
import 'shell.dart';

/// A window in each row of a back office, in the building's east wall (the tower draws the same ones).
List<Opening> wingWindows(int level) => [
  for (var i = 0; i < level; i++) Opening(wall: Side.east, u: wingRowZ(i + 1), width: 2.4, y0: 1.1, y1: 3.3),
];

/// Where the posts under a back office stand: at the back corners of each row.
List<({double x, double z})> wingPosts(int row) {
  final z = wingMinZ(row) - wallT + 0.22;
  return [(x: Wing.minX - wallT + 0.22, z: z), (x: Wing.maxX + wallT - 0.22, z: z)];
}

/// A straight run of outside wall [at] (z for one along x, x for one along z) from [u0] to [u1], with
/// its outdoor side toward [out] (-1 or +1): painted inside in the floor's colours and outside in the
/// building's, and the ends in [endsOut] outside too. It has holes for [holes] (windows), a baseboard
/// and a collider. The back office's walls, and the bit of north wall that comes down for it.
void wallRun(
  Node into,
  List<Collider> cols,
  bool alongX,
  double at,
  double u0,
  double u1,
  int out,
  List<Opening> holes,
  Looks looks,
  (bool, bool) endsOut,
) {
  const t = wallT;
  final outside = tc(Palette.exterior);
  // A box's faces go +x, -x, +y, -y, +z, -z.
  final outFace = alongX ? (out > 0 ? 4 : 5) : (out > 0 ? 0 : 1);
  final endFaces = alongX ? const [1, 0] : const [5, 4];
  final ends = [endsOut.$1, endsOut.$2];
  final paint = <Material?>[
    for (var i = 0; i < 6; i++)
      i == outFace || [for (var k = 0; k < 2; k++) endFaces[k] == i && ends[k]].contains(true) ? outside : looks.wall,
  ];
  final casting = Node(name: 'wall'), above = Node(name: 'wall-above');
  void piece(double a, double b, double y0, double y1) {
    if (b - a < 0.001 || y1 - y0 < 0.001) return;
    if (y0 < shadeHeight && y1 > shadeHeight) {
      piece(a, b, y0, shadeHeight);
      piece(a, b, shadeHeight, y1);
      return;
    }
    final n = alongX ? boxFaces(b - a, y1 - y0, t, paint) : boxFaces(t, y1 - y0, b - a, paint);
    n.castsShadows = y1 <= shadeHeight;
    final u = (a + b) / 2;
    (n.castsShadows ? casting : above).add(
      alongX ? place(n, x: u, y: (y0 + y1) / 2, z: at) : place(n, x: at, y: (y0 + y1) / 2, z: u),
    );
  }

  var u = u0;
  for (final o in [...holes]..sort((a, b) => a.u.compareTo(b.u))) {
    piece(u, o.u - o.width / 2, 0, wallHeight);
    piece(o.u - o.width / 2, o.u + o.width / 2, 0, o.y0);
    piece(o.u - o.width / 2, o.u + o.width / 2, o.y1, wallHeight);
    u = o.u + o.width / 2;
  }
  piece(u, u1, 0, wallHeight);
  final len = u1 - u0, mid = (u0 + u1) / 2;
  casting.add(
    alongX
        ? mesh(box(len, 0.25, t + 0.04), looks.trim, mid, 0.125, at, false)
        : mesh(box(t + 0.04, 0.25, len), looks.trim, at, 0.125, mid, false),
  );
  into
    ..add(mergeByMaterial(casting))
    ..add(mergeByMaterial(above));
  cols.add(
    alongX
        ? Collider(minX: u0, maxX: u1, minZ: at - t / 2, maxZ: at + t / 2, top: 99)
        : Collider(minX: at - t / 2, maxX: at + t / 2, minZ: u0, maxZ: u1, top: 99),
  );
}

/// The sign that says there's room to grow, painted for how far the back office is built out.
void paintGrowSign(Canvas g, double w, double h, int level) {
  final full = level >= Wing.rows;
  g.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = hex(full ? '#e9ecef' : '#ffd166'));
  // Hazard stripes along the top and the bottom, while there's building to do.
  if (!full) {
    final ink = Paint()..color = hex('#2b2d42');
    for (final y in [0.0, h - 34]) {
      g.save();
      g.clipRect(Rect.fromLTWH(0, y, w, 34));
      for (var x = -40.0; x < w + 40; x += 56) {
        g.drawPath(
          Path()
            ..moveTo(x, y + 34)
            ..lineTo(x + 28, y + 34)
            ..lineTo(x + 56, y)
            ..lineTo(x + 28, y)
            ..close(),
          ink,
        );
      }
      g.restore();
    }
  }
  void text(String s, double size, FontWeight weight, double y) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: kFont,
          fontFamilyFallback: kFallback,
          fontSize: size,
          fontWeight: weight,
          color: hex('#2b2d42'),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w - 40);
    tp.paint(g, Offset((w - tp.width) / 2, y - tp.height / 2));
  }

  text(full ? '🏢 As big as it gets' : '🚧 Room to grow', 88, FontWeight.w800, h * 0.4);
  text(
    full
        ? 'The back office is built all the way out'
        : level > 0
        ? 'Press E to go back another row: 2 more desks'
        : 'Press E to knock through: 2 more desks',
    46,
    FontWeight.w700,
    h * 0.68,
  );
}

/// A seat in the back office: its desk, what you bump into at it, and what you use.
typedef WingSeat = ({Node group, Collider collider, Interactable it, Node vacancy});

/// A flat w x d quad facing [up] (or down), with UVs in meters from the floor's corner over [tile]:
/// the room's planks (or ceiling tiles) carried on through, lined up with it.
Geometry _sheet(double minX, double maxX, double minZ, double maxZ, double y, bool up, double tile) {
  final p = <double>[], n = <double>[], uv = <double>[];
  for (final (x, z) in [(minX, minZ), (maxX, minZ), (maxX, maxZ), (minX, maxZ)]) {
    p.addAll([x, y, z]);
    n.addAll([0, up ? 1 : -1, 0]);
    uv.addAll([(x - Floor.minX) / tile, (Floor.maxZ - z) / tile]);
  }
  // Seen from above, counter-clockwise is (0, 3, 2), (0, 2, 1) in x/z with +z toward you.
  final idx = up ? [0, 3, 2, 0, 2, 1] : [0, 1, 2, 0, 2, 3];
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList(p),
      normals: Float32List.fromList(n),
      texCoords: Float32List.fromList(uv),
      indices: idx,
    ),
  );
}

/// The back office, as far as it's built out (see [Wing]).
class WingView {
  WingView._(this._group, this._colliders, this._looks, this._planks, this._ceiling, this._night);

  final Node _group;
  final List<Collider> _colliders;
  final Looks _looks;
  final Material _planks;
  final Material _ceiling;
  final NightParts _night;

  /// The wall where it goes through, standing while there's none.
  final Node _plug = Node(name: 'wing-plug');
  final List<Collider> _plugCols = [];

  /// Each row's rug and lamp, and its seats.
  final List<({Node extras, List<WingSeat> seats})> _rows = [];
  late final Node _sign;
  late final UnlitMaterial _signFace;
  late final Interactable expand;

  /// How many rows it's built out (-1 before it's first set).
  int level = -1;
  final List<Node> _built = [];
  final List<Node> _wet = [];
  List<Collider> _mine = [];
  int _painted = 0;

  /// Builds it out [to] rows (or walls it up): walls, floor, ceiling, desks and all.
  void set(int to) {
    to = math.max(0, math.min(Wing.rows, to));
    if (to == level) return;
    level = to;
    for (final o in _built) {
      o.detach();
    }
    _built.clear();
    for (final w in _wet) {
      _night.wetPanes.remove(w);
    }
    _wet.clear();
    for (final c in _mine) {
      _colliders.remove(c);
    }
    _mine = [];
    Node take(Node o) {
      _group.add(o);
      _built.add(o);
      return o;
    }

    _plug.visible = to == 0;
    if (to == 0) _mine.addAll(_plugCols);
    for (final (i, r) in _rows.indexed) {
      final on = i < to;
      r.extras.visible = on;
      for (final s in r.seats) {
        s.group.visible = on;
        s.it.off = !on;
        if (on) _mine.add(s.collider);
      }
    }

    const t = wallT;
    final back = wingMinZ(to);
    if (to > 0) {
      final shell = Node(name: 'wing-shell');
      wallRun(shell, _mine, false, Wing.minX - t / 2, back, Floor.minZ - t, -1, const [], _looks, (false, false));
      final windows = wingWindows(to);
      wallRun(shell, _mine, false, Floor.maxX + t / 2, back, Floor.minZ, 1, windows, _looks, (false, false));
      wallRun(shell, _mine, true, back - t / 2, Wing.minX - t, Floor.maxX + t, -1, const [], _looks, (true, true));
      for (final o in windows) {
        shell.add(windowIn(o));
        final wet = wetPane(o, _night.wetGlass);
        shell.add(wet);
        _night.wetPanes.add(wet);
        _wet.add(wet);
      }
      take(shell);

      // The floor: the room's planks carried on through (the same texture, lined up with it), on a
      // slab like the room's; and the ceiling's tiles over it.
      const w = Wing.maxX - Wing.minX;
      final d = Floor.minZ - back;
      const midX = (Wing.minX + Wing.maxX) / 2;
      take(mesh(_sheet(Wing.minX, Wing.maxX, back, Floor.minZ, 0, true, 6), _planks, 0, 0, 0, false));
      // Its edges are the band between the floors outside, its underside concrete.
      final band = tc('#e8a87c');
      final concrete = tc('#d3d6dd');
      take(
        place(
          boxFaces(w + 2 * t, slab - 0.01, d, [band, band, concrete, concrete, band, band]),
          x: midX,
          y: -slab / 2 - 0.005,
          z: (back - t + Floor.minZ - t) / 2,
        ),
      );
      take(mesh(_sheet(Wing.minX, Wing.maxX, back, Floor.minZ, wallHeight, false, 1.2), _ceiling, 0, 0, 0, false));
      // Its roof, flush with the tops of its walls, for when there's no floor over it.
      take(
        mesh(box(w + 2 * t, 0.02, d + t), tc('#fffaf3'), midX, wallHeight + 0.03, (back - t + Floor.minZ) / 2, false),
      );
      _mine
        ..add(
          Collider(
            minX: Wing.minX - t,
            maxX: Floor.maxX + t,
            minZ: back - t,
            maxZ: Floor.minZ - t,
            bottom: -slab,
            top: 0,
          ),
        )
        ..add(
          Collider(
            minX: Wing.minX,
            maxX: Floor.maxX,
            minZ: back,
            maxZ: Floor.minZ,
            bottom: wallHeight,
            top: wallHeight + slab,
          ),
        );
    }
    _colliders.addAll(_mine);

    // The sign on whichever wall is at the back: low on the old wall, up over the desks and their lamps
    // once they're there, where it reads from across the room.
    _sign.position = vm.Vector3((Wing.minX + Wing.maxX) / 2, to > 0 ? 5.3 : 2.4, back + 0.05);
    expand.z = back + 0.3;
    _paint(to);
  }

  void _paint(int to) {
    final n = ++_painted;
    canvasTexture(1024, 420, (g) => paintGrowSign(g, 1024, 420, to)).then((tex) {
      if (n != _painted) return;
      _signFace
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
    });
  }
}

/// Builds the back office into [group], walled up (level 0). [desk] builds a seat's desk (see office.dart's).
WingView buildWing({
  required Node group,
  required List<Collider> colliders,
  required List<Interactable> interactables,
  required Looks looks,
  required Material planks,
  required Material ceiling,
  required NightParts night,
  required ({Node group, Node vacancy}) Function(DeskDef def, int index) desk,
}) {
  const t = wallT;
  const midX = (Wing.minX + Wing.maxX) / 2;
  final view = WingView._(group, colliders, looks, planks, ceiling, night);
  wallRun(view._plug, view._plugCols, true, Floor.minZ - t / 2, Wing.minX, Floor.maxX + t, -1, const [], looks, (
    false,
    true,
  ));
  group.add(view._plug);

  for (var i = 0; i < Wing.rows; i++) {
    final row = i + 1;
    final z = wingRowZ(row);
    final extras = Node(name: 'wing-row-$row');
    extras.add(
      mesh(
        roundedBox(3.4, 0.02, Wing.row - 1, 0.5),
        tc(Palette.rugs[(row + 1) % Palette.rugs.length]),
        midX,
        0.011,
        z,
        false,
      ),
    );
    extras.add(place(pendant(wallHeight - 4.05), x: midX, y: 4.05, z: z, scale: 0.8));
    extras.visible = false;
    group.add(extras);
    final seats = <WingSeat>[];
    for (final def in wingDesks.where((d) => d.wing == row)) {
      final built = desk(def, desks.length + wingDesks.indexOf(def));
      built.group.visible = false;
      group.add(built.group);
      const hw = DeskSize.width / 2 - 0.05;
      const hd = DeskSize.depth / 2 - 0.02;
      final collider = Collider(
        minX: def.x - hw,
        maxX: def.x + hw,
        minZ: def.z - hd,
        maxZ: def.z + hd,
        top: DeskSize.height,
      );
      final at = deskSeat(def, 1.25);
      final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: at.x, z: at.z, radius: 1.3, off: true);
      interactables.add(it);
      tagInteract(built.group, it);
      seats.add((group: built.group, collider: collider, it: it, vacancy: built.vacancy));
    }
    view._rows.add((extras: extras, seats: seats));
  }

  // The sign: on the wall at the back, high enough to read from across the room over the desks.
  final sign = Node(name: 'grow-sign');
  sign.add(place(mesh(roundedBox(2.64, 0.06, 1.12, 0.06), tc(Palette.ink), 0, 0, 0, false), rot: euler(math.pi / 2)));
  final face = UnlitMaterial()..baseColorFactor = linear(hex('#ffd166'));
  sign.add(Node(name: 'grow-face', mesh: Mesh(planeXY(2.56, 1.05), face))..position = vm.Vector3(0, 0, 0.032));
  group.add(sign);
  final it = Interactable(kind: InteractKind.expand, x: midX, z: Floor.minZ + 0.3, radius: 2.2);
  interactables.add(it);
  tagInteract(sign, it);
  view
    .._sign = sign
    .._signFace = face
    ..expand = it
    ..set(0);
  return view;
}
