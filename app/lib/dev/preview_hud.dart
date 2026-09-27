// A preview of the HUD over a plain sky, with a made-up office in the store. ?w=<window> opens one
// of the HUD's windows over it: settings, character, help, upgrade, team, accounts, elevator,
// jukebox, services, decor, picture, restart.
//
//   flutter build web --release --no-web-resources-cdn -t lib/dev/preview_hud.dart -o build/preview_hud

import 'package:flutter/material.dart';

import '../caffeine.dart';
import '../net/office_socket.dart';
import '../notify.dart';
import '../office_scope.dart';
import '../shared/avatar.dart';
import '../shared/protocol.dart';
import '../state/store.dart';
import '../ui/accounts.dart';
import '../ui/character.dart';
import '../ui/decor.dart';
import '../ui/elevator.dart';
import '../ui/help.dart';
import '../ui/hud.dart';
import '../ui/jukebox.dart';
import '../ui/modal.dart';
import '../ui/services.dart';
import '../ui/settings.dart';
import '../ui/team.dart';
import '../ui/theme.dart';
import '../ui/upgrade.dart';

void main() => runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: officeTheme(), home: const _Preview()));

final _t0 = DateTime.now().millisecondsSinceEpoch;
int _ago(int minutes) => _t0 - minutes * 60000;

Map<String, dynamic> _usage(double cost, int input, int output, {int calls = 12, bool? costKnown}) => {
  'input': input,
  'output': output,
  'cacheWrite': input ~/ 2,
  'cacheRead': input * 3,
  'cost': cost,
  'calls': calls,
  'costKnown': ?costKnown,
};

Map<String, dynamic> _peer(
  String id,
  String name,
  String color, {
  bool voice = false,
  bool muted = false,
  bool? account,
  String floor = 'f1',
  bool sharing = false,
}) => {
  'id': id,
  'name': name,
  'color': color,
  'look': lookFromSeed(name).toJson(),
  'voice': voice,
  'muted': muted,
  'sharing': sharing,
  'account': ?account,
  'floor': floor,
};

Map<String, dynamic> _worker(
  String id,
  String name,
  String color,
  String status,
  int age, {
  String? provider,
  Map<String, dynamic>? usage,
  String? activity,
  String kind = 'agent',
  Map<String, dynamic>? worktree,
  Map<String, dynamic>? pr,
}) => {
  'id': id,
  'kind': kind,
  'provider': ?provider,
  'deskId': 'desk-$id',
  'name': name,
  'color': color,
  'status': status,
  'acked': false,
  'createdBy': 'Ada',
  'createdAt': _ago(age),
  'prompt': 'Fix the login redirect loop',
  'worktree': ?worktree,
  'pr': ?pr,
  'viewers': <String>[],
  'activity': ?activity,
  'usage': ?usage,
};

final _welcome = <String, dynamic>{
  't': 'welcome',
  'you': 'p1',
  'projectsDir': '/home/office/projects',
  'invites': true,
  'version': 'abc1234',
  'me': {
    'admin': true,
    'account': {'name': 'Ada', 'role': 'admin'},
  },
  'peers': [
    _peer('p1', 'Ada', '#ff8a5b', voice: true, account: true),
    _peer('p2', 'Grace', '#4f86f7', voice: true, muted: true, sharing: true),
    _peer('p3', 'Linus', '#06d6a0', floor: 'f2'),
  ],
  'floors': [
    {
      'id': 'f1',
      'name': 'agent-office',
      'repo': 'acme/agent-office',
      'dir': '/home/office/projects/acme/agent-office',
      'palette': 0,
      'workers': 4,
      'busy': 2,
      'waiting': 1,
      'people': 2,
      'addedBy': 'Ada',
      'addedAt': _ago(9000),
    },
    {
      'id': 'f2',
      'name': 'billing-api',
      'repo': 'acme/billing-api',
      'dir': '/home/office/projects/acme/billing-api',
      'palette': 1,
      'workers': 2,
      'busy': 1,
      'waiting': 2,
      'people': 1,
      'addedBy': 'Grace',
      'addedAt': _ago(4000),
    },
    {
      'id': 'f3',
      'name': 'website',
      'repo': 'acme/website',
      'dir': '/home/office/projects/acme/website',
      'palette': 2,
      'workers': 0,
      'busy': 0,
      'waiting': 0,
      'people': 0,
      'cloning': true,
      'addedBy': 'Linus',
      'addedAt': _ago(2),
    },
  ],
  'floor': 'f1',
  'project': {
    'name': 'agent-office',
    'dir': '/home/office/projects/acme/agent-office',
    'branch': 'main',
    'agentCmd': 'claude',
    'defaultProvider': 'claude',
    'agentProviders': ['claude', 'opencode', 'codex'],
  },
  'workers': [
    _worker(
      'w1',
      'Ziggy',
      '#9d4edd',
      'working',
      40,
      usage: _usage(1.84, 52000, 9000),
      activity: 'Editing src/client/main.ts',
      worktree: {'path': 'wt/ziggy', 'branch': 'fix-login', 'base': 'main'},
    ),
    _worker(
      'w2',
      'Pepper',
      '#ef476f',
      'needs_input',
      30,
      provider: 'opencode',
      usage: _usage(0.31, 21000, 4000),
      activity: 'Allow running npm test?',
    ),
    _worker(
      'w3',
      'Maple',
      '#06d6a0',
      'done',
      20,
      provider: 'codex',
      usage: _usage(0, 88000, 12000, costKnown: false),
      pr: {'number': 42, 'url': 'https://github.com/acme/agent-office/pull/42'},
    ),
    _worker('w4', 'Shell', '#8d99ae', 'offline', 10, kind: 'shell'),
  ],
  'chat': [
    for (final (i, (who, color, text)) in const [
      ('Ada', '#ff8a5b', 'morning! coffee first ☕'),
      ('Grace', '#4f86f7', 'Ziggy is on the login loop'),
      ('Linus', '#06d6a0', "I'm upstairs on billing"),
      ('Ada', '#ff8a5b', 'Pepper wants to run the tests, can someone look?'),
      ('Grace', '#4f86f7', 'on it'),
      ('Ada', '#ff8a5b', 'PR #42 is up for review'),
      ('Linus', '#06d6a0', 'nice, the gong will tell us'),
      ('Grace', '#4f86f7', 'sharing my screen on the TV'),
      ('Ada', '#ff8a5b', 'the jukebox is too loud 🎵'),
      ('Grace', '#4f86f7', 'turn it down in settings then 😄'),
    ].indexed)
      {'from': 'p', 'name': who, 'color': color, 'text': text, 'at': _ago(30 - i), 'account': who == 'Ada'},
  ],
  'upgrade': {
    'available': true,
    'phase': 'idle',
    'current': {
      'sha': 'abc1234',
      'subject': 'Coffee gives you the jitters',
      'date': DateTime.fromMillisecondsSinceEpoch(_ago(4000)).toIso8601String(),
    },
    'latest': {
      'sha': 'def5678',
      'subject': 'A dog that barks at workers who need you',
      'date': DateTime.fromMillisecondsSinceEpoch(_ago(60)).toIso8601String(),
    },
    'changes': [
      {'sha': 'def5678', 'subject': 'A dog that barks at workers who need you'},
      {'sha': 'bcd4567', 'subject': 'Jukebox streams'},
      {'sha': 'abd3456', 'subject': 'Fix the elevator doors'},
    ],
    'behind': 3,
    'checkedAt': _ago(1),
  },
  'usage': {
    'total': _usage(42.18, 3100000, 400000, calls: 900),
    'today': _usage(12.4, 900000, 120000, calls: 210),
    'day': '2026-09-27',
    'budget': 20,
    'pauseHiring': false,
  },
  'limits': {
    'plan': 'max',
    'at': _t0,
    'windows': [
      {'label': '5h session', 'pct': 64, 'resetsAt': _t0 + 134 * 60000},
      {'label': 'Week', 'pct': 91, 'resetsAt': _t0 + 3 * 86400000},
    ],
  },
  'notify': {
    'webhook': {'kind': 'slack', 'hint': '…/T0/B1', 'by': 'Grace', 'at': _ago(600)},
    'lastSentAt': _ago(12),
  },
  'services': {
    'port': 4600,
    'ssh': 'office@203.0.113.7',
    'items': [
      {
        'port': 5173,
        'host': '127.0.0.1',
        'pid': 1,
        'command': 'npm run dev',
        'workerId': 'w1',
        'title': 'Vite dev server',
        'since': _ago(14),
      },
      {
        'port': 8000,
        'host': '127.0.0.1',
        'pid': 2,
        'command': 'python -m http.server',
        'workerId': 'w2',
        'since': _ago(3),
      },
    ],
  },
  'queue': {
    'maxWorkers': 4,
    'tasks': [
      {'id': 't1', 'title': 'Add dark mode', 'prompt': 'x', 'status': 'queued', 'addedBy': 'Ada', 'addedAt': _ago(5)},
    ],
  },
  'jukebox': {'on': true, 'track': 'coffee-break', 'by': 'Grace', 'startedAt': 0, 'elapsed': 0},
  'dog': {'name': 'Biscuit', 'coat': 0, 'path': [], 'speed': 0, 'elapsed': 0, 'act': 'sit'},
  'sky': {'lat': 52.5, 'lon': 13.4, 'utcOffset': 120, 'weather': 'clear', 'intensity': 0},
  'decor': [
    {
      'id': 'd1',
      'url': 'https://example.com/cat.png',
      'title': 'The office cat',
      'wall': 'north',
      'u': 0,
      'y': 1.5,
      'w': 1,
      'h': 1,
      'frame': 1,
      'by': 'Grace',
      'at': _ago(90),
    },
  ],
};

class _FakeActions implements OfficeActions {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    debugPrint('action: ${invocation.memberName}');
    return null;
  }
}

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final store = Store();
  late final net = OfficeSocket(
    profile: () => (name: 'Ada', color: '#ff8a5b', look: store.profile.look),
    floor: () => 'f1',
  );
  final settings = Settings();
  final voice = ValueNotifier(const VoiceState(inVoice: true));
  final connected = ValueNotifier(true);
  final hanging = ValueNotifier(false);
  final speaking = ValueNotifier<Set<String>>({'p1'});
  final crosshair = ValueNotifier(const CrosshairState(show: true, on: true, free: true));
  final hint = ValueNotifier<List<HintPart>?>(const [
    HintTitle('Ziggy · working'),
    HintAside('Editing src/client/main.ts'),
    HintCost('\$1.84 · 128k tokens'),
    HintKey('E', 'Open terminal'),
    HintKey('C', 'Changes'),
    HintKey('P', 'Prompt'),
    HintKey('O', 'Open PR'),
    HintKey('X', 'Send home'),
  ]);
  final caffeine = Caffeine();
  final clock = Stopwatch()..start();
  late final notifier = DesktopNotifier(enabled: () => settings.notify, openWorker: (_) {});
  late final HudController controller;
  late final OfficeScope scope;

  double _secs() => clock.elapsedMilliseconds / 1000;

  @override
  void initState() {
    super.initState();
    store.apply(ServerMsg.parse(_welcome));
    store.apply(
      ServerMsg.parse({
        't': 'team',
        'state': {
          'ssh': 'office@203.0.113.7',
          'port': 4600,
          'fingerprint': 'SHA256:q3Zx9k2c1vRZ7m',
          'members': [
            {'name': 'grace', 'keys': 2},
            {'name': 'linus', 'keys': 1},
          ],
        },
      }),
    );
    store.apply(
      ServerMsg.parse({
        't': 'accounts',
        'state': {
          'sharedPassword': true,
          'accounts': [
            {'id': 'a1', 'name': 'Ada', 'role': 'admin', 'createdAt': _ago(9000), 'createdBy': 'Ada', 'online': true},
            {
              'id': 'a2',
              'name': 'Grace',
              'role': 'member',
              'createdAt': _ago(5000),
              'createdBy': 'Ada',
              'lastSeenAt': _ago(90),
              'online': false,
            },
          ],
          'invites': [
            {
              'id': 'i1',
              'token': 'tok',
              'role': 'member',
              'createdBy': 'Ada',
              'createdAt': _ago(60),
              'expiresAt': _t0 + 5 * 86400000,
            },
          ],
        },
      }),
    );
    store.repos = (
      list: [
        const RepoChoice(name: 'acme/agent-office', private: true, description: 'The office itself'),
        const RepoChoice(name: 'acme/billing-api', private: true, description: 'Payments and invoices'),
        const RepoChoice(
          name: 'acme/design-system',
          private: false,
          description: 'Buttons, all the buttons',
          pushedAt: '2026-09-20T10:00:00Z',
        ),
      ],
      error: null,
      loading: false,
      at: _t0,
    );
    caffeine.drink(_secs());
    caffeine.drink(_secs());
    Toasts.instance.items.value = [ToastItem('🎉 PR #42 merged — bang the gong!', ToastKind.info)];
    controller = HudController(
      HudCallbacks(
        onElevator: () => openElevator(scope, ride: (_) {}),
        onVoice: () => voice.value = VoiceState(inVoice: !voice.value.inVoice),
        onMute: () => voice.value = VoiceState(inVoice: true, muted: !voice.value.muted),
        onShare: () => voice.value = VoiceState(inVoice: voice.value.inVoice, sharing: !voice.value.sharing),
        onIssues: () {},
        onPulls: () {},
        onServices: () => openServices(scope),
        onQueue: () {},
        onTeam: () => openTeam(scope),
        onAccounts: () => openAccounts(scope),
        onUpgrade: () => openUpgrade(scope),
        onSearch: () {},
        onWhiteboard: () {},
        onDecor: () => hanging.value = !hanging.value,
        onSettings: _settings,
        onHelp: openHelp,
        onOpenWorker: (_) {},
        onEditProfile: () => openCharacter(scope, onSave: (_) {}),
      ),
    );
    scope = OfficeScope(store: store, net: net, settings: settings, actions: _FakeActions(), child: const SizedBox());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ModalStack.instance.attach(Overlay.of(context));
      _open(Uri.base.queryParameters['w']);
    });
  }

  void _settings() => openSettings(
    scope,
    settings: settings,
    onChange: (_) {},
    onCharacter: () => openCharacter(scope, onSave: (_) {}),
    previewSound: () {},
    notifier: notifier,
    onSignOut: () {},
    outside: (now: '☀️ Clear · 2:41 PM office time · Berlin, Germany, 18 °C', live: true),
  );

  void _open(String? w) {
    final decor = store.decor.first;
    switch (w) {
      case 'settings':
        _settings();
      case 'character':
        openCharacter(scope, onSave: (_) {});
      case 'character-first':
        openCharacter(scope, first: true, onSave: (_) {});
      case 'help':
        openHelp();
      case 'upgrade':
        openUpgrade(scope);
      case 'restart':
        showRestarting(store.upgrade, scope);
      case 'team':
        openTeam(scope);
      case 'accounts':
        openAccounts(scope);
      case 'elevator':
        openElevator(scope, ride: (_) {});
      case 'jukebox':
        openJukebox(scope, openVolume: _settings);
      case 'services':
        openServices(scope);
      case 'decor':
        openHangDialog(onDone: (_) {});
      case 'decor-edit':
        openHangDialog(initial: decor, onDone: (_) {});
      case 'picture':
        openPicture(scope, decor, move: () {}, edit: () {}, remove: () {});
    }
  }

  @override
  Widget build(BuildContext context) => OfficeScope(
    store: store,
    net: net,
    settings: settings,
    actions: scope.actions,
    child: Scaffold(
      backgroundColor: Swatch.sky,
      body: Hud(
        controller: controller,
        voice: voice,
        connected: connected,
        hint: hint,
        crosshair: crosshair,
        hanging: hanging,
        caffeine: caffeine,
        clock: _secs,
        speaking: speaking,
        shares: const _FakeShare('Grace'),
      ),
    ),
  );
}

/// What a screen-share thumbnail looks like (.share-thumb), for the slot.
class _FakeShare extends StatelessWidget {
  const _FakeShare(this.who);
  final String who;

  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    height: 124 + 6,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFF111111),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Swatch.ink, width: kBorder),
      boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
    ),
    child: Stack(
      children: [
        Positioned(
          left: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Swatch.paper,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Swatch.ink, width: 2),
            ),
            child: Text('🖥️ $who', style: heavy(12)),
          ),
        ),
      ],
    ),
  );
}
