// The building-wide settings the store keeps (workspace folder, theme, prompts, leave-on-merge, the
// machine) and your own saved settings (push to talk, the HUD's panels and pins).

import 'package:agent_office/state/store.dart';
import 'package:agent_office/world/player.dart' show ViewMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

void main() {
  test('your settings: defaults, and what a saved copy brings back', () {
    final d = Settings.fromJson(null);
    expect(d.pushToTalk, isFalse);
    expect(d.hud, kHudDefaults);
    expect(d.hud[HudPanel.chat], isTrue);
    expect(d.pins, isEmpty);

    final s = Settings.fromJson({
      'view': 'third',
      'pushToTalk': true,
      'hud': {'workers': true, 'chat': false, 'bogus': true, 'people': 'yes'},
      'pins': ['issues', 3, 'queue'],
    });
    expect(s.view, ViewMode.third);
    expect(s.pushToTalk, isTrue);
    expect(s.hud[HudPanel.workers], isTrue);
    expect(s.hud[HudPanel.chat], isFalse);
    expect(s.hud[HudPanel.people], isFalse);
    expect(s.pins, ['issues', 'queue']);

    final again = Settings.fromJson(s.toJson());
    expect(again.toJson(), s.toJson());
    final copy = s.copy()..pins.add('help');
    expect(s.pins, ['issues', 'queue'], reason: 'a copy is its own');
    expect(copy.hud, s.hud);
  });

  test('the building settings arrive with welcome and on their own messages', () {
    final store = Store();
    final seen = <Topic>[];
    for (final t in [Topic.projectsDir, Topic.theme, Topic.prompts, Topic.leaveOnMerge, Topic.machine]) {
      store.topic(t).addListener(() => seen.add(t));
    }
    store.apply(
      ServerMsg.parse({
        't': 'projectsDir',
        'state': {'dir': '~/code', 'custom': true, 'by': 'Ada', 'at': 1},
      }),
    );
    expect(store.projectsDir.dir, '~/code');
    expect(store.projectsDir.by, 'Ada');
    store.apply(
      ServerMsg.parse({
        't': 'theme',
        'state': {'pick': 'christmas', 'active': 'christmas'},
      }),
    );
    expect(store.theme.pick, ThemePick.christmas);
    store.apply(
      ServerMsg.parse({
        't': 'leaveOnMerge',
        'state': {'on': true, 'by': 'Bo'},
      }),
    );
    expect(store.leaveOnMerge.on, isTrue);
    store.apply(
      ServerMsg.parse({
        't': 'prompts',
        'state': {
          'custom': {
            'issue.work': {'text': 'Do it', 'by': 'Ada', 'at': 2},
          },
          'agent': {'provider': 'claude', 'model': 'opus', 'effort': 'high', 'by': 'Ada', 'at': 2},
        },
      }),
    );
    expect(store.prompts.custom.keys, ['issue.work']);
    expect(store.prompts.agent?.model, 'opus');
    store.apply(
      ServerMsg.parse({
        't': 'machine',
        'state': {'cpu': 10, 'cores': 8, 'memUsed': 1, 'memTotal': 2, 'workers': 3, 'limit': 4},
      }),
    );
    expect(store.machine.limit, 4);
    expect(seen, [Topic.projectsDir, Topic.theme, Topic.leaveOnMerge, Topic.prompts, Topic.machine]);
  });
}
