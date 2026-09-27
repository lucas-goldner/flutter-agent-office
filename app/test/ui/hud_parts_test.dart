import 'package:agent_office/caffeine.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/avatar.dart';
import 'package:agent_office/ui/chibi.dart';
import 'package:agent_office/ui/help.dart';
import 'package:agent_office/ui/hud_parts.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('css colours', () {
    expect(cssColor('#ff8a5b'), const Color(0xFFFF8A5B));
    expect(cssColor('#fff'), const Color(0xFFFFFFFF));
    expect(cssColor('nope'), const Color(0xFF888888));
    expect(statusLabel(WorkerStatus.offline), 'asleep');
    expect(statusLabel(WorkerStatus.idle), 'ready');
  });

  testWidgets('the hint bar lays out titles, keys, asides and costs', (tester) async {
    await tester.pumpWidget(
      host(
        const HintBar([
          HintTitle('Ada · working'),
          HintAside('editing main.ts'),
          HintCost('\$0.42 · 38k tokens'),
          HintKey('E', 'Open terminal'),
          HintKey('X', 'Send home'),
        ]),
      ),
    );
    expect(find.text('Ada · working'), findsOneWidget);
    expect(find.text('editing main.ts'), findsOneWidget);
    expect(find.text('\$0.42 · 38k tokens'), findsOneWidget);
    expect(find.byType(KeyCap), findsNWidgets(2));
    expect(find.text('Open terminal'), findsOneWidget);
  });

  testWidgets('the crosshair hides, and says "Click to look around" when free', (tester) async {
    await tester.pumpWidget(host(const Crosshair(CrosshairState())));
    expect(find.byType(AnimatedContainer), findsNothing);
    await tester.pumpWidget(host(const Crosshair(CrosshairState(show: true))));
    expect(find.byType(AnimatedContainer), findsOneWidget);
    expect(find.text('Click to look around'), findsNothing);
    await tester.pumpWidget(host(const Crosshair(CrosshairState(show: true, on: true, free: true))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Click to look around'), findsOneWidget);
  });

  testWidgets('the caffeine meter counts down the buzz and hides when it wears off', (tester) async {
    final c = Caffeine();
    var now = 100.0;
    await tester.pumpWidget(host(CaffeineMeter(caffeine: c, clock: () => now)));
    expect(find.textContaining('s'), findsNothing);
    c.drink(now);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('60s'), findsOneWidget);
    expect(find.text('☕'), findsOneWidget);
    c.drink(now);
    c.drink(now);
    now += 2.5;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('58s'), findsOneWidget);
    expect(find.text('☕☕☕'), findsOneWidget);
    now += 70;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('☕☕☕'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the chat log shows the last 60 lines', (tester) async {
    final lines = [
      for (var i = 0; i < 70; i++)
        ChatLine.fromJson({
          'from': 'p$i',
          'name': 'Ada',
          'color': '#ff8a5b',
          'text': 'line $i',
          'at': i,
          'account': i == 69,
        }),
    ];
    await tester.pumpWidget(host(SizedBox(width: 330, child: ChatLog(lines))));
    await tester.pumpAndSettle();
    expect(find.textContaining('line 9', findRichText: true), findsNothing);
    expect(find.textContaining('line 69', findRichText: true), findsOneWidget);
  });

  testWidgets('the help window lists the controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ModalStack.instance.attach(Overlay.of(context));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    openHelp();
    await tester.pumpAndSettle();
    expect(find.text('🎮 Controls'), findsOneWidget);
    expect(find.text('W A S D'), findsOneWidget);
    expect(find.text('Join voice / mute'), findsOneWidget);
    ModalStack.instance.closeAll();
    await tester.pumpAndSettle();
    expect(find.text('🎮 Controls'), findsNothing);
  });

  testWidgets('the stand-in avatar draws every hair style', (tester) async {
    for (var style = 0; style < hairStyles.length; style++) {
      await tester.pumpWidget(
        host(SizedBox(width: 250, height: 360, child: ChibiAvatar(look: Look(skin: 2, hair: 4, style: style), color: '#4f86f7'))),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
