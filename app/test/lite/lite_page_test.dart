// The 2D view (/lite, pages/lite_page.dart): every worker as a card, the ones waiting on someone first;
// tapping one opens its terminal with the keypad and the prompt box, whose keys and box reach the
// program; the floor switcher; the boards along the bottom; and no ✋ Pick it up, with nobody to carry a card.

import 'package:agent_office/lite/lite_controller.dart';
import 'package:agent_office/office_scope.dart';
import 'package:agent_office/pages/lite_page.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:agent_office/ui/pull.dart' show BoardActions;
import 'package:agent_office/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import '../ui/harness.dart';

void main() {
  late FakeNet net;
  late LiteController c;

  /// The page on a phone's screen, with [workers] on the floor.
  Future<void> open(WidgetTester tester, List<Map<String, dynamic>> workers, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    net = FakeNet();
    c = LiteController(net: net, settings: Settings())..listen();
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: LitePage(controller: c),
      ),
    );
    // A welcome, through the page's own socket.
    final welcome = ServerMsg.parse({
      't': 'welcome',
      'you': 'me',
      'peers': [],
      'floors': [floorJson('f1', 'office', people: 1), floorJson('f2', 'web', waiting: 2)],
      'projectsDir': {'dir': '~/Workspace'},
      'ice': [],
      'chat': [],
      'invites': false,
      'version': '1',
      'upgrade': {'available': false, 'phase': 'idle'},
      'usage': {},
      'limits': {'windows': [], 'at': 0},
      'me': {'admin': true},
      'notify': {},
      'floor': 'f1',
      'project': {
        'name': 'office',
        'dir': '/p',
        'branch': 'main',
        'agentCmd': 'claude',
        'defaultProvider': 'claude',
        'agentProviders': ['claude'],
      },
      'workers': workers,
      'issues': {'items': [], 'fetchedAt': 0},
      'pulls': {'items': [], 'fetchedAt': 0},
      'queue': {'tasks': [], 'maxWorkers': 2},
      'decor': [],
      'services': {'items': [], 'port': 4600},
      'whiteboard': {'elements': [], 'people': []},
      'jukebox': {},
    });
    net.incoming.add(welcome);
    await tester.pump();
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    ModalStack.instance.closeAll();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('the workers waiting on someone come first, and the floor says who is waiting elsewhere', (tester) async {
    await open(tester, [
      workerJson('a', desk: 'desk-1', at: 1),
      workerJson('b', desk: 'desk-2', status: 'needs_input', at: 2),
      workerJson('c', desk: 'desk-3', status: 'exited', at: 0),
    ]);
    final cards = find.byWidgetPredicate(
      (w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('lite-worker-'),
    );
    expect(cards, findsNWidgets(3));
    final order = [for (final e in cards.evaluate()) '${(e.widget.key as ValueKey).value}'];
    expect(order, ['lite-worker-b', 'lite-worker-a', 'lite-worker-c']);
    expect(find.text('🙋 1 needs you'), findsOneWidget);
    expect(find.text('🙋 2 waiting on web'), findsOneWidget);
    // ✍️ for the one at work only: the asking one is answered in its terminal, the asleep one woken first.
    expect(find.byKey(const ValueKey('lite-say-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('lite-say-b')), findsNothing);
    expect(find.byKey(const ValueKey('lite-say-c')), findsNothing);
    // A way straight to the other floor.
    await tester.tap(find.text('🙋 2 waiting on web'));
    expect(net.sent.whereType<FloorGoCmd>().single.floor, 'f2');
    await done(tester);
  });

  testWidgets('a tap on a card opens its terminal, full screen, with the keypad and the prompt box', (tester) async {
    await open(tester, [workerJson('a', status: 'needs_input')]);
    await tester.tap(find.byKey(const ValueKey('lite-worker-a')));
    await tester.pump();
    expect(net.sent.whereType<WorkerAttachCmd>().single.workerId, 'a');
    net.incoming.add(ServerMsg.parse({'t': 'term.snapshot', 'workerId': 'a', 'cols': 40, 'rows': 20, 'data': 'hi'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('term-keypad')), findsOneWidget);
    // The keypad's own Esc stands in for the header's.
    expect(find.byKey(const ValueKey('term-esc')), findsNothing);
    // The window is the whole phone screen.
    final window = tester.getSize(find.byType(ModalWindow));
    expect(window.width, 390);
    await tester.tap(find.byKey(const ValueKey('key-1')));
    await tester.tap(find.byKey(const ValueKey('key-⏎')));
    await tester.tap(find.byKey(const ValueKey('key-↑')));
    await tester.pump();
    expect(net.sent.whereType<TermInputCmd>().map((m) => m.data).join(), '1\r\x1b[A');
    await tester.enterText(find.byKey(const ValueKey('term-say')), '  Yes, go on ');
    await tester.tap(find.byKey(const ValueKey('term-send')));
    await tester.pump();
    final p = net.sent.whereType<WorkerPromptCmd>().single;
    expect((p.workerId, p.prompt), ('a', 'Yes, go on'));
    await done(tester);
  });

  testWidgets('an asleep worker is woken as its terminal opens', (tester) async {
    await open(tester, [workerJson('a', status: 'exited')]);
    await tester.tap(find.byKey(const ValueKey('lite-worker-a')));
    await tester.pump();
    expect(net.sent.whereType<WorkerResumeCmd>().single.workerId, 'a');
    await done(tester);
  });

  testWidgets('the floor switcher goes to another floor', (tester) async {
    await open(tester, []);
    expect(find.text('Nobody is working on this floor. ✨ New task hires someone.'), findsOneWidget);
    expect(find.text('⎇ main · acme/office · 👥 1 here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lite-floor')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web · 🙋 2').last);
    await tester.pumpAndSettle();
    expect(net.sent.whereType<FloorGoCmd>().single.floor, 'f2');
    await done(tester);
  });

  testWidgets('✨ New task asks what to do, for a new worker at a free desk', (tester) async {
    await open(tester, []);
    await tester.tap(find.byKey(const ValueKey('lite-nav-new')));
    await tester.pump();
    expect(find.text('✨ New task'), findsWidgets);
    expect(ModalStack.instance.open, isTrue);
    await done(tester);
  });

  test('the 2D view has no hands to carry a card with', () {
    final c = LiteController(net: FakeNet(), settings: Settings());
    expect(c, isA<NotInTheOffice>());
    expect(BoardActions(c.scope).canPickUp, isFalse);
    expect(BoardActions(Office().scope()).canPickUp, isTrue);
  });
}
