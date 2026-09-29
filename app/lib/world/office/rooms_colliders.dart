// What you bump into among the games and rooms (see rooms.dart), worked out from the layout alone,
// as office.ts pushes them while it builds.

import 'dart:math' as math;

import 'package:office_shared/layout.dart';
import 'package:office_shared/nav.dart' show deskPoint;

import '../collider.dart';
import '../hoop.dart' show hoopColliders;

/// A board agent's kiosk and the agent behind it, back to the wall (they all stand by the north
/// wall) so nobody squeezes in behind, and up over the agent's head so nobody hops on it.
Collider kioskCollider(DeskDef def) {
  final corners = [
    for (final t in [-1, 1])
      for (final sz in [-Kiosk.depth / 2, Kiosk.stand + 0.35]) deskPoint(def, t * Kiosk.width / 2, sz),
  ];
  final xs = corners.map((c) => c.$1), zs = corners.map((c) => c.$2);
  return Collider(
    minX: xs.reduce(math.min),
    maxX: xs.reduce(math.max),
    minZ: Floor.minZ,
    maxZ: zs.reduce(math.max),
    top: 1.5,
  );
}

Collider cabinetCollider() => Collider(
  minX: Cabinet.x - 0.45,
  maxX: Floor.maxX,
  minZ: Cabinet.z - Cabinet.width / 2 - 0.02,
  maxZ: Cabinet.z + Cabinet.width / 2 + 0.02,
  top: Cabinet.height,
);

/// Everything the games and rooms put in your way.
List<Collider> roomsColliders() => [for (final d in stations) kioskCollider(d), cabinetCollider(), ...hoopColliders()];
