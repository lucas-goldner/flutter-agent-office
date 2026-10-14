// Cartoon supercars for the garage (a port of features/cars/world.ts's supercar): side profiles
// extruded across the car, in parts that change while it's driven: the roof comes off while anyone's in
// it, and the front wheels turn to steer.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../toon.dart';
import 'geo.dart';

import 'package:office_shared/garage.dart' show Car, CarKind, carSeats, CarSeat;

import 'parts.dart';

const double _width = 1.9;
const double _wheelR = 0.36;
const double _wheelY = 0.37;

/// Wheel arches cut up into the bottom of a side profile, rear to front.
void _sill(Shape2 s, double rearX, double frontX, List<double> axles, [double bottom = 0.2]) {
  const r = 0.46;
  final dx = math.sqrt(r * r - math.pow(_wheelY - bottom, 2));
  final a0 = math.pi + math.atan2(_wheelY - bottom, dx);
  final a1 = -math.atan2(_wheelY - bottom, dx);
  s.moveTo(rearX, bottom);
  for (final ax in axles) {
    s.lineTo(ax - dx, bottom);
    s.absarc(ax, _wheelY, r, a0, a1, true);
  }
  s.lineTo(frontX, bottom);
}

/// Side profiles (x runs rear to front along the car, y up): the painted body and the glass cabin on
/// top, and the windshield that's left of the cabin with the roof off (its foot, and how far up).
({Shape2 body, Shape2 cabin, double axle, (double, double, double, double) screen}) _profiles(CarKind kind) {
  final body = Shape2(10);
  final cabin = Shape2(10);
  if (kind == CarKind.lambo) {
    // All wedge: a knife-edge nose, a flat hood running straight up into the windshield.
    const axle = 1.42;
    _sill(body, -2.22, 2.15, [-axle, axle]);
    body
      ..lineTo(2.32, 0.3)
      ..lineTo(2.3, 0.44)
      ..lineTo(0.95, 0.74)
      ..lineTo(-1.75, 0.86)
      ..lineTo(-2.3, 0.82)
      ..lineTo(-2.32, 0.38);
    cabin
      ..moveTo(1.05, 0.66)
      ..lineTo(-0.05, 1.1)
      ..lineTo(-0.85, 1.1)
      ..lineTo(-2.05, 0.8)
      ..lineTo(-2.05, 0.66);
    return (body: body, cabin: cabin, axle: axle, screen: (1.05, 0.66, 0.34, 0.95));
  }
  // Curves: a rounded nose, a long hood and big rear haunches.
  const axle = 1.36;
  _sill(body, -2.2, 2.12, [-axle, axle]);
  body
    ..quadraticCurveTo(2.3, 0.22, 2.28, 0.42)
    ..quadraticCurveTo(1.7, 0.64, 0.55, 0.76)
    ..lineTo(-1.1, 0.84)
    ..quadraticCurveTo(-2.05, 0.96, -2.25, 0.72)
    ..lineTo(-2.26, 0.3);
  cabin
    ..moveTo(0.65, 0.68)
    ..quadraticCurveTo(0.05, 1.16, -0.55, 1.13)
    ..quadraticCurveTo(-1.35, 1.1, -1.85, 0.78)
    ..lineTo(-1.85, 0.68);
  return (body: body, cabin: cabin, axle: axle, screen: (0.68, 0.68, 0.22, 0.98));
}

/// Extrudes a side profile [width] across, centred, and turns it so the front points to +z.
Geometry _extrude(Shape2 shape, double width, double bevel) {
  final depth = width - bevel * 2;
  final geo = extrudeShape(shape, depth, bevel: bevel);
  return transformed(geo, vm.Matrix4.rotationY(-math.pi / 2)..translateByVector3(vm.Vector3(0, 0, -depth / 2)));
}

/// A car's model, in parts that change while it's driven.
class CarModel {
  CarModel(this.root, this.top, this.open, this.wheels);
  final Node root;

  /// The painted roof and the glass round the cabin: off while anyone's in it, so their heads fit.
  final Node top;

  /// With the roof off: the windshield, the two seats and the steering wheel.
  final Node open;

  /// The front wheels, which turn to steer.
  final List<Node> wheels;
}

/// A cartoon supercar, nose toward +z, wheels on y = 0. A Lambo is a lime, orange or yellow wedge
/// with a wing; a Ferrari is curvy, round taillights and a yellow badge.
CarModel supercar(CarKind kind, String color) {
  final g = Node(name: 'car-body');
  final paint = tc(color);
  final glass = tc('#233347');
  final tire = tc('#1f1f26');
  final rim = tc(kind == CarKind.lambo ? '#e9b949' : '#d9dbe3');
  final lamp = tc('#fff6c9', emissive: '#b8a960');
  final tail = tc('#ff2d3f', emissive: '#a3001a');
  final dark = tc('#2b2d42');
  final lambo = kind == CarKind.lambo;
  final p = _profiles(kind);
  g.add(mesh(_extrude(p.body, _width, 0.05), paint));
  final tireGeo = transformed(cyl(_wheelR, _wheelR, 0.28, 18), rotZ(math.pi / 2));
  final rimGeo = transformed(cyl(_wheelR * 0.6, _wheelR * 0.6, 0.3, 10), rotZ(math.pi / 2));
  Node wheel(double x, double z) => Node(name: 'wheel')
    ..position = vm.Vector3(x, _wheelY, z)
    ..add(mesh(tireGeo, tire))
    ..add(mesh(rimGeo, rim));
  final wheels = <Node>[];
  for (final sx in [-1, 1]) {
    final x = sx * (_width / 2 - 0.16);
    g.add(wheel(x, -p.axle));
    wheels.add(wheel(x, p.axle));
  }
  const l = Car.length / 2;
  if (lambo) {
    for (final sx in [-1, 1]) {
      g.add(
        place(mesh(box(0.5, 0.06, 0.26), lamp), x: sx * 0.62, y: 0.46, z: l - 0.14, rot: euler(-0.25, sx * 0.25, 0)),
      );
      // Air intakes behind the doors.
      g.add(mesh(box(0.03, 0.26, 0.7), dark, sx * (_width / 2 + 0.03), 0.56, -1.0));
      g.add(mesh(box(0.06, 0.26, 0.06), dark, sx * 0.7, 0.98, -2.0));
    }
    g.add(mesh(box(1.7, 0.08, 0.05), tail, 0, 0.7, -l - 0.03));
    // The rear wing, on two struts.
    g.add(mesh(box(1.9, 0.05, 0.36), dark, 0, 1.12, -2.02));
  } else {
    final light = transformed(cyl(0.08, 0.08, 0.05, 12), rotX(math.pi / 2));
    for (final sx in [-1, 1]) {
      g.add(place(mesh(box(0.42, 0.08, 0.3), lamp), x: sx * 0.64, y: 0.5, z: l - 0.3, rot: euler(-0.35, sx * 0.3, 0)));
      for (final off in [0.28, 0.62]) {
        g.add(mesh(light, tail, sx * off, 0.62, -l + 0.18));
      }
      // The badge on each flank.
      g.add(mesh(box(0.02, 0.12, 0.09), tc('#ffd400'), sx * (_width / 2 + 0.03), 0.6, 0.9));
    }
    g.add(mesh(box(0.1, 0.12, 0.03), tc('#ffd400'), 0, 0.46, l - 0.04));
    g.add(mesh(box(0.9, 0.1, 0.05), dark, 0, 0.3, l - 0.06));
  }

  // The cabin: glass all round under a painted roof.
  final closed = Node(name: 'car-top')
    ..add(mesh(_extrude(p.cabin, 1.42, 0.03), glass))
    ..add(mesh(box(1.3, 0.05, lambo ? 0.8 : 0.7), paint, 0, lambo ? 1.11 : 1.13, lambo ? -0.45 : -0.3));

  // Roof off: a windshield up from the hood, bucket seats, and a wheel in front of the driver.
  final open = Node(name: 'car-open');
  final (z0, y0, z1, y1) = p.screen;
  final paneLen = math.sqrt(math.pow(z1 - z0, 2) + math.pow(y1 - y0, 2));
  open.add(
    place(
      mesh(box(1.36, 0.04, paneLen), glass),
      y: (y0 + y1) / 2,
      z: (z0 + z1) / 2,
      rot: euler(math.atan2(y1 - y0, z0 - z1)),
    ),
  );
  for (final s in carSeats.values) {
    open.add(place(mesh(box(0.5, 0.6, 0.1), dark), x: s.x, y: 0.95, z: s.z - 0.34, rot: euler(-0.18)));
  }
  final driver = carSeats[CarSeat.driver]!;
  open.add(place(mesh(torusXY(0.16, 0.028, 6, 18), dark), x: driver.x, y: 0.98, z: driver.z + 0.5, rot: euler(-0.45)));

  final root = Node(name: 'car');
  final top = mergeByMaterial(closed);
  final inside = mergeByMaterial(open)..visible = false;
  root
    ..add(mergeByMaterial(g))
    ..add(top)
    ..add(inside);
  for (final w in wheels) {
    root.add(w);
  }
  return CarModel(root, top, inside, wheels);
}
