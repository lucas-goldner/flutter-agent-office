import 'dart:math' as math;

import 'package:agent_office/world/costumes.dart';
import 'package:agent_office/world/holiday.dart';
import 'package:agent_office/world/office/office_colliders.dart' show roomPlants;
import 'package:agent_office/world/sky_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/theme.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  final oct = DateTime.utc(2026, 10, 15, 12).millisecondsSinceEpoch;
  final dec = DateTime.utc(2026, 12, 20, 12).millisecondsSinceEpoch;
  final jun = DateTime.utc(2026, 6, 20, 12).millisecondsSinceEpoch;

  HolidayPlan? planFor(ThemePick pick, int ms) {
    final t = activeTheme(pick, ms, 0);
    return t == null ? null : HolidayPlan(t);
  }

  test('the pick puts up the holiday: by the calendar, one of them, or none', () {
    expect(planFor(ThemePick.auto, oct)!.theme, HolidayTheme.halloween);
    expect(planFor(ThemePick.auto, dec)!.theme, HolidayTheme.christmas);
    expect(planFor(ThemePick.auto, jun), isNull);
    expect(planFor(ThemePick.christmas, jun)!.theme, HolidayTheme.christmas);
    expect(planFor(ThemePick.off, oct), isNull);
  });

  test('Halloween: a jack-o-lantern on every desk and all down the street, gravestones in the way', () {
    final p = HolidayPlan(HolidayTheme.halloween);
    expect(p.gifts, isEmpty);
    expect(p.plantTrees, isEmpty);
    expect(p.pumpkins.where((s) => s.y == DeskSize.height), hasLength(desks.length));
    for (final d in desks) {
      expect(
        p.pumpkins.where((s) => (s.x - d.x).abs() < 1 && (s.z - d.z).abs() < 1 && s.y == DeskSize.height),
        isNotEmpty,
      );
    }
    final down = p.pumpkins.where(isDown).toList();
    expect(down, isNotEmpty);
    expect(down.every((s) => s.y < 0 || s.x < Floor.minX), isTrue);
    // A pumpkin beside every plant.
    expect(p.pumpkins.where((s) => s.y == 0).length, greaterThanOrEqualTo(roomPlants.length));
    expect(p.colliders, hasLength(graves.length));
    expect(p.colliders.every((c) => c.bottom == streetY && c.top > streetY), isTrue);
  });

  test('Christmas: a present on every desk, the plants turn into trees, a big tree and snowmen out front', () {
    final p = HolidayPlan(HolidayTheme.christmas);
    expect(p.pumpkins, isEmpty);
    expect(p.gifts, hasLength(desks.length));
    expect(p.plantTrees, roomPlants);
    expect(p.colliders, hasLength(1 + snowmen.length));
    expect(p.colliders.first.top, streetY + BigTree.height);
  });

  test('onDesk turns with the desk', () {
    final d = desks.first;
    final (x, z) = onDesk(d, 0, 0);
    expect(x, d.x);
    expect(z, d.z);
    final (x1, z1) = onDesk(d, 1, 0);
    expect(math.sqrt(math.pow(x1 - d.x, 2) + math.pow(z1 - d.z, 2)), closeTo(1, 1e-9));
  });

  group('triangulate', () {
    double area(List<vm.Vector2> p, List<(int, int, int)> tris) => tris.fold(0.0, (s, t) {
      final a = p[t.$1], b = p[t.$2], c = p[t.$3];
      return s + ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;
    });
    double polyArea(List<vm.Vector2> p) {
      var s = 0.0;
      for (var i = 0; i < p.length; i++) {
        s += p[i].x * p[(i + 1) % p.length].y - p[(i + 1) % p.length].x * p[i].y;
      }
      return s.abs() / 2;
    }

    test('fills a concave outline exactly, either winding', () {
      final l = [
        vm.Vector2(0, 0),
        vm.Vector2(2, 0),
        vm.Vector2(2, 1),
        vm.Vector2(1, 1),
        vm.Vector2(1, 2),
        vm.Vector2(0, 2),
      ];
      expect(triangulate(l), hasLength(4));
      expect(area(l, triangulate(l)), closeTo(3, 1e-9));
      final r = l.reversed.toList();
      expect(area(r, triangulate(r)), closeTo(3, 1e-9));
    });

    test("the bat wing's scalloped outline", () {
      final wing = batWingOutline();
      final tris = triangulate(wing);
      expect(tris, hasLength(wing.length - 2));
      expect(area(wing, tris), closeTo(polyArea(wing), 1e-9));
    });
  });

  group('the holiday sky', () {
    SkyState sky(Weather w) => SkyState(lat: 52.52, lon: 13.4, utcOffset: 0, weather: w, intensity: 0);

    test('it snows all Christmas, whatever the forecast', () {
      final m = SkyModel(random: math.Random(1))..set(sky(Weather.clear));
      m.update(0.016, 0, dec);
      expect(m.snow, 0);
      m.setTheme(HolidayTheme.christmas);
      for (var i = 0; i < 200; i++) {
        m.update(0.1, i * 0.1, dec);
      }
      expect(m.snow, greaterThan(0.5));
      expect(m.festive, greaterThan(0.9));
    });

    test('Halloween: a gloomy day, mist, and a big harvest moon low in the south', () {
      final m = SkyModel(random: math.Random(1))..set(sky(Weather.clear));
      m.update(0.016, 0, oct);
      final day = m.daylight;
      m.setTheme(HolidayTheme.halloween);
      for (var i = 0; i < 300; i++) {
        m.update(0.1, i * 0.1, oct);
      }
      expect(m.spooky, greaterThan(0.99));
      expect(m.daylight, lessThan(day * 0.5));
      expect(m.fog, greaterThan(0.25));
      expect(m.moonScale, greaterThan(3));
      expect(m.moonDiscOpacity, greaterThan(0.4));
      expect(m.sunDiscOpacity, lessThan(0.01));
      final toward = skyward(kSpookyMoonEl, kSpookyMoonAz);
      expect(m.moonDir.dot(toward), greaterThan(0.99));
    });
  });
}
