// A preview of the GitHub windows and wall boards with a fake office: a store full of issues and
// PRs, a socket that answers merges, comments and closes by itself, and canned /api/gh replies.
// Pick what to show with ?w=issues|pulls|pull|issue|diff|face-issues|face-pulls|face-services|face-queue|markdown
//
//   flutter build web --release --no-web-resources-cdn -t lib/dev/preview_github.dart -o build/preview_github

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../net/office_socket.dart';
import '../office_scope.dart';
import '../shared/avatar.dart';
import '../shared/protocol.dart';
import '../state/store.dart';
import '../ui/boards.dart';
import '../ui/markdown.dart';
import '../ui/modal.dart';
import '../ui/pull.dart';
import '../ui/pull_diff.dart';
import '../ui/theme.dart';
import '../world/board_faces.dart';

const repo = 'https://github.com/acme/rocket';

String ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

Map<String, dynamic> label(String name, String color) => {'name': name, 'color': color};

final labels = {
  'bug': label('bug', '#d73a4a'),
  'enhancement': label('enhancement', '#a2eeef'),
  'ui': label('ui', '#5319e7'),
  'good first issue': label('good first issue', '#7057ff'),
  'in progress': label('in progress', '#fbca04'),
  'docs': label('docs', '#0075ca'),
  'perf': label('perf', '#0e8a16'),
};

GhIssue issue(int n, String title, {String state = 'OPEN', List<String> l = const [], List<String> assignees = const [], int comments = 0, int hours = 5, String author = 'mika'}) =>
    GhIssue.fromJson({
      'number': n,
      'title': title,
      'state': state,
      'url': '$repo/issues/$n',
      'author': author,
      'labels': [for (final x in l) labels[x]],
      'assignees': assignees,
      'createdAt': ago(Duration(hours: hours * 3)),
      'updatedAt': ago(Duration(hours: hours)),
      'body': sampleIssueBody,
      'comments': comments,
    });

GhPull pr(int n, String title,
        {String state = 'OPEN', bool draft = false, String review = 'REVIEW_REQUIRED', String checks = 'pass', int add = 42, int del = 7, List<String> l = const [], String head = '', int hours = 3, String author = 'ana'}) =>
    GhPull.fromJson({
      'number': n,
      'title': title,
      'state': state,
      'isDraft': draft,
      'url': '$repo/pull/$n',
      'author': author,
      'labels': [for (final x in l) labels[x]],
      'reviewDecision': review,
      'headRefName': head.isEmpty ? 'feat/pr-$n' : head,
      'baseRefName': 'main',
      'createdAt': ago(Duration(hours: hours * 4)),
      'updatedAt': ago(Duration(hours: hours)),
      'additions': add,
      'deletions': del,
      'checks': checks,
      'body': samplePrBody,
      'closes': [],
    });

const sampleIssueBody = '''The jukebox skips a track whenever someone joins the floor mid-song. It should pick up where everyone else is.

**Steps**
1. Start a track in the lounge
2. Join from a second browser
3. The new tab starts from 0:00

> [!NOTE]
> Only happens on floors with more than one person.

Related to #812, reported by @kenji-t.''';

const samplePrBody = '''## What

Moves the board faces to Flutter widgets so they can be drawn on the walls with `WidgetComponent`.

- [x] Issues and PR cork boards
- [x] Services chalkboard
- [ ] Queue whiteboard sheen

| Board | Before | After |
|---|---:|---:|
| Issues | 4.1 ms | 0.6 ms |
| Queue | 2.3 ms | 0.4 ms |

```ts
const face = new BoardTexture('issues');
face.render(store.issues, store.workers);
```

> [!WARNING]
> The old canvases stay until the cutover.

Closes #841. See [the plan](FLUTTER_WEB_PLAN.md) and ![diagram](https://example.com/diagram.png)
<!-- reviewers: please check the queue board -->''';

final issues = [
  issue(841, 'Board faces should repaint only when their notes change', l: ['perf', 'enhancement'], comments: 3),
  issue(839, 'Jukebox restarts the track when someone joins mid-song', l: ['bug'], comments: 5, hours: 2),
  issue(836, 'Add keyboard shortcuts to the PR files view', l: ['ui', 'good first issue'], hours: 20),
  issue(833, 'Dog gets stuck behind the kitchen counter on floor 2', l: ['bug'], assignees: ['ana'], comments: 2, hours: 9),
  issue(830, 'Show the worker provider on the queue board', l: ['in progress', 'ui'], hours: 30),
  issue(828, 'Document the /api/image proxy', l: ['docs'], hours: 50),
  issue(824, 'Let people rename floors from the elevator panel', hours: 70, author: 'kenji-t'),
  issue(820, 'Confetti clips through the ceiling in the loft', state: 'CLOSED', l: ['bug'], hours: 4),
  issue(815, 'Snow piles up on the balcony forever', state: 'CLOSED', hours: 40),
];

final pulls = [
  pr(852, 'Flutter: the GitHub windows and board faces', add: 2380, del: 12, l: ['ui'], head: 'wt/ui-github', checks: 'pending', hours: 1),
  pr(850, 'Fix jukebox sync for late joiners', review: 'APPROVED', add: 88, del: 31, l: ['bug'], head: 'fix/jukebox-sync', hours: 2),
  pr(849, 'WIP: smoke-break animation for workers', draft: true, add: 410, del: 3, checks: 'none', hours: 6, author: 'kenji-t'),
  pr(847, 'Queue: retry failed tasks with backoff', review: 'CHANGES_REQUESTED', checks: 'fail', add: 156, del: 44, hours: 12),
  pr(845, 'Speed up the diff parser on huge PRs', add: 64, del: 58, l: ['perf'], head: 'perf/diff', hours: 18, author: 'mika'),
  pr(843, 'Docs: explain floors and the elevator', state: 'MERGED', review: 'APPROVED', add: 120, del: 4, l: ['docs'], hours: 5),
  pr(840, 'Remove the old lobby carpet texture', state: 'MERGED', review: 'APPROVED', add: 2, del: 380, hours: 26),
  pr(838, 'Try WebGPU for the office renderer', state: 'CLOSED', add: 900, del: 200, hours: 60),
];

WorkerInfo worker(String id, String name, String color, String desk, String status, {String? branch, int? prNo}) => WorkerInfo.fromJson({
      'id': id,
      'kind': 'agent',
      'deskId': desk,
      'name': name,
      'color': color,
      'status': status,
      'createdBy': 'you',
      'createdAt': 0,
      if (branch != null) 'worktree': {'path': '/tmp/$id', 'branch': branch, 'base': 'main'},
      if (prNo != null) 'pr': {'number': prNo, 'url': '$repo/pull/$prNo'},
    });

final workers = {
  for (final w in [
    worker('w1', 'Pixel', '#4f86f7', 'desk-3', 'working', branch: 'wt/ui-github', prNo: 852),
    worker('w2', 'Mochi', '#ef476f', 'desk-5', 'needs_input', branch: 'fix/jukebox-sync'),
    worker('w3', 'Tofu', '#06d6a0', 'desk-1', 'idle'),
  ])
    w.id: w,
};

QueueTask task(String id, String status, {int? issue, String title = '', String? workerId, String? workerName, String? outcome, Map<String, dynamic>? pr, String provider = 'claude'}) =>
    QueueTask.fromJson({
      'id': id,
      'issue': issue,
      'title': title,
      'prompt': '',
      'addedBy': 'you',
      'addedAt': 0,
      'status': status,
      'provider': provider,
      'workerId': ?workerId,
      'workerName': ?workerName,
      'outcome': ?outcome,
      'pr': ?pr,
    });

final queue = QueueState.fromJson({'tasks': [], 'maxWorkers': 3});

QueueState fullQueue() => QueueState(maxWorkers: 3, tasks: [
      task('t1', 'running', issue: 830, title: '#830 Show the worker provider on the queue board', workerId: 'w1', workerName: 'Pixel'),
      task('t2', 'running', issue: 839, title: '#839 Jukebox restarts the track when someone joins mid-song', workerId: 'w2', workerName: 'Mochi', provider: 'opencode'),
      task('t3', 'queued', issue: 836, title: '#836 Add keyboard shortcuts to the PR files view'),
      task('t4', 'queued', issue: 828, title: '#828 Document the /api/image proxy', provider: 'codex'),
      task('t5', 'queued', title: 'Tidy up the loft plants'),
      task('t6', 'done', issue: 820, title: '#820 Confetti clips through the ceiling in the loft', outcome: 'done', pr: {'number': 843, 'url': '$repo/pull/843', 'state': 'MERGED', 'title': 'x'}),
      task('t7', 'done', issue: 815, title: '#815 Snow piles up on the balcony forever', outcome: 'killed'),
    ]);

ServicesState services() => ServicesState.fromJson({
      'port': 4600,
      'items': [
        {'port': 5173, 'host': '127.0.0.1', 'pid': 1, 'command': 'vite --port 5173', 'workerId': 'w1', 'title': 'Agent Office (dev)', 'since': 0},
        {'port': 8080, 'host': '127.0.0.1', 'pid': 2, 'command': 'python3 -m http.server 8080', 'workerId': 'w2', 'since': 0},
        {'port': 6006, 'host': '127.0.0.1', 'pid': 3, 'command': 'storybook dev -p 6006', 'workerId': 'w3', 'title': 'Storybook: board components', 'since': 0},
      ],
    });

Map<String, dynamic> comment(String id, String author, String body, int hoursAgo, {String? state}) =>
    {'id': id, 'author': author, 'body': body, 'createdAt': ago(Duration(hours: hoursAgo)), 'url': '$repo/pull/852#issuecomment-$id', 'state': ?state};

Map<String, dynamic> pullDetail(int n) => {
      'number': n,
      'body': samplePrBody,
      'state': 'OPEN',
      'isDraft': false,
      'reviewDecision': 'REVIEW_REQUIRED',
      'headRefName': 'wt/ui-github',
      'baseRefName': 'main',
      'mergeable': 'MERGEABLE',
      'mergeStateStatus': 'UNSTABLE',
      'commits': 4,
      'comments': [
        comment('c1', 'kenji-t', 'Nice! Does the queue board still strike through finished tasks?', 8),
        comment('c2', 'ana', 'Yes, see `QueueBoardPainter`. Screenshots below:\n\n- issues ✅\n- queue ✅', 6),
      ],
      'reviews': [
        comment('r1', 'mika', 'A couple of nits on the diff view, otherwise good to go.', 5, state: 'CHANGES_REQUESTED'),
        comment('r2', 'kenji-t', '', 2, state: 'APPROVED'),
      ],
      'reviewComments': [
        {'id': 101, 'author': 'mika', 'body': 'This should use `roundToDouble()` like the canvas did.', 'createdAt': ago(const Duration(hours: 5)), 'url': '$repo/pull/852#discussion_r101', 'path': 'app/lib/world/board_faces.dart', 'line': 4, 'side': 'RIGHT'},
        {'id': 102, 'replyTo': 101, 'author': 'ana', 'body': 'Good catch, fixed.', 'createdAt': ago(const Duration(hours: 4)), 'url': '$repo/pull/852#discussion_r102', 'path': 'app/lib/world/board_faces.dart', 'line': 4, 'side': 'RIGHT'},
        {'id': 103, 'author': 'mika', 'body': 'Was this removed on purpose?', 'createdAt': ago(const Duration(hours: 3)), 'url': '$repo/pull/852#discussion_r103', 'path': 'src/client/world/boards.ts', 'line': null, 'side': 'LEFT'},
      ],
      'checks': [
        {'name': 'build / web', 'state': 'pass', 'url': '$repo/actions/runs/1'},
        {'name': 'test / dart', 'state': 'pending', 'url': '$repo/actions/runs/2'},
        {'name': 'lint', 'state': 'pass'},
        {'name': 'deploy preview', 'state': 'skip'},
      ],
      'repo': {'nameWithOwner': 'acme/rocket', 'methods': ['squash', 'merge', 'rebase']},
      'viewer': 'office-bot',
    };

Map<String, dynamic> issueDetail(int n) => {
      'number': n,
      'state': 'OPEN',
      'body': sampleIssueBody,
      'comments': [
        comment('i1', 'ana', 'I can reproduce this on Firefox too.', 20),
        comment('i2', 'kenji-t', 'Probably the `pong` clock sync. See #812.\n\n```ts\nconst offset = m.now - (m.at + rtt / 2);\n```', 10),
      ],
      'viewer': 'office-bot',
    };

String fakeDiff() {
  final big = StringBuffer();
  for (var i = 1; i <= 30; i++) {
    big.writeln('+  "dep-$i": "^1.$i.0",');
  }
  return '''diff --git a/app/lib/world/board_faces.dart b/app/lib/world/board_faces.dart
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/app/lib/world/board_faces.dart
@@ -0,0 +1,9 @@
+// The faces of the four wall boards.
+import 'dart:math' as math;
+
+const kFaceSize = Size(1200, 600);
+
+class CorkBoardFace extends StatelessWidget {
+  const CorkBoardFace({super.key});
+}
+
diff --git a/app/lib/ui/pull.dart b/app/lib/ui/pull.dart
index 2222222..3333333 100644
--- a/app/lib/ui/pull.dart
+++ b/app/lib/ui/pull.dart
@@ -10,7 +10,8 @@ import 'package:flutter/material.dart';
 /// The board windows ask about the floor you're on.
-String onFloor(String url) => url;
+String onFloor(Store store, String url) =>
+    store.floor != null ? '\$url&floor=\${store.floor}' : url;

 const _mergeKey = 'agent-office.merge';
 const _filesKey = 'agent-office.pr-files';
 const _tabKey = 'agent-office.pr-tab';
diff --git a/src/client/world/boards.ts b/src/client/world/boards.ts
deleted file mode 100644
index 4444444..0000000
--- a/src/client/world/boards.ts
+++ /dev/null
@@ -1,4 +0,0 @@
-import * as THREE from 'three';
-import { DESK_BY_ID } from '../../shared/layout';
-
-const NOTE_COLORS = ['#fff7b0', '#ffd6e0'];
diff --git a/docs/boards.md b/docs/wall-boards.md
similarity index 100%
rename from docs/boards.md
rename to docs/wall-boards.md
diff --git a/app/assets/cork.png b/app/assets/cork.png
index 5555555..6666666 100644
Binary files a/app/assets/cork.png and b/app/assets/cork.png differ
diff --git a/app/pubspec.yaml b/app/pubspec.yaml
index 7777777..8888888 100644
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@ -12,3 +12,4 @@ dependencies:
   http: ^1.6.0
   web_socket_channel: ^3.0.3
+  markdown: ^7.3.1
   shared_preferences: ^2.5.5
\\ No newline at end of file
diff --git a/package-lock.json b/package-lock.json
index 9999999..aaaaaaa 100644
--- a/package-lock.json
+++ b/package-lock.json
@@ -1,3 +1,33 @@
 {
${big.toString()}   "name": "agent-office"
 }
''';
}

/// Answers the GitHub commands by itself, a moment later, as the server would.
class FakeSocket extends OfficeSocket {
  FakeSocket(this.store) : super(profile: () => (name: 'You', color: '#4f86f7', look: randomLook()), floor: () => 'main');
  final Store store;
  final _out = StreamController<ServerMsg>.broadcast();

  @override
  Stream<ServerMsg> get messages => _out.stream;

  @override
  void send(ClientMsg msg) {
    toast('→ ${msg.t}');
    Timer(const Duration(milliseconds: 700), () {
      switch (msg) {
        case GhMergeCmd m:
          _out.add(GhMergedMsg(m.number, error: m.method == GhMergeMethod.rebase ? 'GraphQL: Rebase merges are not allowed on this repository (mergePullRequest)' : null));
        case GhCommentCmd m:
          _out.add(GhCommentedMsg(
            kind: m.kind,
            number: m.number,
            comment: GhComment(id: 'new', author: 'office-bot', body: m.body, createdAt: DateTime.now().toUtc().toIso8601String(), url: '$repo/pull/${m.number}'),
          ));
        case GhCloseCmd m:
          _out.add(GhClosedMsg(kind: m.kind, number: m.number));
        default:
          break;
      }
    });
  }
}

class FakeActions implements OfficeActions {
  @override
  void sendToWorker(String title, {String? context, String? initial}) => toast('sendToWorker: $title');
  @override
  void goToDesk(String deskId) => toast('goToDesk: $deskId');
  @override
  dynamic noSuchMethod(Invocation invocation) => toast('${invocation.memberName}');
}

Store fakeStore() {
  final s = Store()
    ..floor = 'main'
    ..project = ProjectInfo.fromJson({'name': 'rocket', 'dir': '/src/rocket', 'agentCmd': 'claude', 'defaultProvider': 'claude', 'agentProviders': ['claude', 'opencode', 'codex']})
    ..workers = workers
    ..issues = GhState(items: issues, fetchedAt: DateTime.now().millisecondsSinceEpoch - 90000, loading: false)
    ..pulls = GhState(items: pulls, fetchedAt: DateTime.now().millisecondsSinceEpoch - 30000, loading: false)
    ..queue = fullQueue()
    ..services = services();
  return s;
}

void main() {
  GhApi.getJson = (url) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final n = int.parse(RegExp(r'number=(\d+)').firstMatch(url)![1]!);
    if (url.startsWith('/api/gh/pull')) return pullDetail(n);
    return issueDetail(n);
  };
  GhApi.getText = (url) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return fakeDiff();
  };
  runApp(const PreviewApp());
}

class PreviewApp extends StatefulWidget {
  const PreviewApp({super.key});

  @override
  State<PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<PreviewApp> {
  final store = fakeStore();
  late final net = FakeSocket(store);
  final which = Uri.base.queryParameters['w'] ?? 'pull';

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: officeTheme(),
        home: OfficeScope(
          store: store,
          net: net,
          settings: Settings(),
          actions: FakeActions(),
          child: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(child: which.startsWith('face-') ? _face(which) : const ColoredBox(color: Swatch.sky)),
                if (!which.startsWith('face-')) _Opener(which),
                const Positioned(top: 12, left: 0, right: 0, child: Center(child: ToastLayer())),
              ],
            ),
          ),
        ),
      );

  Widget _face(String w) {
    if (w == 'face-issues-empty') store.issues = const GhState(items: [], fetchedAt: 1, loading: false);
    if (w == 'face-queue-empty') store.queue = queue;
    final face = switch (w) {
      'face-pulls' => CorkBoardFace(store: store, kind: CorkKind.pulls),
      'face-services' => ServicesBoardFace(store: store),
      'face-queue' || 'face-queue-empty' => QueueBoardFace(store: store),
      _ => CorkBoardFace(store: store, kind: CorkKind.issues),
    };
    return ColoredBox(color: const Color(0xFF444444), child: Center(child: FittedBox(child: face)));
  }
}

class _Opener extends StatefulWidget {
  const _Opener(this.which);
  final String which;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  void _open() {
    ModalStack.instance.attach(Overlay.of(context));
    final scope = OfficeScope.read(context);
    switch (widget.which) {
      case 'issues':
        openBoard(scope, BoardKind.issues);
      case 'pulls':
        openBoard(scope, BoardKind.pulls);
      case 'issue':
        openIssue(scope, issues[1]);
      case 'diff':
        storageSet('agent-office.pr-tab', '"files"');
        final files = parseDiff(fakeDiff());
        final r = Reviewed('$repo/pull/852', KeyValueStore(get: storageGet, set: storageSet));
        r.set(files[2], true);
        // A file reviewed before it changed.
        r.set(files[1], true);
        files[1].hash = 'old';
        r.set(files[1], true);
        openPull(scope, pulls[0]);
      case 'markdown':
        ModalStack.instance.show((modal) => ModalWindow(
              modal: modal,
              width: 900,
              title: const Text('📝 Markdown'),
              bodyPadding: EdgeInsets.zero,
              body: const MarkdownView('$samplePrBody\n\n---\n\n$sampleIssueBody\n\n> [!CAUTION]\n> Careful with ~~force pushes~~.\n\n<details><summary>Logs</summary>\n\nall *green*\n</details>',
                  itemUrl: '$repo/pull/852'),
            ));
      default:
        storageSet('agent-office.pr-tab', '"conversation"');
        openPull(scope, pulls[0]);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
