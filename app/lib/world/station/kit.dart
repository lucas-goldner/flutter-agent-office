// What every part of the station is built with: its sizes, the Kit the builder hands each part, the
// materials in the map's colors, and how a part says what's in the way. A port of
// world/station/kit.ts.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan;
import 'package:office_shared/maps/props.dart' show boxFootprint;
import 'package:vector_math/vector_math.dart' as vm;

import '../castle/kit.dart' show shade, tc;
import '../collider.dart';
import '../office/geo.dart' show yaw;
import '../office/office.dart' show DeskView, Gong;
import '../toon.dart';

export '../castle/kit.dart' show seeded, shade, tc, texToon;

/// The most light pods that light the deck for real (the rest just glow). Two of the toon shader's
/// eight pools are left for the airlock's alarm.
const int maxLights = 6;
const double tableTop = 0.78;
const double benchTop = 0.45;

/// How big one tile of the hull's panelling and of the deck's plating is (m).
const double panel = 3;
const double plate = 2;

/// What pulses: [set] is handed 0–1, [rate] times a second, each [phase] out of step.
class Pulse {
  Pulse(this.set, this.rate, this.phase);
  final void Function(double k) set;
  final double rate;
  final double phase;
}

/// What turns about y, and how fast (rad/s).
class Spinner {
  Spinner(this.obj, this.speed);
  final Node obj;
  final double speed;
  double angle = 0;
}

class Mats {
  Mats({
    required this.hull,
    required this.hullDark,
    required this.panel,
    required this.metal,
    required this.metalDark,
    required this.black,
    required this.pad,
    required this.white,
    required this.glow,
    required this.accent,
    required this.lamp,
    required this.warn,
    required this.glass,
  });

  /// The hull's panels, pale, and the darker metal of its frames, ribs and furniture.
  final Material hull, hullDark, panel, metal, metalDark, black;

  /// Padding: seats, and the captain's chair.
  final Material pad, white;

  /// Light that's the map's own (its `glow`): holograms, displays, the pods overhead.
  final UnlitMaterial glow;

  /// Light in the floor's color, so each project's deck is its own: the strips in the deck, the lines round the walls.
  final UnlitMaterial accent;

  /// A light pod's lens, and warning red.
  final UnlitMaterial lamp, warn;
  final UnlitMaterial glass;
}

/// What the builder hands each part: where to put meshes, what's in the way, and what moves or glows.
class Kit {
  Kit({required this.plan, required this.group, required this.mats, required this.height, required this.glow});

  final MapPlan plan;
  final Node group;

  /// Merged into a few draw calls at the end: whatever never moves, and has no picture on it.
  final Node still = Node(name: 'station-still');
  final List<Collider> colliders = [];
  final List<Interactable> interactables = [];
  final Mats mats;
  final double height;

  /// The map's own light, '#rrggbb' (its palette's `glow`): what the displays draw in.
  final String glow;

  /// Every seat by id, as it's built.
  final Map<String, DeskView> desks = {};

  /// Where the light pods that light the deck for real hang (in the station's space).
  final List<vm.Vector3> lights = [];
  final List<Spinner> spinners = [];
  final List<Pulse> pulses = [];
  Gong? gong;

  /// The top of whatever the deck is at (x, z): the bridge, or the deck.
  double floorAt(double x, double z) {
    var top = 0.0;
    for (final c in colliders) {
      if (c.top < 50 && !c.fence && c.top > top && x > c.minX && x < c.maxX && z > c.minZ && z < c.maxZ) top = c.top;
    }
    return top;
  }
}

/// Something that glows: unlit, '#rrggbb', see-through when [opacity] is under 1.
UnlitMaterial lit(String color, {double opacity = 1}) {
  final m = basic(hex(color), opacity: opacity);
  if (opacity < 1) m.alphaMode = AlphaMode.blend;
  return m;
}

/// The colors of the hull and the rest, as the map's palette has them.
Mats stationMaterials({required String hull, required String panel, required String metal, required String glow}) =>
    Mats(
      hull: tc(hull),
      hullDark: tc(shade(hull, -0.12)),
      panel: tc(panel),
      metal: tc(metal),
      metalDark: tc(shade(metal, -0.12)),
      black: tc('#1b212b'),
      pad: tc('#2c3644'),
      white: tc('#f4f7fb'),
      glow: lit(glow),
      accent: lit(glow),
      lamp: lit('#f4fbff'),
      warn: lit('#3a0d0d'),
      // Blended in linear light, where three blended in sRGB: as faint as the old client's 0.07 looked.
      glass: lit('#a9d8ff', opacity: 0.015),
    );

/// Something [w] by [d] at (x, z), turned [rotY], standing [top] high: in the way (see Collider).
void collide(Kit kit, double x, double z, double w, double d, double rotY, double top, {bool fence = false}) {
  final (minX, maxX, minZ, maxZ) = boxFootprint(x, z, w, d, rotY);
  kit.colliders.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, top: top, fence: fence));
}

/// A group at (x, y, z), turned [rotY].
Node placed(double x, double y, double z, [double rotY = 0, String name = '']) => Node(name: name)
  ..position = vm.Vector3(x, y, z)
  ..rotation = yaw(rotY);

/// Pieces with a picture on them (see [Batch.tileBox]), gathered as they're built and merged into one
/// mesh per material, their pictures' coordinates kept (mergeByMaterial drops them).
class Batch {
  final Map<Material, ({List<double> p, List<double> n, List<double> uv})> _by = {};

  ({List<double> p, List<double> n, List<double> uv}) _of(Material m) =>
      _by[m] ??= (p: <double>[], n: <double>[], uv: <double>[]);

  /// A box whose picture tiles across it at [tile] meters a repeat, laid out by where it is in the
  /// world (its middle at [at]), so the panels on one piece of wall line up with the next piece's.
  void tileBox(double w, double h, double d, double tile, vm.Vector3 at, Material mat) {
    final out = _of(mat);
    final hx = w / 2, hy = h / 2, hz = d / 2;
    void face(vm.Vector3 c, vm.Vector3 r, vm.Vector3 u) {
      final normal = r.cross(u)..normalize();
      final corners = [c - r - u, c + r - u, c + r + u, c - r - u, c + r + u, c - r + u];
      for (final v in corners) {
        final x = v.x + at.x, y = v.y + at.y, z = v.z + at.z;
        out.p.addAll([x, y, z]);
        out.n.addAll([normal.x, normal.y, normal.z]);
        // three's v runs up the picture; the engine's runs down it.
        if (normal.x.abs() > 0.5) {
          out.uv.addAll([z / tile, -y / tile]);
        } else if (normal.y.abs() > 0.5) {
          out.uv.addAll([x / tile, z / tile]);
        } else {
          out.uv.addAll([x / tile, -y / tile]);
        }
      }
    }

    face(vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz), vm.Vector3(0, hy, 0));
    face(vm.Vector3(-hx, 0, 0), vm.Vector3(0, 0, hz), vm.Vector3(0, hy, 0));
    face(vm.Vector3(0, hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz));
    face(vm.Vector3(0, -hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, hz));
    face(vm.Vector3(0, 0, hz), vm.Vector3(hx, 0, 0), vm.Vector3(0, hy, 0));
    face(vm.Vector3(0, 0, -hz), vm.Vector3(-hx, 0, 0), vm.Vector3(0, hy, 0));
  }

  /// One mesh per material.
  Node build([String name = 'batch']) {
    final g = Node(name: name);
    for (final e in _by.entries) {
      final b = e.value;
      if (b.p.isEmpty) continue;
      final geo = MeshGeometry.fromMeshData(
        MeshData.build(
          positions: Float32List.fromList(b.p),
          normals: Float32List.fromList(b.n),
          texCoords: Float32List.fromList(b.uv),
        ),
      );
      g.add(mesh(geo, e.key, 0, 0, 0, false));
    }
    _by.clear();
    return g;
  }
}

/// Points round a circle of radius [r] at (cx, cy), [n] of them (a porthole's hole).
List<vm.Vector2> circle(double cx, double cy, double r, int n) => [
  for (var i = 0; i < n; i++)
    vm.Vector2(cx + r * math.cos(i / n * math.pi * 2), cy + r * math.sin(i / n * math.pi * 2)),
];

/// An unlit material with a picture on it (a display, stripes): white until the picture's painted.
UnlitMaterial unlitPicture(Future<Texture2D> tex, {bool blend = false}) {
  final m = UnlitMaterial();
  if (blend) {
    m
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = vm.Vector4(1, 1, 1, 0);
  }
  tex
      .then((t) {
        m
          ..baseColorTexture = t
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
      })
      .catchError((Object e) => debugPrint('station picture failed: $e'));
  return m;
}
