// What you bump into and what you can use: a port of Collider and Interactable from office.ts.

import 'package:flutter_scene/scene.dart';

/// A box footprint you can't walk through (or can stand on top of, up to [top]).
class Collider {
  Collider({required this.minX, required this.maxX, required this.minZ, required this.maxZ, required this.top, this.bottom});

  final double minX;
  final double maxX;
  final double minZ;
  final double maxZ;

  /// Mutable for the elevator's doors, which stop blocking you once they're open.
  double top;

  /// Underside, for things you walk beneath (the loft). Null means the floor.
  final double? bottom;

  @override
  String toString() => 'Collider($minX..$maxX, $minZ..$maxZ, top $top${bottom == null ? '' : ', bottom $bottom'})';
}

enum InteractKind { desk, issues, pulls, services, queue, tv, coffee, decor, smoke, elevator, gong, dog, jukebox, seat, whiteboard }

/// Something you can use: walk up to it and press E, or click it.
class Interactable {
  Interactable({
    required this.kind,
    required this.x,
    required this.z,
    this.y,
    required this.radius,
    this.deskId,
    this.decorId,
    this.seatId,
    this.off = false,
  });

  final InteractKind kind;
  double x;
  double z;

  /// The floor it's on, when that's not the office floor (the loft's).
  double? y;
  double radius;
  String? deskId;
  String? decorId;
  String? seatId;

  /// Put away for now (a bean bag nobody needs yet): can't be used.
  bool off;
}

/// Which node carries which interactable, for clicking: the old `userData.interact`. A raycast hit
/// walks up the parent chain until it finds one (see [interactableOf]).
final Expando<Interactable> _interact = Expando('interact');

void tagInteract(Node node, Interactable it) => _interact[node] = it;

Interactable? interactableOf(Node? node) {
  for (var n = node; n != null; n = n.parent) {
    final it = _interact[n];
    if (it != null) return it;
  }
  return null;
}
