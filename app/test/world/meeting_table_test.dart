// A full meeting's laptops (in the castle, its tomes) where the worlds put them on the table
// (world/office/meeting_room.dart, world/castle/seats.dart), each the size of the real model with its
// lid up: none reaches into another, and all of each is on the table. A port of
// tests/meeting-table.test.ts (#267). The old test measured the model; this one takes its footprint
// from world/laptop.dart's numbers: the base 0.78 by 0.52 (the tome's 0.8 by 0.54, gold corners
// 0.405 out), 0.02 toward the chair, and the lid, 0.5 tall from a hinge 0.24 back, leaning 0.22 rad past
// upright.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart' show DeskDef, MeetingLaptop, MeetingTable, meetingSeats;
import 'package:office_shared/maps/maps.dart' show Council, planOf;
import 'package:office_shared/nav.dart' show Pt, deskPoint;

/// The least room between two of them.
const double _room = 0.1;

typedef _Footprint = ({double minX, double maxX, double minZ, double maxZ});

final double _lidBack = -0.24 - math.sin(0.22) * 0.5 - 0.0125;
final _Footprint _laptop = (minX: -0.39, maxX: 0.39, minZ: _lidBack, maxZ: 0.02 + 0.26);
final _Footprint _tome = (minX: -0.405, maxX: 0.405, minZ: _lidBack, maxZ: 0.02 + 0.27);

/// Its four corners on the floor plan, at [seat]'s place, `scale` the model's size and `z` toward the chair.
List<Pt> _corners(DeskDef seat, _Footprint f, ({double scale, double z}) at) {
  final x0 = f.minX * at.scale, x1 = f.maxX * at.scale;
  final z0 = f.minZ * at.scale + at.z, z1 = f.maxZ * at.scale + at.z;
  return [deskPoint(seat, x0, z0), deskPoint(seat, x1, z0), deskPoint(seat, x1, z1), deskPoint(seat, x0, z1)];
}

/// How far apart two four-sided shapes are: the widest gap across any of their sides (under 0, they overlap).
double _gap(List<Pt> a, List<Pt> b) {
  var widest = double.negativeInfinity;
  for (final shape in [a, b]) {
    for (var i = 0; i < shape.length; i++) {
      final (x0, z0) = shape[i];
      final (x1, z1) = shape[(i + 1) % shape.length];
      final len = math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0));
      List<double> along(List<Pt> pts) => [for (final (x, z) in pts) (x * (z1 - z0) - z * (x1 - x0)) / len];
      final pa = along(a), pb = along(b);
      widest = [
        widest,
        pb.reduce(math.min) - pa.reduce(math.max),
        pa.reduce(math.min) - pb.reduce(math.max),
      ].reduce(math.max);
    }
  }
  return widest;
}

void _apart(List<DeskDef> seats, List<List<Pt>> shapes, String where) {
  for (var i = 0; i < seats.length; i++) {
    for (var j = i + 1; j < seats.length; j++) {
      final g = _gap(shapes[i], shapes[j]);
      expect(
        g,
        greaterThanOrEqualTo(_room),
        reason: '$where: ${seats[i].id} and ${seats[j].id} are ${g.toStringAsFixed(2)} m apart',
      );
    }
  }
}

void main() {
  test('round the meeting table, no laptop reaches into another, and each is on the table', () {
    final shapes = [
      for (final s in meetingSeats) _corners(s, _laptop, (scale: MeetingLaptop.scale, z: MeetingLaptop.z)),
    ];
    _apart(meetingSeats, shapes, 'the meeting table');
    for (var i = 0; i < shapes.length; i++) {
      for (final (x, z) in shapes[i]) {
        expect(
          (x - MeetingTable.x).abs() < MeetingTable.width / 2 && (z - MeetingTable.z).abs() < MeetingTable.depth / 2,
          isTrue,
          reason: "${meetingSeats[i].id}'s laptop is over the table's edge at ($x, $z)",
        );
      }
    }
  });

  test("round the castle's council table, no tome reaches into another, and each is on the table", () {
    final plan = planOf('castle');
    final shapes = [for (final s in plan.meeting) _corners(s, _tome, Council.tome)];
    expect(shapes.length, meetingSeats.length);
    _apart(plan.meeting, shapes, 'the council table');
    final c = plan.council!;
    for (var i = 0; i < shapes.length; i++) {
      for (final (x, z) in shapes[i]) {
        final d = math.sqrt((x - c.x) * (x - c.x) + (z - c.z) * (z - c.z));
        expect(d, lessThan(Council.radius), reason: "${plan.meeting[i].id}'s tome is over the table's edge");
      }
    }
  });
}
