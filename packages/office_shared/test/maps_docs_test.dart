// The docs part of tests/maps.test.ts: docs/maps/castle.json and station.json are copies of the
// built-in maps to start your own from, and every map docs/maps.md shows loads.
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

/// The repository's docs folder (the tests run from packages/office_shared).
final String docs = '${Directory.current.path}/../../docs';

void main() {
  for (final (id, mine) in const [('castle', 'my-castle'), ('station', 'my-station')]) {
    test('docs/maps/$id.json is the $id, ready to copy into .agent-office/maps/ and change', () {
      final json = jsonDecode(File('$docs/maps/$id.json').readAsStringSync());
      final checked = checkCustomMaps([(file: '$id.json', json: json)]);
      expect(checked.single.error, isNull);
      expect(checked.single.config?['id'], mine);
      final plan = planOf(mine, checked);
      final builtin = planOf(id);
      expect(plan.id, mine);
      expect(plan.desks.length, builtin.desks.length);
      for (final d in plan.desks) {
        final b = builtin.byId[d.id]!;
        expect((d.x - b.x).abs() < 1e-3 && (d.z - b.z).abs() < 1e-3, isTrue, reason: '${d.id} is where the $id has it');
      }
      expect(plan.style, builtin.style);
      expect(plan.sendHome?.keeps, builtin.sendHome?.keeps);
    });
  }

  test('every map in docs/maps.md loads', () {
    final doc = File('$docs/maps.md').readAsStringSync();
    final maps = [
      for (final m in RegExp(r'```json\n([\s\S]*?)\n```').allMatches(doc)) jsonDecode(m[1]!) as Map<String, dynamic>,
    ];
    expect(maps.length, greaterThanOrEqualTo(2));
    final checked = checkCustomMaps([for (final json in maps) (file: '${json['id']}.json', json: json)]);
    for (final m in checked) {
      expect(m.error, isNull, reason: '${m.file}: ${m.error}');
    }
  });
}
