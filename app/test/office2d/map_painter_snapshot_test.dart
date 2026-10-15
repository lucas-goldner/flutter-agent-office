// Renders the 2D office with people on it to a PNG for a look (set SNAPSHOT_DIR to keep it).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_office/office2d/map_painter.dart';
import 'package:agent_office/office2d/office2d_view.dart' show workerEmoji;
import 'package:agent_office/office2d/pixel_map.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/nav.dart' show deskPoint;

void main() {
  test('the live layer draws people, workers and lights over the floor plan', () async {
    final rec = ui.PictureRecorder();
    paintFloorPlan(ui.Canvas(rec));
    final map = await rec.endRecording().toImage(MapBounds.width, MapBounds.height);
    final statuses = MapStatus.values;
    final scene = MapScene(
      t: 0.2,
      dog: (x: 4.0, z: 3.0),
      heading: (x: 2.0, z: 1.0),
      hover: const MapHover(x: Whiteboard.x, z: Whiteboard.z, radius: 1.5, title: '📝 Whiteboard'),
      labels: [
        MapLabel(x: Boards.issues.x, z: Floor.minZ, text: '📌 Issues'),
        MapLabel(x: Boards.queue.x, z: Floor.minZ, text: '📋 Task queue'),
        MapLabel(x: Boards.pulls.x, z: Floor.minZ, text: '🔀 Pull requests'),
        const MapLabel(x: Gong.x, z: Floor.minZ, text: '🎉 Gong'),
        MapLabel(x: stations.last.x, z: stations.last.z - 1.9, text: '📋 Queue agent'),
        for (var i = 0; i < 6 && i < seats.length; i++)
          MapLabel(
            x: deskSeat(seats[i]).x,
            z: deskSeat(seats[i]).z > seats[i].z ? deskSeat(seats[i]).z + 0.1 : deskSeat(seats[i]).z - 2.85,
            below: deskSeat(seats[i]).z > seats[i].z,
            text: '${workerEmoji(MapStatus.values[i])} Worker ${i + 1}',
          ),
        const MapLabel(x: Elevator.x, z: Floor.minZ, text: '🛗 Elevator'),
        const MapLabel(x: Cabinet.x, z: Cabinet.z - 0.4, text: '🕹️ Arcade'),
        const MapLabel(x: Jukebox.x, z: Jukebox.z - 0.5, text: '🎵 Jukebox'),
        const MapLabel(
          x: Whiteboard.x,
          z: Whiteboard.z - 0.4,
          text: '📝 Whiteboard',
          detail: ['📝 Whiteboard', 'Aiko is drawing'],
          action: '🖱 Draw together',
        ),
      ],
      people: [
        MapPerson(
          x: deskPoint(stations.last, 0, Kiosk.stand).$1,
          z: deskPoint(stations.last, 0, Kiosk.stand).$2,
          look: const Look(skin: 0, hair: 0, style: 0),
          shirt: const Color(0xFF2B2D42),
          status: MapStatus.working,
        ),
        const MapPerson(
          x: 0,
          z: 2,
          look: Look(skin: 1, hair: 2, style: 0),
          shirt: Color(0xFFEF476F),
          me: true,
          walking: true,
        ),
        const MapPerson(
          x: 6,
          z: 4,
          look: Look(skin: 3, hair: 0, style: 0),
          shirt: Color(0xFF118AB2),
          name: 'Aiko',
          facing: 3.1,
        ),
        for (var i = 0; i < statuses.length && i < seats.length; i++)
          MapPerson(
            x: deskSeat(seats[i]).x,
            z: deskSeat(seats[i]).z,
            look: Look(skin: i % 4, hair: i % 5, style: 0),
            shirt: [Pal.green, Pal.blue, Pal.yellow, Pal.red, Pal.couch, Pal.pot][i % 6],
            sitting: true,
            facing: 3.1,
            status: statuses[i],
          ),
      ],
    );
    const size = Size(1400, 900);
    final rec2 = ui.PictureRecorder();
    OfficeMapPainter(map: map, scene: () => scene).paint(ui.Canvas(rec2), size);
    final img = await rec2.endRecording().toImage(size.width.toInt(), size.height.toInt());
    expect(img.width, 1400);
    final dir = Platform.environment['SNAPSHOT_DIR'];
    if (dir == null) return;
    // Again with the office's fonts (tests draw text in boxes otherwise), for a look.
    for (final (family, file) in [('Nunito', 'Nunito'), ('Twemoji', 'Twemoji')]) {
      final bytes = File('assets/fonts/$file.ttf').readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    final rec3 = ui.PictureRecorder();
    OfficeMapPainter(map: map, scene: () => scene).paint(ui.Canvas(rec3), size);
    final shot = await rec3.endRecording().toImage(size.width.toInt(), size.height.toInt());
    // Zoomed in, as a pinch would: on the first desks, and on you, Aiko and the dog.
    for (final (name, x, z) in [
      ('zoom', deskSeat(seats[0]).x + 1, deskSeat(seats[0]).z + 1),
      ('people', 2.5, 3.0),
      ('kiosk', stations.last.x, stations.last.z),
    ]) {
      final at = mapPoint(x, z);
      const zoom = 7.0;
      final rec4 = ui.PictureRecorder();
      OfficeMapPainter(
        map: map,
        scene: () => scene,
        view: (s) => MapView(zoom, Offset(s.width / 2, s.height / 2) - at * zoom),
      ).paint(ui.Canvas(rec4), size);
      final close = await rec4.endRecording().toImage(size.width.toInt(), size.height.toInt());
      final zpng = await close.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/office2d-$name.png').writeAsBytesSync(zpng!.buffer.asUint8List());
    }
    final png = await shot.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/office2d.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
