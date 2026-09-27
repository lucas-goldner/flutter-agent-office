// A port of tests/player.test.ts: walking, collisions, stairs, the loft and seats.

import 'dart:math' as math;

import 'package:office_shared/layout.dart';
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/player.dart';
import 'package:flutter_test/flutter_test.dart';

/// The office floor: upstairs, over the garage, so off it you'd drop to the street.
Collider get officeFloor =>
    Collider(minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ, bottom: -slab, top: 0);

Collider box(double minX, double maxX, double minZ, double maxZ, double top, [double? bottom]) =>
    Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, top: top, bottom: bottom);

class Rig {
  Rig(List<Collider> colliders) : player = PlayerController([officeFloor, ...colliders]) {
    player.camYaw = 0;
  }
  final PlayerController player;

  void keys(Set<String> held) => player.input
    ..forward = held.contains('W')
    ..back = held.contains('S')
    ..left = held.contains('A')
    ..right = held.contains('D')
    ..run = held.contains('Shift')
    ..jump = held.contains('Space');

  void frames(int count, [double dt = 1 / 60]) {
    for (var i = 0; i < count; i++) {
      player.update(dt);
    }
  }
}

final Collider desk = box(-1.05, 1.05, -0.53, 0.53, 0.78);

/// Whether a player standing at (x, z) overlaps the collider's footprint.
bool overlaps(Collider c, double x, double z) {
  final dx = x - x.clamp(c.minX, c.maxX), dz = z - z.clamp(c.minZ, c.maxZ);
  return math.sqrt(dx * dx + dz * dz) < 0.32;
}

void main() {
  test('can walk away from a loft post overlapping the randomized spawn area', () {
    final r = Rig([box(9.01, 9.29, 8.01, 8.29, 2.75)]);
    r.player.pos.setValues(9.15, 0, 7.98);
    r.keys({'W'});
    r.frames(30);
    expect(r.player.pos.z, lessThan(6));
    expect(r.player.pos.y, 0);
  });

  test('can escape a furniture overlap without first clearing it in a single frame', () {
    final r = Rig([desk]);
    r.player.pos.setValues(0, 0, 0.2);
    r.keys({'S'});
    r.frames(30);
    expect(r.player.pos.z, greaterThan(2));
    expect(r.player.pos.y, 0);
  });

  test('approaches a desk up to contact even with a slow frame and can then slide along it', () {
    final r = Rig([desk]);
    r.player.pos.setValues(0, 0, 1);
    r.keys({'W', 'Shift'});
    r.frames(1, 0.05);
    expect(r.player.pos.z, inInclusiveRange(0.85 - 1e-6, 0.86));
    r.keys({'W', 'D'});
    r.frames(12);
    expect(r.player.pos.x, greaterThan(0.6), reason: 'did not slide');
    expect(r.player.pos.z, greaterThanOrEqualTo(0.85 - 1e-6), reason: 'must not enter the desk');
    r.keys({'S'});
    r.frames(5);
    expect(r.player.pos.z, greaterThan(1.2), reason: 'must be able to back away immediately');
  });

  test('escaping one collider cannot move deeper into an adjacent collider', () {
    final r = Rig([desk, box(-3, 3, 0.9, 1.1, 99)]);
    r.player.pos.setValues(0, 0, 0.6);
    r.keys({'S'});
    r.frames(20);
    expect(r.player.pos.z, lessThanOrEqualTo(0.6 + 1e-6), reason: 'must not tunnel into the wall to escape the desk');
  });

  test('walks up and down the office stairs without jumping', () {
    final colliders = [
      for (var i = 0; i < Stairs.steps; i++)
        box(Stairs.fromX + i * 0.4, Stairs.fromX + (i + 1) * 0.4, Stairs.minZ, Stairs.maxZ, (i + 1) * 0.2),
      box(Loft.minX, Loft.maxX, Loft.minZ, Loft.maxZ, 3, 2.75),
    ];
    final r = Rig(colliders);
    r.player.pos.setValues(2.6, 0, 12);
    r.keys({'D', 'Shift'});
    r.frames(20, 0.05);
    expect(r.player.pos.x, greaterThan(9.5), reason: 'stuck climbing at ${r.player.pos}');
    expect(r.player.pos.y, 3);
    r.keys({'A', 'Shift'});
    r.frames(20, 0.05);
    expect(r.player.pos.x, lessThan(3), reason: 'stuck descending at ${r.player.pos}');
    expect(r.player.pos.y, 0);
  });

  test('can walk beneath the loft and land on a desk after jumping', () {
    final r = Rig([desk, box(3, 6, -2, 2, 3, 2.75)]);
    r.player.pos.setValues(4, 0, 0);
    r.keys({'D'});
    r.frames(10);
    expect(r.player.pos.x, greaterThan(4.7));
    expect(r.player.pos.y, 0);
    r.player.pos.setValues(0, 1, 0);
    r.player
      ..grounded = false
      ..vy = -2;
    r.keys({});
    r.frames(30);
    // Vector3 keeps 32-bit floats: 0.78 as stored.
    expect(r.player.pos.y, closeTo(0.78, 1e-6));
    expect(r.player.grounded, isTrue);
  });

  test('escaping overlap cannot cross through a thin stair rail on a slow sprint frame', () {
    final r = Rig([box(3, 9, 11.1, 11.2, 99)]);
    for (final z in [11.0, 11.149]) {
      r.player.pos.setValues(6, 0, z);
      final from = r.player.pos.z; // as stored, in 32 bits
      r.keys({'S', 'Shift'});
      r.frames(2, 0.05);
      expect(r.player.pos.z, lessThanOrEqualTo(from), reason: 'crossed the rail from $z');
      r.keys({'W'});
      r.frames(10);
      expect(r.player.pos.z, lessThan(10.4), reason: 'can still retreat away from the rail');
    }
  });

  test('sits on the lounge couch until you walk off, then gets up clear of it', () {
    final couch = box(10, 11, -2.2, 2.2, 0.55);
    final r = Rig([officeFloor, couch, box(12.2, 13.8, -0.8, 0.8, 0.46)]);
    var gotUp = 0;
    r.player.onStand = () => gotUp++;
    final place = seatPlace(seatingById['couch']!, 2);
    r.player.sit(place);
    r.keys({});
    r.frames(30);
    expect([r.player.pos.x, r.player.pos.y, r.player.pos.z], [closeTo(place.x, 1e-6), 0, closeTo(place.z, 1e-6)]);
    expect(r.player.facing, place.rotY);
    expect(r.player.moving, isFalse);
    r.keys({'W'});
    r.frames(1);
    expect(r.player.seat, isNull);
    expect(gotUp, 1);
    expect(overlaps(couch, r.player.pos.x, r.player.pos.z), isFalse, reason: 'still on the couch at ${r.player.pos}');
    r.frames(10);
    expect(r.player.pos.x, greaterThan(11.8), reason: 'walked toward the TV');
    expect(r.player.pos.y, 0);
  });

  test("gets up from the boss's chair behind it, away from the desk", () {
    final r = Rig([box(Loft.minX, Loft.maxX, Loft.minZ, Loft.maxZ, 3, 2.75), box(12.7, 15.3, 9.6, 10.8, 3.8, 3)]);
    r.player.sit(seatPlace(seatingById['boss-chair']!, 0));
    r.keys({'Space'});
    r.frames(1);
    expect(r.player.seat, isNull);
    expect(r.player.pos.z, greaterThan(11.9), reason: 'got up into the desk at ${r.player.pos}');
    r.keys({});
    r.frames(60);
    expect(r.player.pos.y, 3);
  });

  test('gets up off a beanbag to the side when something stands in front of it', () {
    final bag = seatingById['lounge-beanbag-1']!;
    final bean = box(bag.x - 0.5, bag.x + 0.5, bag.z - 0.5, bag.z + 0.5, 0.6);
    final place = seatPlace(bag, 0);
    final ax = place.x + math.sin(bag.rotY) * bag.out;
    final az = place.z + math.cos(bag.rotY) * bag.out;
    final crate = box(ax - 0.4, ax + 0.4, az - 0.4, az + 0.4, 1);
    final r = Rig([officeFloor, bean, crate]);
    r.player
      ..sit(place)
      ..stand();
    for (final c in [bean, crate]) {
      expect(overlaps(c, r.player.pos.x, r.player.pos.z), isFalse, reason: 'stood inside something at ${r.player.pos}');
    }
  });

  test('gets up off the balcony bench onto the deck, clear of the bench', () {
    final deck = box(Balcony.minX, Balcony.maxX, Balcony.minZ, Balcony.maxZ, 0, -slab);
    final bench = box(-10, -8, Balcony.minZ, Balcony.minZ + 0.55, 0.49);
    final r = Rig([deck, bench]);
    for (final i in [0, 1]) {
      r.player.sit(seatPlace(seatingById['bench']!, i));
      r.keys({'S'});
      r.frames(1);
      expect(r.player.seat, isNull);
      expect(overlaps(bench, r.player.pos.x, r.player.pos.z), isFalse, reason: 'stood inside the bench at ${r.player.pos}');
      r.keys({});
      r.frames(30);
      expect(r.player.pos.y, 0, reason: 'still on the balcony');
    }
  });

  test('seat places are only the ones the office has', () {
    expect(seatAt('couch:2')?.seatId, 'couch');
    expect(seatAt('loft-couch:1')?.y, Loft.y);
    for (final bad in ['couch:3', 'couch:', 'couch', 'sofa:0', 'couch:-1', 'couch:1.5', '']) {
      expect(seatAt(bad), isNull, reason: bad);
    }
  });
}
