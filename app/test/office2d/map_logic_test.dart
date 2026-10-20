// The 2D map's arithmetic: floor ↔ map points, fitting it on the page, and worker bubbles.
import 'dart:ui';

import 'package:agent_office/office2d/map_painter.dart';
import 'package:agent_office/office2d/office2d_view.dart';
import 'package:agent_office/office2d/pixel_map.dart';
import 'package:agent_office/office2d/retro.dart';
import 'package:agent_office/office/controller.dart';
import 'package:agent_office/office/interaction.dart' show DeskKey;
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/office2d/sprites.dart';
import 'package:agent_office/ui/hud_parts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';

void main() {
  test('a floor point goes onto the map and back', () {
    final p = mapPoint(Gong.x, Gong.z);
    final back = floorPoint(p);
    expect(back.x, closeTo(Gong.x, 1e-9));
    expect(back.z, closeTo(Gong.z, 1e-9));
    expect(mapPoint(MapBounds.minX, MapBounds.minZ), Offset.zero);
  });

  test('the map fits under the bar, in whole pixels once it is twice its size or more', () {
    final w = MapBounds.width.toDouble(), h = MapBounds.height.toDouble();
    final big = mapFit(Size(w * 2.6, h * 2.6 + 64), top: 64);
    expect(big.scale, 2, reason: 'floored to whole pixels');
    expect(big.origin.dy, greaterThanOrEqualTo(64));
    final small = mapFit(Size(w * 0.8, h), top: 0);
    expect(small.scale, closeTo(0.8, 1e-9), reason: 'small pages take whatever fits');
    expect(small.origin.dx, 0);
  });

  test("a worker's bubble says how it's doing", () {
    expect(mapStatus(WorkerStatus.needsInput), MapStatus.needsInput);
    expect(mapStatus(WorkerStatus.working), MapStatus.working);
    expect(mapStatus(WorkerStatus.exited), MapStatus.off);
    expect(mapStatus(WorkerStatus.offline), MapStatus.off);
    expect(mapColor('#ff8a5b'), const Color(0xFFFF8A5B));
    expect(mapColor('nope'), const Color(0xFF888888));
  });

  test('a zoomed view puts floor points on the page and back', () {
    final v = MapView(6, const Offset(-900, -400));
    expect(v.perMeter, 6 * kPx);
    final page = v.toPage(Cabinet.x, Cabinet.z);
    final back = v.toFloor(page);
    expect(back.x, closeTo(Cabinet.x, 1e-9));
    expect(back.z, closeTo(Cabinet.z, 1e-9));
  });

  test("16-bit sprites: every look, pose and status makes a pixel image with its feet on it", () {
    final book = SpriteBook();
    for (final style in [0, 1, 2, 3, 4, 5, 6]) {
      for (final back in [false, true]) {
        final p = book.person(Look(skin: 1, hair: 2, style: style), const Color(0xFF4F86F7), back: back, step: 1);
        expect((p.image.width, p.image.height), (16, 23));
        expect(p.footY, lessThan(p.image.height));
      }
    }
    for (final s in MapStatus.values) {
      final w = book.worker(const Color(0xFF06D6A0), s, blink: true);
      expect(w.image.height, 23);
      expect(identical(book.worker(const Color(0xFF06D6A0), s, blink: true), w), isTrue, reason: 'kept, not redrawn');
    }
    expect(book.dog(step: 1, left: true).image.width, 16);
    expect(kBulb.keys, containsAll(MapStatus.values), reason: 'every status has its bulb');
  });

  test('the Mega Drive palette: 3 bits a channel, and ramps from dark to light', () {
    final c = md(const Color(0xFFCEAC74));
    for (final ch in [(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round()]) {
      expect([0, 52, 87, 116, 144, 172, 206, 255], contains(ch));
    }
    final r = ramp(const Color(0xFF06D6A0));
    double luma(Color c) => c.r * 0.3 + c.g * 0.59 + c.b * 0.11;
    expect(luma(r[0]), lessThan(luma(r[2])));
    expect(luma(r[4]), greaterThan(luma(r[2])));
  });

  test('every activity has a name tag on the map, but not the desks, seats and pictures', () {
    for (final k in [
      InteractKind.whiteboard,
      InteractKind.queue,
      InteractKind.issues,
      InteractKind.cabinet,
      InteractKind.jukebox,
      InteractKind.expand,
      InteractKind.build,
    ]) {
      expect(labelOf(k), isNotNull, reason: '$k');
    }
    for (final k in [InteractKind.desk, InteractKind.seat, InteractKind.decor]) {
      expect(labelOf(k), isNull, reason: '$k');
    }
    expect(OfficeController.kWalkToUse, contains(InteractKind.coffee), reason: 'a cup is had at the machine');
    expect(OfficeController.kWalkToUse, isNot(contains(InteractKind.whiteboard)), reason: 'windows open from anywhere');
  });

  test("right-clicking a worker on the map offers what aiming at it in 3D does", () {
    final keys = hintKeys(const [
      HintTitle('Bolt · working'),
      HintAside('Fixing the QR screen'),
      HintKey('E', 'Open terminal'),
      HintKey('C', 'Changes'),
      HintKey('P', 'Prompt'),
      HintKey('O', 'PR #12'),
      HintKey('X', 'Send home'),
      HintKey('Space', 'Jump'),
    ]);
    expect(
      [for (final k in keys) (k.label, k.desk)],
      [
        ('Open terminal', DeskKey.e),
        ('Changes', DeskKey.c),
        ('Prompt', DeskKey.p),
        ('PR #12', DeskKey.o),
        ('Send home', DeskKey.x),
      ],
    );
  });
}
