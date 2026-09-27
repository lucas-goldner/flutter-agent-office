// The office's materials and mesh helpers: a port of world/toon.ts.
//
// The toon look is assets/materials/toon.fmat, a port of MeshToonMaterial with the old client's
// 3-step ramp. Its shader is loaded once in [Toon.init]; after that materials are made
// synchronously, so building the office reads like the three.js code it came from.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The light every toon material is shaded with. The sky changes it and calls [Toon.updateLight].
class ToonLight {
  vm.Vector3 sunDirection = vm.Vector3(0.45, 0.8, 0.35);
  Color sunColor = const Color(0xFFFFFFFF);
  // The old client's intensities over pi, as three.js's Lambert BRDF divides them.
  double sunIntensity = 2.2 / math.pi;
  Color sky = const Color(0xFFFFF5E6);
  Color ground = const Color(0xFFC9A27A);
  double hemiIntensity = 1.5 / math.pi;
  double ambient = 0.5 / math.pi;

  /// Lamplight filling the office and the garage at night: linear colour x strength.
  vm.Vector3 officeLight = vm.Vector3.zero();
  vm.Vector3 garageLight = vm.Vector3.zero();

  /// Up to eight pools of lamplight: position and reach, and linear colour x power.
  final List<vm.Vector4> lampPos = List.generate(8, (_) => vm.Vector4.zero());
  final List<vm.Vector3> lampColor = List.generate(8, (_) => vm.Vector3.zero());
  double wet = 0;
  double snow = 0;
}

class _Shader {
  _Shader(this.fragment, this.metadata, this.vertex);
  final gpu.Shader fragment;
  final Map<String, Object?> metadata;
  final Map<String, gpu.Shader>? vertex;

  PreprocessedMaterial make() =>
      PreprocessedMaterial(fragmentShader: fragment, metadata: metadata, vertexShaders: vertex);
}

class Toon {
  Toon._();

  static final ToonLight light = ToonLight();
  static late _Shader _opaque;
  static late _Shader _alpha;
  static final List<PreprocessedMaterial> _all = [];
  static final Map<String, PreprocessedMaterial> _cache = {};

  /// Loads the toon shaders. Call once, after Scene.initializeStaticResources().
  static Future<void> init() async {
    _opaque = await _load('assets/materials/toon.fmat');
    _alpha = await _load('assets/materials/toon_alpha.fmat');
  }

  static Future<_Shader> _load(String path) async {
    late _Shader shader;
    await loadFmatMaterial(
      path,
      factory: ({required fragmentShader, required metadata, vertexShaders}) {
        shader = _Shader(fragmentShader, metadata, vertexShaders);
        return shader.make();
      },
    );
    return shader;
  }

  static PreprocessedMaterial create(Color color, {Color? emissive, double opacity = 1}) {
    final m = (opacity < 1 ? _alpha : _opaque).make();
    m.parameters.setColor('base_color', color.withValues(alpha: opacity));
    if (emissive != null) m.parameters.setColor('emissive', emissive);
    _apply(m);
    _all.add(m);
    return m;
  }

  static PreprocessedMaterial cached(Color color, {Color? emissive, double opacity = 1}) {
    final key = '${color.toARGB32()}|${emissive?.toARGB32()}|$opacity';
    return _cache[key] ??= create(color, emissive: emissive, opacity: opacity);
  }

  /// Pushes [light] to every toon material: a handful of uniforms each.
  static void updateLight() {
    for (final m in _all) {
      _apply(m);
    }
  }

  static vm.Matrix4 _columns(Iterable<vm.Vector4> cols) {
    final m = vm.Matrix4.zero();
    var i = 0;
    for (final c in cols) {
      m.setColumn(i++, c);
    }
    return m;
  }

  static void _apply(PreprocessedMaterial m) {
    final l = light;
    vm.Vector4 col(vm.Vector3 c) => vm.Vector4(c.x, c.y, c.z, 0);
    m.parameters
      ..setVec3('office_light', l.officeLight)
      ..setVec3('garage_light', l.garageLight)
      ..setMat4('lamp_pos_a', _columns(l.lampPos.take(4)))
      ..setMat4('lamp_pos_b', _columns(l.lampPos.skip(4)))
      ..setMat4('lamp_col_a', _columns(l.lampColor.take(4).map(col)))
      ..setMat4('lamp_col_b', _columns(l.lampColor.skip(4).map(col)))
      ..setFloat('wet', l.wet)
      ..setFloat('snow', l.snow)
      ..setVec3('sun_direction', l.sunDirection.normalized())
      ..setColor('sun_color', l.sunColor)
      ..setFloat('sun_intensity', l.sunIntensity)
      ..setColor('sky_color', l.sky)
      ..setColor('ground_color', l.ground)
      ..setFloat('hemi_intensity', l.hemiIntensity)
      ..setFloat('ambient', l.ambient);
  }
}

/// A cached toon material in one colour, like toon() in the old client.
PreprocessedMaterial toon(Color color, {Color? emissive, double opacity = 1}) =>
    Toon.cached(color, emissive: emissive, opacity: opacity);

/// A toon material of its own, for a colour that changes (a shirt, a status bulb).
PreprocessedMaterial toonUnique(Color color, {Color? emissive}) => Toon.create(color, emissive: emissive);

/// Sets a toon material's colour (for [toonUnique] ones).
void setToonColor(Material m, Color color, {Color? emissive}) {
  if (m is! PreprocessedMaterial) return;
  m.parameters.setColor('base_color', color);
  if (emissive != null) m.parameters.setColor('emissive', emissive);
}

/// An unlit material in one colour: screens, glass, signs (MeshBasicMaterial).
UnlitMaterial basic(Color color, {double opacity = 1}) =>
    UnlitMaterial()..baseColorFactor = linear(color, opacity);

/// A node carrying one mesh, placed at x, y, z (mesh() in the old client).
Node mesh(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) {
  final n = Node(mesh: Mesh(geo, mat));
  n.position = vm.Vector3(x, y, z);
  n.castsShadows = shadow;
  return n;
}

/// A box with rounded corners in plan: a rounded rectangle w x d, extruded h tall, centred.
Geometry roundedBox(double w, double h, double d, [double r = 0.06]) {
  r = math.min(r, math.min(w / 2, d / 2));
  // The outline, counter-clockwise seen from above (+y), four segments a corner like the TS.
  final pts = <vm.Vector2>[];
  void corner(double cx, double cz, double a0) {
    for (var i = 0; i <= 4; i++) {
      final a = a0 + (math.pi / 2) * i / 4;
      pts.add(vm.Vector2(cx + math.cos(a) * r, cz + math.sin(a) * r));
    }
  }

  final hx = w / 2 - r, hz = d / 2 - r;
  corner(hx, hz, 0);
  corner(-hx, hz, math.pi / 2);
  corner(-hx, -hz, math.pi);
  corner(hx, -hz, 3 * math.pi / 2);
  return prism(pts, h);
}

/// The outline [pts] (x, z; counter-clockwise from above, convex) extruded [h] tall, centred on
/// y = 0, with flat normals.
Geometry prism(List<vm.Vector2> pts, double h) {
  final y0 = -h / 2, y1 = h / 2;
  final p = <double>[];
  void tri(double ax, double ay, double az, double bx, double by, double bz, double cx, double cy, double cz) =>
      p.addAll([ax, ay, az, bx, by, bz, cx, cy, cz]);
  final n = pts.length;
  // Caps: fans from the first point. Counter-clockwise from above faces up once z is flipped.
  for (var i = 1; i < n - 1; i++) {
    final a = pts[0], b = pts[i], c = pts[i + 1];
    tri(a.x, y1, a.y, c.x, y1, c.y, b.x, y1, b.y);
    tri(a.x, y0, a.y, b.x, y0, b.y, c.x, y0, c.y);
  }
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    tri(a.x, y0, a.y, a.x, y1, a.y, b.x, y1, b.y);
    tri(a.x, y0, a.y, b.x, y1, b.y, b.x, y0, b.y);
  }
  return geometryFrom(Float32List.fromList(p));
}

/// A triangle-list geometry from positions alone, with flat normals worked out per face.
Geometry geometryFrom(Float32List positions, {Float32List? colors}) =>
    MeshGeometry.fromMeshData(MeshData.build(positions: positions, colors: colors));

/// Merges every mesh under [root] into one per material: a few draw calls instead of dozens, for
/// things that never move on their own (mergeByMaterial in the old client).
Node mergeByMaterial(Node root) {
  final inv = vm.Matrix4.inverted(root.globalTransform);
  final byMat = <Material, List<MeshData>>{};
  final noShadow = <Material>{};
  void visit(Node node) {
    final m = node.mesh;
    if (m != null) {
      final xf = inv * node.globalTransform as vm.Matrix4;
      for (final prim in m.primitives) {
        final data = prim.geometry.extractMeshData();
        final flat = MeshData(
          positions: data.positions,
          vertexCount: data.vertexCount,
          normals: data.normals,
          indices: data.indices,
        ).transformed(xf);
        (byMat[prim.material] ??= []).add(flat);
        if (!node.castsShadows) noShadow.add(prim.material);
      }
    }
    for (final c in node.children) {
      visit(c);
    }
  }

  visit(root);
  final out = Node(name: '${root.name}-merged');
  for (final e in byMat.entries) {
    final geo = MeshGeometry.fromMeshData(MeshData.merge(e.value));
    out.add(mesh(geo, e.key, 0, 0, 0, !noShadow.contains(e.key)));
  }
  return out;
}

/// sRGB colour to linear RGBA, the way three.js's ColorManagement converts hex colours.
vm.Vector4 linear(Color c, [double alpha = 1]) =>
    vm.Vector4(_lin(c.r), _lin(c.g), _lin(c.b), alpha * c.a);

double _lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// '#rrggbb' to a Color.
Color hex(String s) => Color(0xFF000000 | int.parse(s.replaceFirst('#', ''), radix: 16));
