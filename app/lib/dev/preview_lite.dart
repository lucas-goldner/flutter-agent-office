// Preview of the 2D view (/lite) with a fake office: a few workers on a floor, one asking something.
//   ?term=1   opens the asking worker's terminal, with the keypad
// Build: flutter build web --release --no-web-resources-cdn -t lib/dev/preview_lite.dart -o build/preview_lite

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';

import '../lite/lite_controller.dart';
import '../net/office_socket.dart';
import '../pages/lite_page.dart';
import '../state/store.dart';
import '../ui/theme.dart';

class _FakeNet extends OfficeSocket {
  _FakeNet() : super(profile: () => (name: 'Ada', color: '#ff8a5b', look: randomLook()), floor: () => 'f1');

  final incoming = StreamController<ServerMsg>.broadcast(sync: true);

  @override
  Stream<ServerMsg> get messages => incoming.stream;

  @override
  void send(ClientMsg msg) {
    if (msg is WorkerAttachCmd) {
      Timer(const Duration(milliseconds: 50), () {
        incoming.add(
          ServerMsg.parse({
            't': 'term.snapshot',
            'workerId': msg.workerId,
            'cols': 44,
            'rows': 20,
            'data':
                '\x1b[1mBash command\x1b[0m\r\n\r\n  npm test\r\n\r\nDo you want to proceed?\r\n\x1b[33m❯ 1. Yes\x1b[0m\r\n  2. Yes, and don\'t ask again\r\n  3. No, and tell Claude what to do differently\r\n',
          }),
        );
      });
    }
  }
}

Map<String, dynamic> _worker(
  String id,
  String name,
  String desk,
  String status, {
  String color = '#4f86f7',
  Map<String, dynamic> extra = const {},
  int at = 0,
}) => {
  'id': id,
  'kind': 'agent',
  'provider': 'claude',
  'deskId': desk,
  'name': name,
  'color': color,
  'status': status,
  'acked': status != 'done',
  'createdBy': 'Ada',
  'createdAt': at,
  'cols': 80,
  'rows': 24,
  'viewers': [],
  ...extra,
};

void main() {
  final net = _FakeNet();
  final c = LiteController(net: net, settings: Settings())..listen();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: officeTheme(),
      home: LitePage(controller: c),
    ),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  Timer(const Duration(milliseconds: 300), () {
    net.incoming.add(
      ServerMsg.parse({
        't': 'welcome',
        'you': 'me',
        'peers': [],
        'floors': [
          {
            'id': 'f1',
            'name': 'agent-office',
            'repo': 'acme/agent-office',
            'dir': '/w/agent-office',
            'palette': 0,
            'addedBy': 'Ada',
            'addedAt': 0,
            'workers': 3,
            'busy': 1,
            'waiting': 1,
            'people': 2,
          },
          {
            'id': 'f2',
            'name': 'website',
            'repo': 'acme/website',
            'dir': '/w/website',
            'palette': 1,
            'addedBy': 'Ada',
            'addedAt': 0,
            'workers': 2,
            'busy': 0,
            'waiting': 2,
            'people': 0,
          },
        ],
        'projectsDir': {'dir': '~/agent-office'},
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
          'name': 'agent-office',
          'dir': '/w/agent-office',
          'branch': 'main',
          'agentCmd': 'claude',
          'defaultProvider': 'claude',
          'agentProviders': ['claude', 'codex'],
        },
        'workers': [
          _worker(
            'a',
            'Pixel',
            'desk-1',
            'working',
            extra: {
              'model': 'opus',
              'task': {'name': 'Fix the login redirect', 'summary': 'Running the auth tests'},
              'worktree': {'path': '/w/.wt/pixel', 'branch': 'office/pixel'},
            },
            at: 1,
          ),
          _worker(
            'b',
            'Biscuit',
            'desk-4',
            'needs_input',
            color: '#ef476f',
            extra: {
              'activity': 'Wants permission: Bash: npm test',
              'waitingSince': now - 4 * 60000,
              'task': {'name': 'Dark mode for the settings page', 'summary': ''},
              'lastInput': {'by': 'Ada', 'at': now - 20 * 60000},
            },
            at: 2,
          ),
          _worker(
            'c',
            'Noodle',
            'desk-7',
            'done',
            color: '#06d6a0',
            extra: {
              'waitingSince': now - 60000,
              'task': {'name': 'Bump the dependencies', 'summary': 'Opened PR #41 with the bumps'},
              'pr': {'number': 41, 'url': 'https://github.com/acme/agent-office/pull/41', 'state': 'OPEN'},
            },
            at: 3,
          ),
          _worker('d', 'Mochi', 'desk-9', 'exited', color: '#9d4edd', extra: {'title': 'Old refactor'}),
        ],
        'issues': {
          'items': [
            for (var i = 1; i <= 5; i++)
              {
                'number': i,
                'title': 'Issue $i',
                'state': 'OPEN',
                'author': 'ada',
                'labels': [],
                'assignees': [],
                'url': 'https://x/$i',
                'createdAt': '2026-10-01T00:00:00Z',
                'updatedAt': '2026-10-01T00:00:00Z',
                'comments': 0,
              },
          ],
          'fetchedAt': now,
        },
        'pulls': {'items': [], 'fetchedAt': now},
        'queue': {'tasks': [], 'maxWorkers': 3},
        'decor': [],
        'services': {'items': [], 'port': 4600},
        'whiteboard': {'elements': [], 'people': []},
        'jukebox': {},
      }),
    );
    if (Uri.base.queryParameters['term'] == '1') {
      Timer(const Duration(milliseconds: 300), () => c.openWorker('b'));
    }
  });
}
