// A station's airlock (see office_shared's maps/airlock.dart): an inner door in the hull with a
// porthole in it, a chamber sticking out of the hull beyond, and an outer hatch whose two halves part,
// up and down, onto space. Whoever's blown out of it is the workers' to act out (office/send_home.dart),
// and whoever's adrift out there afterwards is theirs to show (world/adrift.dart). A port of
// world/station/airlock.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/airlock.dart' show AirlockSize, hullThickness;
import 'package:office_shared/maps/types.dart' show AirlockPlan;
import 'package:vector_math/vector_math.dart' as vm;

import '../geo.dart' as g3;
import '../office/geo.dart' show Shape2, circleXY, extrudeShape, planeXYuv, transformed, yaw;
import '../office/parts.dart' show canvasTexture;
import '../text.dart';
import '../toon.dart';
import '../world.dart' show AirlockSite;
import 'kit.dart';
import 'shell.dart' show WallFrame;
import 'textures.dart';

/// How high the chamber is inside.
const double _roof = 3.1;
const double _skin = 0.25;

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

/// The airlock, built: see [AirlockSite]. Its alarm's red lamp floods the deck round it, as a pool of
/// the toon shader's lamplight (see the station's mood).
class AirlockView implements AirlockSite {
  AirlockView._(this.plan, this._innerNode, this._jaws, this.doorAt, this.hatchAt, this.outside, this.lampAt, this._h);

  @override
  final AirlockPlan plan;
  final Node _innerNode;
  final List<Node> _jaws;
  final double _h;
  @override
  final vm.Vector3 doorAt;
  @override
  final vm.Vector3 hatchAt;
  @override
  final Node outside;

  /// Where its red lamp hangs (in the station's space), and how bright it is now (three's intensity).
  final vm.Vector3 lampAt;
  double lamp = 0;
  bool alarming = false;

  @override
  void inner(double open) {
    final p = _innerNode.position;
    _innerNode.position = vm.Vector3(p.x, open * (_h + 0.1), p.z);
  }

  @override
  void outer(double open) {
    final e = open * open * (3 - 2 * open);
    for (var i = 0; i < _jaws.length; i++) {
      final p = _jaws[i].position;
      _jaws[i].position = vm.Vector3(p.x, _roof / 2 + (i > 0 ? 1 : -1) * (_roof / 4 + e * (_roof / 2 + 0.05)), p.z);
    }
  }

  @override
  void alarm(bool on) => alarming = on;
}

/// Puts up the airlock in the kit's plan, if it has one.
AirlockView? buildAirlock(Kit kit) {
  final a = kit.plan.airlock;
  if (a == null) return null;
  final mats = kit.mats;
  const t = hullThickness;
  final f = WallFrame(kit.plan.bounds, a.wall);
  final rotY = f.rotY;
  // Everything's built looking out through the wall: +z is out, x runs along it.
  final at = placed(a.door.$1, 0, a.door.$2, rotY, 'airlock');
  vm.Vector3 world(double x, double y, double z) => vm.Vector3(
    a.door.$1 + math.cos(rotY) * x + math.sin(rotY) * z,
    y,
    a.door.$2 - math.sin(rotY) * x + math.cos(rotY) * z,
  );
  const w = AirlockSize.door, h = AirlockSize.height;
  final stripes = unlitPicture(canvasTexture(256, 32, danger));

  // The inner door's frame, with its stripes and its sign over it, and a beacon either side.
  for (final sx in const [-1, 1]) {
    at.add(_m(g3.box(0.28, h + 0.28, t + 0.3), mats.metalDark, sx * (w / 2 + 0.1), (h + 0.28) / 2, t / 2));
  }
  at.add(_m(g3.box(w + 0.56, 0.28, t + 0.3), mats.metalDark, 0, h + 0.1, t / 2));
  at.add(_m(planeXYuv(w + 0.56, 0.24, 0, 0, 2, 1), stripes, 0, h + 0.14, -0.16, false)..rotation = yaw(math.pi));
  at.add(
    textPlane('⚠️ Airlock', const TextOpts(bg: '#2a0f12', color: '#ffd7d7', border: '#d7263d', size: 56))
      ..position = vm.Vector3(0, h + 0.72, -0.06)
      ..rotation = yaw(math.pi)
      ..scale = vm.Vector3.all(0.85),
  );
  for (final sx in const [-1, 1]) {
    at.add(_m(g3.cylinder(0.11, 0.13, 0.1, 12), mats.black, sx * (w / 2 + 0.55), h + 0.14, -0.1, false));
    at.add(
      _m(
        g3.sphereData(0.11, 12, 8, 0, math.pi * 2, 0, math.pi / 2).rotateX(-math.pi / 2).build(),
        mats.warn,
        sx * (w / 2 + 0.55),
        h + 0.14,
        -0.14,
        false,
      ),
    );
  }

  // The inner door: one slab with a porthole, sliding up into the hull.
  final slab = Shape2(24)
    ..moveTo(-w / 2, 0)
    ..lineTo(w / 2, 0)
    ..lineTo(w / 2, h)
    ..lineTo(-w / 2, h);
  slab.holes.add(circle(0, 1.6, 0.48, 28));
  final inner = Node(name: 'inner-door')
    ..add(_m(transformed(extrudeShape(slab, 0.16), vm.Matrix4.translationValues(0, 0, -0.08)), mats.metal))
    ..add(_m(g3.torus(0.5, 0.05, 8, 28), mats.metalDark, 0, 1.6, -0.09, false))
    ..add(_m(circleXY(0.48, 28, true), mats.glass, 0, 1.6, 0, false))
    ..add(_m(g3.box(w - 0.3, 0.1, 0.2), mats.warn, 0, 0.5, 0, false))
    ..position = vm.Vector3(0, 0, t / 2);
  at.add(inner);

  // The chamber: a box out of the hull, lit red when it matters.
  const cw = AirlockSize.width, depth = AirlockSize.depth;
  const zc = t + depth / 2;
  at.add(_m(g3.box(cw + 2 * _skin, _skin, depth), mats.metalDark, 0, -_skin / 2, zc));
  at.add(_m(g3.box(cw + 2 * _skin, _skin, depth), mats.hullDark, 0, _roof + _skin / 2, zc));
  for (final sx in const [-1, 1]) {
    at.add(_m(g3.box(_skin, _roof, depth), mats.hull, sx * (cw / 2 + _skin / 2), _roof / 2, zc));
    // A rail to hold on to, for all the good it does, and a strip of light down each side.
    at.add(
      _m(
        g3.cylinderData(0.03, 0.03, depth - 1, 8).rotateX(math.pi / 2).build(),
        mats.metal,
        sx * (cw / 2 - 0.12),
        1.05,
        zc,
        false,
      ),
    );
    at.add(_m(g3.box(0.04, 0.08, depth - 0.6), mats.warn, sx * (cw / 2 - 0.02), _roof - 0.25, zc, false));
  }
  // The wall round the inner door, on the chamber's side.
  at.add(_m(g3.box(cw, _roof - h, 0.02), mats.hullDark, 0, (_roof + h) / 2, t + 0.01, false));

  // The outer hatch: two halves that part, one up and one down, in a heavy frame with the stripes all round it.
  const zo = t + depth;
  for (final sx in const [-1, 1]) {
    at.add(_m(g3.box(0.3, _roof + 2 * _skin, 0.4), mats.metalDark, sx * (cw / 2 + _skin / 2), _roof / 2, zo));
  }
  for (final y in const [-_skin / 2, _roof + _skin / 2]) {
    at.add(_m(g3.box(cw + 2 * _skin + 0.3, 0.3, 0.4), mats.metalDark, 0, y, zo));
  }
  for (final y in const [-0.42, _roof + 0.42]) {
    at.add(_m(planeXYuv(cw + 0.8, 0.22, 0, 0, 2, 1), stripes, 0, y, zo + 0.21, false));
  }
  final jaws = <Node>[];
  for (final sy in const [-1, 1]) {
    final jaw = Node(name: 'jaw')
      ..add(_m(g3.box(cw, _roof / 2, 0.18), mats.metal))
      ..add(_m(g3.box(cw - 0.5, 0.08, 0.22), mats.warn, 0, -sy * (_roof / 4 - 0.12), 0, false))
      ..position = vm.Vector3(0, _roof / 2 + sy * _roof / 4, zo);
    at.add(jaw);
    jaws.add(jaw);
  }
  kit.group.add(at);

  final outside = Node(name: 'adrift');
  kit.group.add(outside);
  final view = AirlockView._(
    a,
    inner,
    jaws,
    world(0, 1.4, t / 2),
    world(0, _roof / 2, zo),
    outside,
    // A red lamp over the inner door that floods the deck round it when the alarm's going.
    world(0, h + 0.2, -1.2),
    h,
  );
  final dark = linear(hex('#3a0d0d')), bright = linear(hex('#ff3b30'));
  kit.pulses.add(
    Pulse(
      (k) {
        final on = view.alarming;
        final mix = on ? 0.25 + 0.75 * k : 0.0;
        mats.warn.baseColorFactor = dark + (bright - dark) * mix;
        view.lamp = on ? 3 + 9 * k : 0;
      },
      2.4,
      0,
    ),
  );
  return view;
}
