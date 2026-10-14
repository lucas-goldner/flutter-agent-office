// ⚙️ Settings → Building → Map (ui/settings_map.dart): what the note says, and the maps that won't load.
import 'package:agent_office/ui/settings_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart' show MapState;

void main() {
  test('the note says what the map is, who picked it and when, and where your own go', () {
    final choices = mapChoices();
    expect(choices.map((c) => c.id), containsAll(['office', 'castle', 'station']));
    final office = mapNote(const MapState(), choices);
    expect(office, startsWith(choices.first.description));
    expect(office, contains('same on every floor'));
    expect(office, isNot(contains('picked by')));
    expect(office, contains('.agent-office/maps/'));
    final castle = mapNote(
      const MapState(pick: 'castle', by: 'Ada', at: 5),
      choices,
      ago: (_) => '2m ago',
    );
    expect(castle, startsWith(choices.firstWhere((c) => c.id == 'castle').description));
    expect(castle, contains('picked by Ada 2m ago'));
  });

  test("a map of your own that won't load says why, and isn't one to pick", () {
    final custom = checkCustomMaps([
      (file: 'broken.json', json: {'id': 'broken', 'name': 'Broken', 'style': 'castle'}),
    ]);
    final choices = mapChoices(custom);
    final broken = choices.firstWhere((c) => c.id == 'broken.json');
    expect(broken.error, isNotNull);
    expect(broken.custom, isTrue);
    expect(brokenMaps(choices), "⚠️ broken.json won't load: ${broken.error}");
    expect(brokenMaps(mapChoices()), isEmpty);
  });
}
