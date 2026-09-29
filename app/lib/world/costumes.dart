// Holiday costumes (see holiday.dart for the decorations): a port of world/costumes.ts. The workers
// go as zombies for Halloween and elves for Christmas, people wear a warlock's hat or a Santa hat,
// and the dog gets bat wings and a witch's hat, or antlers and a glowing red nose. Each piece is
// built here and hung on the model that wears it.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show setEmissive;
import 'geo.dart';
import 'toon.dart';

/// What undead skin is mixed toward, for Halloween: a warlock's hands and face.
const Color kUndeadSkin = Color(0xFFA3BF98);

/// What a zombie worker's skin is mixed toward.
const Color kZombie = Color(0xFF7FA36B);

/// Mixes two colours in sRGB, like THREE.Color.lerp on the old client's colours.
Color mixColor(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// A colour times [k] (THREE.Color.multiplyScalar).
Color scaleColor(Color c, double k) => Color.from(
  alpha: 1,
  red: (c.r * k).clamp(0.0, 1.0),
  green: (c.g * k).clamp(0.0, 1.0),
  blue: (c.b * k).clamp(0.0, 1.0),
);

final vm.Vector3 _z = vm.Vector3(0, 0, 1);

GeoData _moved(GeoData g, double x, double y, double z) => g.transform(vm.Matrix4.translationValues(x, y, z));
GeoData _scaled(GeoData g, double x, double y, double z) => g.transform(vm.Matrix4.diagonal3Values(x, y, z));

/// Triangles (indices into [pts]) filling a simple polygon, any winding: ear clipping.
List<(int, int, int)> triangulate(List<vm.Vector2> pts) {
  final n = pts.length;
  final out = <(int, int, int)>[];
  if (n < 3) return out;
  var area = 0.0;
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    area += a.x * b.y - b.x * a.y;
  }
  // Worked on counter-clockwise.
  final left = area < 0 ? [for (var i = n - 1; i >= 0; i--) i] : [for (var i = 0; i < n; i++) i];
  double cross(vm.Vector2 o, vm.Vector2 a, vm.Vector2 b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  bool inside(vm.Vector2 p, vm.Vector2 a, vm.Vector2 b, vm.Vector2 c) =>
      cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0;
  var guard = 0;
  while (left.length > 3 && guard++ < 10000) {
    var clipped = false;
    for (var i = 0; i < left.length; i++) {
      final ia = left[(i + left.length - 1) % left.length], ib = left[i], ic = left[(i + 1) % left.length];
      final a = pts[ia], b = pts[ib], c = pts[ic];
      if (cross(a, b, c) <= 1e-12) continue;
      var ear = true;
      for (final j in left) {
        if (j == ia || j == ib || j == ic) continue;
        if (inside(pts[j], a, b, c)) {
          ear = false;
          break;
        }
      }
      if (!ear) continue;
      out.add((ia, ib, ic));
      left.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) break;
  }
  if (left.length == 3) out.add((left[0], left[1], left[2]));
  return out;
}

/// A flat outline (x, y), filled (three's ShapeGeometry), facing +z.
GeoData shapeData(List<vm.Vector2> outline) {
  final g = GeoData();
  final pts = [...outline];
  if (pts.length > 1 && (pts.first - pts.last).length < 1e-9) pts.removeLast();
  final ids = [for (final p in pts) g.vertex(p.x, p.y, 0, 0, 0, 1)];
  for (final (a, b, c) in triangulate(pts)) {
    g.tri(ids[a], ids[b], ids[c]);
  }
  return g;
}

/// Points along a quadratic Bézier from [a] (not included) to [b], in [n] steps.
Iterable<vm.Vector2> _quad(vm.Vector2 a, vm.Vector2 c, vm.Vector2 b, [int n = 6]) sync* {
  for (var i = 1; i <= n; i++) {
    final t = i / n;
    final u = 1 - t;
    yield vm.Vector2(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y);
  }
}

// ---- The workers --------------------------------------------------------------------------------

/// The worker's bean-shaped body (see Worker): a capsule standing at y 0.4..0.7, 0.28 round.
const double _beanY = 0.55, _beanHalf = 0.15, _beanR = 0.28;

/// A point on the bean at height [y], [a] round from the front (+z; +x is positive), [out] off its
/// surface, and which way is out there.
({vm.Vector3 at, vm.Vector3 normal}) onBean(double y, double a, [double out = 0]) {
  final c = y.clamp(_beanY - _beanHalf, _beanY + _beanHalf);
  final dy = y - c;
  final rr = math.sqrt(math.max(0, _beanR * _beanR - dy * dy));
  final normal = vm.Vector3(math.sin(a) * rr, dy, math.cos(a) * rr)..normalize();
  return (at: vm.Vector3(math.sin(a) * rr, y, math.cos(a) * rr) + normal * out, normal: normal);
}

/// Lays [m] on the bean at ([y], [a]), its +z pointing out of the surface.
Node _stick(Node m, double y, double a, [double out = 0]) {
  final p = onBean(y, a, out);
  m.position = p.at;
  m.rotation = vm.Quaternion.fromTwoVectors(_z, p.normal);
  return m;
}

/// A stitched-up line over the bean from ([from].y, [from].a) to [to]: thread, with cross stitches.
void _stitches(Node g, (double, double) from, (double, double) to, int crossings, [double wobble = 0]) {
  final thread = toon(hex('#3b2a2a'));
  final pts = <vm.Vector3>[];
  for (var i = 0; i <= 8; i++) {
    final k = i / 8;
    final y = from.$1 + (to.$1 - from.$1) * k + math.sin(k * 9) * wobble;
    pts.add(onBean(y, from.$2 + (to.$2 - from.$2) * k, 0.004).at);
  }
  // The thread: a short rod between each pair of points.
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final d = b - a;
    final rod = mesh(cylinder(0.009, 0.009, d.length, 5), thread, 0, 0, 0, false)
      ..position = (a + b) * 0.5
      ..rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), d.normalized());
    g.add(rod);
  }
  final stitch = box(0.075, 0.014, 0.014);
  for (var i = 0; i < crossings; i++) {
    final k = (i + 0.5) / crossings;
    final f = k * (pts.length - 1);
    final j = math.min(f.floor(), pts.length - 2);
    final at = pts[j] + (pts[j + 1] - pts[j]) * (f - j);
    final along = (pts[j + 1] - pts[j])..normalize();
    final normal = vm.Vector3(at.x, at.y - at.y.clamp(_beanY - _beanHalf, _beanY + _beanHalf), at.z)..normalize();
    final across = normal.cross(along)..normalize();
    final up = normal.cross(across)..normalize();
    final basis = vm.Matrix3.columns(across, up, normal);
    final s = mesh(stitch, thread, at.x, at.y, at.z, false)
      ..rotation = (vm.Quaternion.fromRotation(basis) * vm.Quaternion.axisAngle(_z, i.isOdd ? 0.25 : -0.25));
    g.add(s);
  }
}

/// A zombie's bits, over the worker's own body: a stitched grin and scar, a drooping eyelid, bandages, rot.
Node zombieWorker(Material skin) {
  final g = Node(name: 'zombie');
  // A grim stitched mouth across the front, and a scar over the top of the head.
  _stitches(g, (0.5, -0.42), (0.5, 0.42), 6, 0.012);
  _stitches(g, (0.93, -0.9), (0.82, -0.1), 4);
  // The right eye (the one on +x) half shut under a drooping lid.
  g.add(
    mesh(sphere(0.098, 14, 8, 0, math.pi * 2, 0, math.pi / 2), skin, 0.11, 0.7, 0.235, false)
      ..scale = vm.Vector3(1.04, 1, 0.64)
      ..rotation = euler(0.55, 0, -0.25),
  );
  // Rotten patches.
  final rot = toon(hex('#4d6b3c'));
  for (final (y, a, r) in const [(0.38, 0.55, 0.06), (0.62, -1.95, 0.075), (0.84, 2.3, 0.06), (0.3, -2.8, 0.05)]) {
    g.add(_stick(mesh(sphere(r, 10, 8), rot, 0, 0, 0, false), y, a, -0.012)..scale = vm.Vector3(1, 1, 0.3));
  }
  // Grubby bandages round the middle, one wrap coming loose.
  final linen = toon(hex('#e3dcc4'));
  for (final (y, tilt, r) in const [(0.33, 0.22, 0.284), (0.4, -0.16, 0.29)]) {
    g.add(
      mesh(torus(r, 0.028, 6, 28), linen, 0, y, 0)
        ..rotation = euler(math.pi / 2 + tilt, 0)
        ..scale = vm.Vector3(1, 1, 1.4),
    );
  }
  final loose = _stick(mesh(box(0.06, 0.16, 0.012), linen), 0.26, 2.2, 0.01);
  loose.rotation = loose.rotation * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), 0.25);
  g.add(loose);
  g.add(_stick(mesh(sphere(0.022, 8, 6), toon(hex('#8f1d21')), 0, 0, 0, false), 0.36, -0.7, 0.03));
  return g;
}

/// An elf's hat, whose pom-pom is the worker's status bulb (it sits right on the tip).
Node elfHat() {
  final g = Node(name: 'elf-hat');
  g.add(mesh(torus(0.205, 0.05, 8, 28), toon(hex('#fffaf3')), 0, 0.9, 0)..rotation = euler(math.pi / 2, 0));
  g.add(mesh(cone(0.2, 0.3, 24), toon(hex('#2e9e48')), 0, 1.05, 0));
  g.add(mesh(torus(0.135, 0.02, 6, 24), toon(hex('#d62828')), 0, 1.0, 0, false)..rotation = euler(math.pi / 2, 0));
  return g;
}

/// An elf's pointy ears (in the worker's own colour), a jester's collar with bells, and a belt.
Node elfWorker(Material skin) {
  final g = Node(name: 'elf');
  for (final sx in [-1.0, 1.0]) {
    g.add(mesh(cone(0.045, 0.17, 10), skin, sx * 0.27, 0.85, 0)..rotation = euler(0, 0, -sx * 1.05));
  }
  final flap = _moved(_scaled(coneData(0.075, 0.15, 4).rotateX(math.pi), 1, 1, 0.35), 0, -0.07, 0.01).build();
  final red = toon(hex('#d62828'));
  final green = toon(hex('#2e9e48'));
  final gold = toon(hex('#ffc233'));
  for (var i = 0; i < 10; i++) {
    final a = i / 10 * math.pi * 2;
    final f = _stick(mesh(flap, i.isOdd ? green : red, 0, 0, 0, false), 0.57, a, 0.012);
    f.rotation = f.rotation * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -0.3);
    g.add(f);
    if (i.isEven) g.add(_stick(mesh(sphere(0.022, 8, 6), gold, 0, 0, 0, false), 0.43, a, 0.045));
  }
  g.add(mesh(torus(0.273, 0.03, 6, 28), toon(hex('#2b2d42')), 0, 0.3, 0, false)..rotation = euler(math.pi / 2, 0));
  g.add(_stick(mesh(box(0.1, 0.075, 0.02), gold, 0, 0, 0, false), 0.3, 0, 0.03));
  g.add(_stick(mesh(box(0.055, 0.035, 0.02), toon(hex('#2b2d42')), 0, 0, 0, false), 0.3, 0, 0.037));
  return g;
}

/// A curly-toed elf boot with a bell on the toe, for a worker's foot (its capsule's middle is 0,0,0).
Node elfBoot() {
  final g = Node(name: 'elf-boot');
  final red = toon(hex('#d62828'));
  g.add(mesh(sphere(0.075, 12, 8), red, 0, -0.06, 0.02)..scale = vm.Vector3(1, 0.65, 1.3));
  final toe = Node()
    ..position = vm.Vector3(0, -0.06, 0.09)
    ..rotation = euler(-0.75, 0);
  toe.add(mesh(_moved(coneData(0.04, 0.13, 8).rotateX(math.pi / 2), 0, 0, 0.06).build(), red, 0, 0, 0, false));
  toe.add(mesh(sphere(0.022, 8, 6), toon(hex('#ffc233')), 0, 0, 0.135, false));
  g.add(toe);
  return g;
}

// ---- People -------------------------------------------------------------------------------------

/// A tall, crooked warlock's hat for a person's head (its middle is 0,0,0, 0.34 round; the face looks down +z).
Node warlockHat() {
  final g = Node(name: 'warlock-hat');
  final felt = toon(hex('#2d1b3d'));
  g.add(mesh(cylinder(0.54, 0.54, 0.03, 32), felt, 0, 0.25, 0));
  g.add(mesh(cylinder(0.13, 0.31, 0.42, 24), felt, 0, 0.46, 0));
  g.add(mesh(cylinder(0.305, 0.312, 0.08, 24), toon(hex('#ff7b00')), 0, 0.3, 0));
  g.add(mesh(box(0.11, 0.08, 0.02), toon(hex('#ffd166')), 0, 0.3, 0.315, false));
  final bend = Node()
    ..position = vm.Vector3(0, 0.66, 0)
    ..rotation = euler(-0.55, 0, 0.25);
  bend.add(mesh(cone(0.13, 0.36, 20), felt, 0, 0.17, 0));
  g.add(bend);
  g.rotation = euler(-0.15, 0);
  return g;
}

/// A floppy Santa hat for a person's head.
Node santaHat() {
  final g = Node(name: 'santa-hat');
  final red = toon(hex('#d62828'));
  final fur = toon(hex('#fffaf3'));
  g.add(mesh(torus(0.31, 0.075, 10, 30), fur, 0, 0.21, 0)..rotation = euler(math.pi / 2, 0));
  g.add(mesh(cylinder(0.17, 0.31, 0.3, 24), red, 0, 0.36, 0));
  final flop = Node()
    ..position = vm.Vector3(0, 0.5, 0)
    ..rotation = euler(-0.35, 0, -1.05);
  flop.add(mesh(cone(0.17, 0.4, 20), red, 0, 0.18, 0));
  flop.add(mesh(sphere(0.085, 12, 10), fur, 0, 0.4, 0));
  g.add(flop);
  g.rotation = euler(-0.15, 0);
  return g;
}

// ---- The dog ------------------------------------------------------------------------------------

/// A bat wing's outline in its own plane: root at 0,0, reaching out along +x, leading edge up.
List<vm.Vector2> batWingOutline() {
  final pts = <vm.Vector2>[vm.Vector2(0, 0.05), vm.Vector2(0.4, 0.13), vm.Vector2(1, 0.1)];
  void q(double cx, double cy, double x, double y) => pts.addAll(_quad(pts.last, vm.Vector2(cx, cy), vm.Vector2(x, y)));
  q(0.86, 0, 0.78, -0.12);
  q(0.66, -0.02, 0.52, -0.14);
  q(0.4, -0.04, 0.26, -0.13);
  q(0.14, -0.04, 0, -0.08);
  return pts;
}

/// A bat wing, root at 0,0,0, reaching out along +x (its leading edge toward +z, the dog's head).
Geometry batWingGeometry(double span) =>
    _scaled(shapeData(batWingOutline()).rotateX(math.pi / 2), span, 1, span).build();

/// Bat wings on the dog's back (a torso-local group), and the pivots that flap them.
({Node group, List<Pivot> wings}) dogBatWings() {
  final group = Node(name: 'bat-wings');
  final mat = toonUnique(hex('#2b1d3a'))..doubleSided = true;
  final geo = batWingGeometry(0.42);
  final wings = <Pivot>[];
  for (final sx in [-1.0, 1.0]) {
    final pivot = Pivot()..position = vm.Vector3(sx * 0.07, 0.17, 0.26);
    pivot.add(mesh(geo, mat)..scale = vm.Vector3(sx, 1, 1));
    group.add(pivot.node);
    wings.add(pivot);
  }
  return (group: group, wings: wings);
}

/// A little witch's hat between the dog's ears (head-local).
Node dogWitchHat() {
  final g = Node(name: 'witch-hat');
  final felt = toon(hex('#3c1f5c'));
  g.add(mesh(cylinder(0.12, 0.12, 0.012, 24), felt));
  g.add(mesh(cylinder(0.066, 0.068, 0.03, 16), toon(hex('#ff7b00')), 0, 0.02, 0, false));
  final tip = Node()
    ..position = vm.Vector3(0, 0.03, 0)
    ..rotation = euler(-0.35, 0, 0.2);
  tip.add(mesh(cone(0.066, 0.2, 16), felt, 0, 0.1, 0));
  g.add(tip);
  g
    ..position = vm.Vector3(0, 0.13, -0.02)
    ..rotation = euler(-0.2, 0, 0.15);
  return g;
}

/// Reindeer antlers (head-local).
Node dogAntlers() {
  final g = Node(name: 'antlers');
  final horn = toon(hex('#8b5a2b'));
  Geometry tine(double len) => _moved(capsuleData(0.012, len, 4, 6), 0, len / 2, 0).build();
  for (final sx in [-1.0, 1.0]) {
    final beam = Node()
      ..position = vm.Vector3(sx * 0.06, 0.11, -0.01)
      ..rotation = euler(-0.25, 0, -sx * 0.45);
    beam.add(mesh(tine(0.16), horn));
    beam.add(mesh(tine(0.06), horn, 0, 0.07, 0)..rotation = euler(0.95, 0));
    beam.add(mesh(tine(0.055), horn, 0, 0.13, 0)..rotation = euler(0, 0, -sx * 0.8));
    g.add(beam);
  }
  return g;
}

/// Rudolph's nose, which glows (head-local, over the dog's own).
({Node nose, PreprocessedMaterial glow}) dogRedNose() {
  final glow = toonUnique(hex('#ff3030'));
  setEmissive(glow, hex('#ff1a1a'), 0.8);
  return (nose: mesh(sphere(0.04, 12, 10), glow, 0, -0.005, 0.225, false), glow: glow);
}

/// A red scarf round the dog's neck, over its collar, one end hanging down its chest (head-local).
Node dogScarf() {
  final g = Node(name: 'scarf');
  final red = toon(hex('#d62828'));
  g.add(mesh(torus(0.1, 0.042, 8, 20), red, 0, -0.11, -0.05)..rotation = euler(math.pi / 2 + 0.5, 0));
  final end = Node()
    ..position = vm.Vector3(0.075, -0.15, 0)
    ..rotation = euler(0.35, 0.5, 0.12);
  end.add(mesh(box(0.055, 0.15, 0.025), red, 0, -0.07, 0));
  for (var i = 0; i < 2; i++) {
    end.add(mesh(box(0.057, 0.02, 0.027), toon(hex('#fffaf3')), 0, -0.07 - i * 0.05, 0, false));
  }
  g.add(end);
  return g;
}

// ---- Your hands (first person) ------------------------------------------------------------------

/// An open sleeve end flaring out toward the hand, in rags (along -z, like the hands' arms).
Node raggedCuff(Material mat) {
  const n = 16;
  final g = GeoData();
  // An open tube from r 0.066 (z -0.075, toward the hand) to 0.1 (z +0.075), its hand end ragged.
  final rows = <List<int>>[];
  for (var row = 0; row <= 2; row++) {
    final v = row / 2;
    final r = 0.066 + (0.1 - 0.066) * v;
    var z = -0.075 + 0.15 * v;
    final ids = <int>[];
    for (var i = 0; i <= n; i++) {
      final a = i / n * math.pi * 2;
      var zz = z;
      if (row == 0) {
        final k = ((a + math.pi) / (math.pi * 2) * n).round();
        zz += k.isOdd ? 0.045 : (k % 3 != 0 ? 0.012 : 0);
      }
      ids.add(g.vertex(math.cos(a) * r, math.sin(a) * r, zz, math.cos(a), math.sin(a), 0));
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
  return mesh(g.build(), mat, 0, 0, 0.11, false);
}

/// An undead warlock's hand, in camera space like the hands' own (-z is forward): a bony grey-green
/// palm, long crooked fingers with black claws, and a thumb on the inside ([side] is 1 for the right).
Node warlockHand(int side, Material skin) {
  final g = Node(name: 'warlock-hand');
  g.add(mesh(sphere(0.054, 18, 12), skin, 0, 0, 0, false)..scale = vm.Vector3(1, 0.62, 1.2));
  final claw = toon(hex('#1e1522'));
  final knuckle = sphere(0.013, 8, 6);
  Geometry bone(double len) => _moved(capsuleData(0.0092, len, 4, 8).rotateX(math.pi / 2), 0, 0, -len / 2).build();
  final tip = _moved(coneData(0.0095, 0.038, 8).rotateX(-math.pi / 2), 0, 0, -0.019).build();
  for (final (fx, len) in const [(-0.032, 0.056), (-0.011, 0.064), (0.011, 0.06), (0.031, 0.046)]) {
    final x = fx * side;
    g.add(mesh(knuckle, skin, x, 0.02, -0.052, false));
    final base = Node()
      ..position = vm.Vector3(x, 0.01, -0.058)
      ..rotation = euler(-0.2, x * 2.2);
    base.add(mesh(bone(len), skin, 0, 0, 0, false));
    final joint = Node()
      ..position = vm.Vector3(0, 0, -len)
      ..rotation = euler(-0.55, 0);
    joint.add(mesh(knuckle, skin, 0, 0, 0, false));
    joint.add(mesh(bone(len * 0.8), skin, 0, 0, 0, false));
    final nail = Node()
      ..position = vm.Vector3(0, 0, -len * 0.8)
      ..rotation = euler(-0.4, 0);
    nail.add(mesh(tip, claw, 0, 0, 0, false));
    joint.add(nail);
    base.add(joint);
    g.add(base);
  }
  // The thumb, on the inside of the hand.
  final thumb = Node()
    ..position = vm.Vector3(-side * 0.045, -0.004, -0.02)
    ..rotation = euler(-0.1, side * 0.75);
  thumb.add(mesh(bone(0.04), skin, 0, 0, 0, false));
  final tnail = Node()
    ..position = vm.Vector3(0, 0, -0.04)
    ..rotation = euler(-0.35, 0);
  tnail.add(mesh(tip, claw, 0, 0, 0, false));
  thumb.add(tnail);
  g.add(thumb);
  return g;
}

/// Green witch-fire swirling round a warlock's hand: sparks to move each frame (see Hands.update).
({Node group, List<Node> sparks}) witchFire(int count) {
  final group = Node(name: 'witch-fire');
  final mat = basic(hex('#5dff2e'));
  final geo = sphere(0.01, 6, 4);
  final sparks = [for (var i = 0; i < count; i++) mesh(geo, mat, 0, 0, 0, false)];
  for (final s in sparks) {
    group.add(s);
  }
  return (group: group, sparks: sparks);
}
