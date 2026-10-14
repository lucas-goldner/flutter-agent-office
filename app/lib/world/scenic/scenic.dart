// The scenic loop (see shared scenic.dart), down on the street: the country road itself, and what you
// drive past on it (world/scenic/index.ts). A farm on the way out of town to the east, then the
// pines, with a creek under a bridge; the mountains to the south, snow on their tops, a lake under
// them and a tunnel through a spur of them; up the coast, the beach, the sea and a pier, a lighthouse
// out on a rocky point; and back into town from the west. It's all made once and merged, a square of
// the map at a time so what's lost in the haze isn't drawn (see Scenic.cull), and it drops with the
// street (it's in the office's ground, see Office.setLevel).
//
// Each stretch is built by a file of its own beside this one (the road and its signs, the farm, the
// water, the mountains, the tunnel, the coast, then the trees round all of it), into the kit that
// kit.dart makes, on the CPU alone ([planScenic]); [buildScenic] then makes it into meshes.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/rng.dart';
import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../office/geo.dart' show linColor, setToonTexture;
import '../office/outside.dart' show Glow, NightParts, bulb;
import '../office/parts.dart' show canvasTexture, fill;
import '../sky_view.dart' show hazeMax, hazeReach;
import '../text.dart' show textPlane, kTextScale, paintText;
import '../toon.dart';
import 'coast.dart';
import 'farm.dart';
import 'kit.dart';
import 'mountains.dart';
import 'road.dart';
import 'trees.dart';
import 'tunnel.dart';
import 'water.dart';

/// The whole loop laid out, before anything's drawn: the kit everything went into, and what moves.
class ScenicPlan {
  ScenicPlan._(this.kit, this.sails, this.surf, this.boats, this.beam);
  final ScenicKit kit;
  final Clump sails;
  final Coat surf;
  final List<Boat> boats;
  final Beam beam;

  /// What you bump into out there (they go in with the ground's, and drop with the street).
  List<Collider> get colliders => kit.colliders;
}

/// Lays the loop out: a part at a time, each taking its numbers from kit.rand in turn, in this order,
/// or the trees move.
ScenicPlan planScenic() {
  final kit = ScenicKit();
  final road = buildRoad(kit);
  buildSigns(kit);
  final sails = buildFarm(kit);
  final surf = buildWater(kit, road);
  buildMountains(kit);
  buildTunnel(kit, road);
  final coast = buildCoast(kit);
  plantTrees(kit);
  return ScenicPlan._(kit, sails, surf, coast.boats, coast.beam);
}

/// The scenic loop, as it's drawn.
class Scenic {
  Scenic._(this.group, this.colliders, this._seen, this._sails, this._boats, this._beam, this._surf);

  /// The road and everything along it.
  final Node group;

  /// What you bump into out there.
  final List<Collider> colliders;
  final List<(Node, Seen)> _seen;
  final Node _sails;
  final List<(Node, Boat)> _boats;
  final Node _beam;
  final Material? _surf;

  /// Only what's near enough to see from [eye] (office space) through the haze (its far edge down on
  /// the street at [far], the street at [street]): the rest isn't drawn.
  void cull(vm.Vector3 eye, double street, double far) {
    final up = eye.y - street;
    for (final (node, t) in _seen) {
      final reach = math.min(hazeMax, far * hazeReach(street + math.max(up, t.above), street)) + 10;
      final dx = math.max(math.max(t.minX - eye.x, 0.0), eye.x - t.maxX);
      final dz = math.max(math.max(t.minZ - eye.z, 0.0), eye.z - t.maxZ);
      node.visible = dx * dx + dz * dz < reach * reach;
    }
  }

  /// The windmill's sails, the lighthouse's beam, boats bobbing and the surf: [t] in seconds.
  void update(double t) {
    _sails.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), -t * 0.7);
    _beam.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), t * 0.8);
    for (final (node, b) in _boats) {
      node.position = vm.Vector3(b.x, G - 0.3 + math.sin(t * 1.3 + b.phase) * 0.12, b.z);
      node.rotation = eulerQ(0, b.turn, math.sin(t * 0.9 + b.phase) * 0.06);
    }
    final surf = _surf;
    if (surf != null) {
      setToonColor(surf, ui.Color.from(alpha: 0.45 + 0.3 * math.sin(t * 0.9), red: 1, green: 1, blue: 1));
    }
  }
}

/// How big a map square is, for merging and culling (m).
const double _tile = 120;

/// Builds the scenic loop into [ground] (the office's ground node), its lights into [night].
Scenic buildScenic(Node ground, NightParts night, [ScenicPlan? plan]) {
  final p = plan ?? planScenic();
  final kit = p.kit;
  final root = Node(name: 'scenic');
  ground.add(root);
  final seen = <(Node, Seen)>[];
  final looks = _Looks(night);

  for (final l in kit.root) {
    final n = Node(mesh: Mesh(MeshGeometry.fromMeshData(l.data), looks.of(l.coat)))..castsShadows = l.shadow;
    final at = l.at;
    if (at != null) n.localTransform = at;
    root.add(n);
    final s = l.seen;
    if (s != null) seen.add((n, s));
  }

  // Merged a square of the map at a time, so what's lost in the haze needn't be drawn.
  final byTile = <(int, int), List<Clump>>{};
  for (final list in kit.parts.values) {
    for (final c in list) {
      (byTile[((c.position.x / _tile).floor(), (c.position.z / _tile).floor())] ??= []).add(c);
    }
  }
  for (final MapEntry(key: (tx, tz), value: clumps) in byTile.entries) {
    final merged = looks.merge(clumps);
    root.add(merged);
    // A tree on the edge of a square reaches a little way out of it.
    seen.add((merged, Seen(tx * _tile - 10, (tx + 1) * _tile + 10, tz * _tile - 10, (tz + 1) * _tile + 10)));
  }
  for (final (clumps, x, z, r, above) in [
    (kit.silo, Farm.silo.x, Farm.silo.z, 4.0, 16.0),
    (kit.mill, Farm.windmill.x, Farm.windmill.z, 6.0, 17.0),
    (kit.light, lighthouse.x, lighthouse.z, 12.0, 26.0),
  ]) {
    final merged = looks.merge(clumps);
    root.add(merged);
    seen.add((merged, Seen.around(x, z, r, above)));
  }
  for (final l in kit.labels) {
    final n = textPlane(l.text, l.opts);
    var scale = l.scale;
    final fit = l.fit;
    if (fit != null) scale = math.min(scale, fit / (paintText(l.text, l.opts).w * kTextScale));
    n
      ..position = vm.Vector3(l.x, l.y, l.z)
      ..rotation = yawQ(l.rotY)
      ..scale = vm.Vector3.all(scale);
    root.add(n);
    seen.add((n, Seen.around(l.x, l.z, 4)));
  }

  // What moves.
  final sails = looks.merge([_unplaced(p.sails)])
    ..position = p.sails.position.clone()
    ..name = 'sails';
  root.add(sails);
  seen.add((sails, Seen.around(Farm.windmill.x, Farm.windmill.z, 10, 17)));
  final boats = <(Node, Boat)>[];
  for (final b in p.boats) {
    final n = looks.merge([b.clump])..name = 'boat';
    root.add(n);
    seen.add((n, Seen.around(b.x, b.z, 5)));
    boats.add((n, b));
  }
  final beam = looks.merge(p.beam.cones)
    ..position = vm.Vector3(p.beam.x, p.beam.y, p.beam.z)
    ..name = 'beam';
  root.add(beam);
  seen.add((beam, Seen.around(p.beam.x, p.beam.z, 70, 18 + 8)));
  final glow = looks.made[const Coat.beam('#fff3b8')];
  if (glow is UnlitMaterial) night.glows.add(Glow(beam, glow, 0.4));
  night.halos.addAll(kit.halos);

  final scenic = Scenic._(root, kit.colliders, seen, sails, boats, beam, looks.made[p.surf]);
  scenic.update(0);
  return scenic;
}

/// [c]'s pieces in its own frame, not where it is (its own place, and its turning, are its node's).
Clump _unplaced(Clump c) => Clump()..pieces.addAll(c.pieces);

/// The materials the loop's [Coat]s are made into, one each, and the merging.
class _Looks {
  _Looks(this.night);
  final NightParts night;
  final Map<Coat, Material> made = {};

  /// Every plain piece, whatever its colour: white, times the colour in its vertices.
  late final Material _painted = Toon.create(const ui.Color(0xFFFFFFFF));

  Material of(Coat c) => made[c] ??= switch (c.kind) {
    CoatKind.plain => toon(hex(c.color)),
    CoatKind.bulb => bulb(night, c.color, c.day),
    CoatKind.glow => Toon.cached(hex(c.color), emissive: hex(c.emissive!)),
    CoatKind.flat => () {
      final m = Toon.create(hex(c.color), opacity: c.opacity);
      final art = c.canvas;
      if (art != null) _paint(art).then((t) => setToonTexture(m, t));
      return m;
    }(),
    CoatKind.dim => () {
      final m = UnlitMaterial()
        ..baseColorFactor = linear(hex(c.color))
        ..vertexColorWeight = 0;
      final art = c.canvas;
      if (art != null) _paint(art).then((t) => m.baseColorTexture = t);
      return m;
    }(),
    CoatKind.lining => UnlitMaterial(),
    CoatKind.beam => () {
      final l = linear(hex(c.color));
      return UnlitMaterial()
        ..alphaMode = AlphaMode.blend
        ..baseColorFactor = vm.Vector4(l.x, l.y, l.z, 0);
    }(),
  };

  /// Every piece of [clumps] in one node: the plain ones in one mesh (two: what casts a shadow and what
  /// doesn't), their colours in their vertices; the rest a mesh per material (mergeByColor in the TS).
  Node merge(List<Clump> clumps) {
    final plain = <bool, List<MeshData>>{true: [], false: []};
    final other = <Coat, List<MeshData>>{};
    final otherShadow = <Coat>{};
    for (final c in clumps) {
      final xf = c.xf;
      for (final piece in c.pieces) {
        final d = piece.data;
        final m = xf * piece.xf as vm.Matrix4;
        if (piece.coat.kind == CoatKind.plain) {
          final l = linear(hex(piece.coat.color));
          final colors = Float32List(d.vertexCount * 4);
          for (var i = 0; i < d.vertexCount; i++) {
            colors
              ..[i * 4] = l.x
              ..[i * 4 + 1] = l.y
              ..[i * 4 + 2] = l.z
              ..[i * 4 + 3] = 1;
          }
          plain[piece.shadow]!.add(
            MeshData(
              positions: d.positions,
              vertexCount: d.vertexCount,
              normals: d.normals,
              indices: d.indices,
              colors: colors,
            ).transformed(m),
          );
        } else {
          (other[piece.coat] ??= []).add(
            MeshData(
              positions: d.positions,
              vertexCount: d.vertexCount,
              normals: d.normals,
              indices: d.indices,
              colors: d.colors,
            ).transformed(m),
          );
          if (piece.shadow) otherShadow.add(piece.coat);
        }
      }
    }
    final out = Node(name: 'scenic-merged');
    for (final MapEntry(key: cast, value: list) in plain.entries) {
      if (list.isEmpty) continue;
      out.add(Node(mesh: Mesh(MeshGeometry.fromMeshData(MeshData.merge(list)), _painted))..castsShadows = cast);
    }
    for (final MapEntry(key: coat, value: list) in other.entries) {
      out.add(
        Node(mesh: Mesh(MeshGeometry.fromMeshData(MeshData.merge(list)), of(coat)))
          ..castsShadows = otherShadow.contains(coat),
      );
    }
    return out;
  }
}

/// The pictures the loop's flat things are painted with (canvases in the TS).
final Map<Painted, Future<Texture2D>> _paints = {};

Future<Texture2D> _paint(Painted art) => _paints[art] ??= switch (art) {
  // The street's asphalt: white lines along its edges and a dashed yellow one down the middle, 8 m to
  // a dash and a gap (outside.dart's, the same picture).
  Painted.asphalt => canvasTexture(256, 128, (g) {
    g.drawRect(const ui.Rect.fromLTWH(0, 0, 256, 128), fill(linColor('#5b606c')));
    final white = fill(linColor('#f1f1f1'));
    g.drawRect(const ui.Rect.fromLTWH(0, 6, 256, 4), white);
    g.drawRect(const ui.Rect.fromLTWH(0, 118, 256, 4), white);
    g.drawRect(const ui.Rect.fromLTWH(0, 61, 150, 6), fill(linColor('#ffd166')));
  }),
  Painted.checks => canvasTexture(64, 256, (g) {
    for (var r = 0; r < 16; r++) {
      for (var c = 0; c < 4; c++) {
        g.drawRect(ui.Rect.fromLTWH(c * 16.0, r * 16.0, 16, 16), fill(linColor((r + c).isOdd ? '#1d1d24' : '#f8f8f2')));
      }
    }
  }),
  Painted.wheat => _rows('#e9c46a', '#d4a340'),
  Painted.greens => _rows('#80b918', '#55a630'),
  Painted.creek => _ripples('#4ea8de', '#9bd4f5'),
  Painted.lake => _ripples('#3a86c8', '#76b7e0'),
  Painted.sea => _ripples('#2a9bd4', '#62c2e8'),
};

/// Crops in rows.
Future<Texture2D> _rows(String a, String b) => canvasTexture(64, 64, (g) {
  g.drawRect(const ui.Rect.fromLTWH(0, 0, 64, 64), fill(linColor(a)));
  final row = fill(linColor(b));
  for (var x = 0.0; x < 64; x += 16) {
    g.drawRect(ui.Rect.fromLTWH(x, 0, 8, 64), row);
  }
});

/// Water, with little curls of light on it.
Future<Texture2D> _ripples(String base, String light) => canvasTexture(128, 128, (g) {
  g.drawRect(const ui.Rect.fromLTWH(0, 0, 128, 128), fill(linColor(base)));
  final stroke = ui.Paint()
    ..color = linColor(light)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.5;
  final r = mulberry32(7);
  for (var k = 0; k < 10; k++) {
    final x = r() * 128, y = r() * 128, w = 14 + r() * 26;
    g.drawPath(
      ui.Path()
        ..moveTo(x, y)
        ..quadraticBezierTo(x + w / 2, y - 4, x + w, y),
      stroke,
    );
  }
});
