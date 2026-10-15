// Renders the 2D map to a PNG for a look (set SNAPSHOT_DIR to keep it): the office, the office with its
// back office built out, and the castle's and the space station's plans.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_office/office2d/pixel_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/maps/maps.dart';

Future<ui.Image> _draw(void Function(ui.Canvas c) paint) async {
  final rec = ui.PictureRecorder();
  paint(ui.Canvas(rec));
  return rec.endRecording().toImage(MapBounds.width, MapBounds.height);
}

Future<void> _keep(ui.Image img, String name) async {
  final dir = Platform.environment['SNAPSHOT_DIR'];
  if (dir == null) return;
  // Scaled up 3x without smoothing, as the view shows it.
  final rec2 = ui.PictureRecorder();
  final c2 = ui.Canvas(rec2)..scale(3);
  c2.drawImage(img, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.none);
  final big = await rec2.endRecording().toImage(img.width * 3, img.height * 3);
  final png = await big.toByteData(format: ui.ImageByteFormat.png);
  File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  tearDown(MapBounds.office);

  test('the floor plan draws, the size the map says', () async {
    MapBounds.office();
    final img = await _draw(paintFloorPlan);
    expect((img.width, img.height), (MapBounds.width, MapBounds.height));
    await _keep(img, 'map');
  });

  test('built out, the map reaches north over the back office, with its desks', () async {
    MapBounds.office();
    final h0 = MapBounds.height;
    MapBounds.office(Wing.rows);
    expect(MapBounds.height, greaterThan(h0));
    expect(MapBounds.minZ, lessThan(wingMinZ(Wing.rows)));
    final img = await _draw((c) => paintFloorPlan(c, wing: Wing.rows));
    expect((img.width, img.height), (MapBounds.width, MapBounds.height));
    await _keep(img, 'map-wing');
  });

  test("a map of its own draws from its plan, round its own hall", () async {
    for (final id in ['castle', 'station']) {
      final plan = planOf(id);
      MapBounds.plan(plan.bounds);
      expect(MapBounds.minX, lessThan(plan.bounds.minX));
      expect(MapBounds.maxZ, greaterThan(plan.bounds.maxZ));
      final img = await _draw((c) => paintMapPlan(c, plan));
      expect((img.width, img.height), (MapBounds.width, MapBounds.height), reason: id);
      await _keep(img, 'map-$id');
    }
  });
}
