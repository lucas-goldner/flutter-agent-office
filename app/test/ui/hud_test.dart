// The HUD as a whole (#100): only the chat shows at first; the ☰ menu's switches (and each panel's
// ✕) bring the panels and the floor details in and out; chat lines fade after a while; Tab is the menu.

import 'package:agent_office/caffeine.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/hud.dart';
import 'package:agent_office/ui/hud_parts.dart' show kChatLinger, lingering;
import 'package:agent_office/ui/menu.dart' show hudMenuOpen;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

HudController hudController(Settings settings, {List<Rect?>? floors, List<bool>? talk}) {
  void no() {}
  return HudController(
    HudCallbacks(
      onElevator: no,
      onVoice: no,
      onMute: no,
      onShare: no,
      onIssues: no,
      onPulls: no,
      onServices: no,
      onQueue: no,
      onTeam: no,
      onAccounts: no,
      onUpgrade: no,
      onSearch: no,
      onWhiteboard: no,
      onDecor: no,
      onSettings: no,
      onHelp: no,
      onOpenWorker: (_) {},
      onEditProfile: no,
      onFloors: floors?.add,
      onTalk: talk == null ? null : (down) => (talk..add(down)).isNotEmpty,
    ),
    prefs: HudPrefs(settings: settings),
  );
}

Widget hud(HudController c) => Hud(
  controller: c,
  voice: ValueNotifier(const VoiceState()),
  connected: ValueNotifier(true),
  hint: ValueNotifier(null),
  crosshair: ValueNotifier(const CrosshairState()),
  hanging: ValueNotifier(false),
  caffeine: Caffeine(),
  clock: () => 0,
);

void main() {
  testWidgets('quiet by default; panels come and go', (tester) async {
    final office = Office()..welcome(floors: [floorJson('f1', 'one')]);
    office.store.apply(WorkerUpdateMsg(WorkerInfo.fromJson(workerJson('1'))));
    final floors = <Rect?>[];
    final c = hudController(office.settings, floors: floors);
    await office.pump(tester, hud(c));
    expect(find.text('Press T to chat'), findsOneWidget);
    expect(find.text('WORKERS'), findsNothing);
    expect(find.text('IN THE OFFICE'), findsNothing);

    c.prefs.setPanel(HudPanel.workers, true);
    c.prefs.setPanel(HudPanel.spend, true);
    await tester.pump();
    expect(find.text('WORKERS'), findsOneWidget);
    expect(find.text('SPEND'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hide-workers')));
    await tester.pump();
    expect(find.text('WORKERS'), findsNothing);
    expect(office.settings.hud[HudPanel.workers], isFalse);

    // The floor you're on is a button for the floor list.
    await tester.tap(find.text('🏢 office'));
    expect(floors, hasLength(1));
    expect(floors.single, isNotNull);

    // Tab opens the ☰ menu (the office page hands the HUD its keys).
    expect(
      c.handleKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.tab,
          logicalKey: LogicalKeyboardKey.tab,
          timeStamp: Duration.zero,
        ),
      ),
      isTrue,
    );
    await tester.pump();
    await tester.pump();
    expect(hudMenuOpen(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(hudMenuOpen(), isFalse);
  });

  testWidgets('with the chat off, it hides until T', (tester) async {
    final office = Office()..welcome();
    office.settings.hud[HudPanel.chat] = false;
    final c = hudController(office.settings);
    await office.pump(tester, hud(c));
    Opacity chatOpacity() =>
        tester.widget<Opacity>(find.ancestor(of: find.text('Press T to chat'), matching: find.byType(Opacity)).first);
    expect(chatOpacity().opacity, 0);
    c.focusChat();
    await tester.pump();
    await tester.pump();
    expect(chatOpacity().opacity, 1);
  });

  test('V is push to talk when the office says so', () {
    final talk = <bool>[];
    final c = hudController(Settings(), talk: talk);
    expect(
      c.handleKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyV,
          logicalKey: LogicalKeyboardKey.keyV,
          timeStamp: Duration.zero,
        ),
      ),
      isTrue,
    );
    expect(talk, [true]);
  });

  test('chat lines linger for a while, then fade', () {
    final lines = [
      for (final t in ['hi', 'there'])
        ChatLine.fromJson({'from': 'a', 'name': 'Ada', 'color': '#fff', 'text': t, 'at': 0}),
    ];
    expect(lingering(lines, 1000), lines);
    final later = ChatLine.fromJson({'from': 'a', 'name': 'Ada', 'color': '#fff', 'text': 'again', 'at': 0});
    expect(lingering([...lines, later], 1000 + kChatLinger.inMilliseconds), [later]);
  });
}
