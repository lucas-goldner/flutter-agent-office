// A small office for widget tests: a store, a socket that keeps what it's sent, settings, and an
// overlay for ModalStack's windows.

import 'package:agent_office/net/office_socket.dart';
import 'package:agent_office/office_scope.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:agent_office/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';

class FakeNet extends OfficeSocket {
  FakeNet() : super(profile: () => (name: 'Ada', color: '#ff8a5b', look: randomLook()), floor: () => 'f1');

  final List<ClientMsg> sent = [];

  @override
  void send(ClientMsg msg) => sent.add(msg);
}

class FakeActions implements OfficeActions {
  final List<String> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString().replaceAll('Symbol("', '').replaceAll('")', ''));
    return null;
  }
}

class Office {
  final Store store = Store();
  final FakeNet net = FakeNet();
  final Settings settings = Settings();
  final FakeActions actions = FakeActions();

  OfficeScope scope([Widget child = const SizedBox()]) =>
      OfficeScope(store: store, net: net, settings: settings, actions: actions, child: child);

  /// Pumps [child] in the office, with ModalStack attached to the app's overlay.
  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(ModalStack.instance.closeAll);
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: scope(
            Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) => ModalStack.instance.attach(Overlay.of(context)));
                return child;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void welcome({List<Map<String, dynamic>> floors = const [], String? floor = 'f1', bool admin = true}) {
    store.apply(
      ServerMsg.parse({
        't': 'welcome',
        'you': 'me',
        'peers': [],
        'floors': floors,
        'projectsDir': {'dir': '~/Workspace'},
        'ice': [],
        'chat': [],
        'invites': false,
        'version': '1',
        'upgrade': {'available': false, 'phase': 'idle'},
        'usage': {},
        'limits': {'windows': [], 'at': 0},
        'me': {'admin': admin},
        'notify': {},
        ...{
          'floor': floor,
          'project': floor == null
              ? null
              : {
                  'name': 'office',
                  'dir': '/p',
                  'agentCmd': 'claude',
                  'defaultProvider': 'claude',
                  'agentProviders': ['claude', 'opencode'],
                },
          'workers': [],
          'issues': {'items': [], 'fetchedAt': 0},
          'pulls': {'items': [], 'fetchedAt': 0},
          'queue': {'tasks': [], 'maxWorkers': 2},
          'decor': [],
          'services': {'items': [], 'port': 4600},
          'whiteboard': {'elements': [], 'people': []},
          'jukebox': {},
        },
      }),
    );
  }
}

Map<String, dynamic> floorJson(
  String id,
  String name, {
  int workers = 0,
  int waiting = 0,
  int people = 0,
  bool? local,
}) => {
  'id': id,
  'name': name,
  'repo': 'acme/$name',
  'dir': '/w/$name',
  'palette': 0,
  'addedBy': 'Ada',
  'addedAt': 0,
  'workers': workers,
  'busy': 0,
  'waiting': waiting,
  'people': people,
  'local': ?local,
};

Map<String, dynamic> workerJson(
  String id, {
  String desk = 'desk-1',
  String status = 'working',
  bool acked = true,
  int at = 0,
}) => {
  'id': id,
  'kind': 'agent',
  'deskId': desk,
  'name': 'W$id',
  'color': '#ff8a5b',
  'status': status,
  'acked': acked,
  'createdBy': 'Ada',
  'createdAt': at,
  'cols': 80,
  'rows': 24,
  'viewers': [],
};
