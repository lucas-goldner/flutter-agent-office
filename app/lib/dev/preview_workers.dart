// Preview of the worker windows, with a fake office (or, for the terminal, a real one):
//   ?w=terminal|changes|prompt|sendhome|ask|queue|search|provider|laptop
//   ?w=terminal&real=1   connects to the office serving this page and opens a shell worker's terminal
//                        (spawning one at a free desk when there is none).
// Build: flutter build web --release --no-web-resources-cdn -t lib/dev/preview_workers.dart -o build/preview_workers

import 'dart:async';

import 'package:flutter/material.dart';

import '../net/office_socket.dart';
import '../office_scope.dart';
import '../shared/avatar.dart';
import '../shared/layout.dart' as layout;
import '../shared/protocol.dart';
import '../state/store.dart';
import '../ui/ask.dart';
import '../ui/changes.dart';
import '../ui/modal.dart';
import '../ui/prompt.dart';
import '../ui/queue.dart';
import '../ui/search.dart';
import '../ui/terminal.dart';
import '../ui/theme.dart';
import '../world/laptop_screen.dart';
import 'preview_workers_data.dart';

void main() {
  final q = Uri.base.queryParameters;
  runApp(_PreviewApp(which: q['w'] ?? 'terminal', real: q['real'] == '1'));
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp({required this.which, required this.real});

  final String which;
  final bool real;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: officeTheme(),
    home: Scaffold(
      backgroundColor: Swatch.sky,
      body: which == 'laptop' ? const _Laptops() : _Office(which: which, real: real),
    ),
  );
}

/// A stand-in socket: logs what the windows send and answers like the office would.
class FakeSocket extends OfficeSocket {
  FakeSocket(this.store) : super(profile: () => (name: 'Ada', color: '#4f86f7', look: randomLook()), floor: () => null);

  final Store store;
  final _msgs = StreamController<ServerMsg>.broadcast(sync: true);
  final List<ClientMsg> sent = [];

  @override
  Stream<ServerMsg> get messages => _msgs.stream;

  void emit(ServerMsg m) {
    store.apply(m);
    _msgs.add(m);
  }

  @override
  void send(ClientMsg msg) {
    sent.add(msg);
    debugPrint('→ ${msg.toJson()}');
    Timer(const Duration(milliseconds: 150), () {
      switch (msg) {
        case WorkerAttachCmd(:final workerId):
          emit(TermSnapshotMsg(workerId: workerId, data: demoAnsi, cols: 100, rows: 30));
        case ChangesWatchCmd(:final workerId):
          emit(ChangesMsg(ChangesState.fromJson(demoChanges(workerId))));
        case ChangesDiffCmd(:final workerId, :final path):
          emit(ChangesDiffMsg(workerId: workerId, path: path, diff: demoDiff, truncated: false));
        case WorkerWorktreeCmd(:final workerId):
          Timer(const Duration(milliseconds: 600), () {
            emit(WorkerWorktreeMsg(workerId, const WorktreeState(exists: true, dirty: 3, ahead: 2, unpushed: 1)));
          });
        default:
          break;
      }
    });
  }
}

class _Actions implements OfficeActions {
  late OfficeScope scope;

  @override
  void openWorkerTerminal(String workerId, {TerminalFind? find}) =>
      openTerminal(scope, workerId, onChanges: () => openWorkerChanges(workerId), find: find);

  @override
  void openWorkerChanges(String workerId) => openChanges(scope, workerId, onTerminal: () => openWorkerTerminal(workerId));

  @override
  void showQueue() => openQueue(scope);

  @override
  void showSearch() => openSearch(scope);

  @override
  void killWorker(String workerId) => scope.net.send(WorkerKillCmd(workerId));

  @override
  dynamic noSuchMethod(Invocation invocation) => debugPrint('action ${invocation.memberName}');
}

class _Office extends StatefulWidget {
  const _Office({required this.which, required this.real});

  final String which;
  final bool real;

  @override
  State<_Office> createState() => _OfficeState();
}

class _OfficeState extends State<_Office> {
  final store = Store();
  final actions = _Actions();
  late final OfficeSocket net;
  final _overlay = GlobalKey<OverlayState>();
  StreamSubscription<ServerMsg>? _sub;
  bool _opened = false;
  bool _spawned = false;

  @override
  void initState() {
    super.initState();
    if (widget.real) {
      net = OfficeSocket(
        profile: () => (name: Uri.base.queryParameters['name'] ?? 'Preview', color: '#4f86f7', look: randomLook()),
        floor: () => null,
      );
      _sub = net.messages.listen((m) {
        store.apply(m);
        _realStep();
      });
      net.connect();
    } else {
      net = FakeSocket(store);
      fillStore(store);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ModalStack.instance.attach(_overlay.currentState!);
      if (!widget.real) _open();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  OfficeScope get scope => OfficeScope(store: store, net: net, settings: Settings(), actions: actions, child: const SizedBox());

  /// Real mode: open the first shell worker's terminal, hiring one at a free desk if there is none.
  void _realStep() {
    if (_opened || store.floor == null) return;
    if (widget.which == 'search') {
      // Real search: GET /api/search, and a terminal hit opens that terminal at the line.
      _opened = true;
      actions.scope = scope;
      openSearch(scope, query: Uri.base.queryParameters['q'] ?? 'hello');
      return;
    }
    final shell = store.workers.values.where((w) => w.kind == WorkerKind.shell).firstOrNull;
    if (shell != null) {
      _opened = true;
      actions.scope = scope;
      openTerminal(scope, shell.id, onChanges: () => actions.openWorkerChanges(shell.id));
      return;
    }
    if (_spawned) return;
    _spawned = true;
    final free = layout.desks.where((d) => store.workerAtDesk(d.id) == null).first;
    net.send(WorkerSpawnCmd(deskId: free.id, kind: WorkerKind.shell));
  }

  void _open() {
    actions.scope = scope;
    final s = scope;
    switch (widget.which) {
      case 'terminal':
        openTerminal(
          s,
          'w-claude',
          onChanges: () => actions.openWorkerChanges('w-claude'),
          find: Uri.base.queryParameters['find'] == null ? null : (row: 12, needle: Uri.base.queryParameters['find']!),
        );
      case 'changes':
        openChanges(s, 'w-claude', onTerminal: () => actions.openWorkerTerminal('w-claude'));
      case 'prompt':
        openPrompt(
          PromptOptions(
            title: '✨ Hire a worker at Desk 3',
            subtitle: 'They start in the project folder, with the whole office watching.',
            worktreeOption: true,
            providerOption: true,
            project: store.project,
            onSubmit: (text, opts) => debugPrint('prompt: $text $opts'),
          ),
        );
      case 'confirm':
        confirmDialog(
          'Discard the changes to hud.ts?',
          'This puts src/client/ui/hud.ts back to the last commit in the project folder. Committed changes stay.',
          'Discard',
          () {},
        );
      case 'sendhome':
        sendHomeDialog(
          s,
          SendHomeOptions(
            workerId: 'w-claude',
            name: 'Nova',
            where: 'Desk 3',
            worktree: (path: '.agent-office/worktrees/nova', branch: 'nova/fix-login'),
            onConfirm: (c) => debugPrint('send home: $c'),
          ),
        );
      case 'ask':
        openAsk(
          s,
          AskOptions(
            title: '🙋 Ask about #42 Login button does nothing on Safari',
            context: 'GitHub issue #42 in acme/app: "Login button does nothing on Safari"\nhttps://github.com/acme/app/issues/42',
            initial: 'Please look into this issue and fix it.',
            newDesk: 'Desk 5',
            workers: [for (final w in store.workers.values) AskWorker(id: w.id, name: w.name, color: w.color, status: w.status)],
            worktreeOption: true,
            providerOption: true,
            onSubmit: (p, to, wt, provider, model) => debugPrint('ask: $to $wt $provider $model\n$p'),
          ),
        );
      case 'queue':
        openQueue(s);
      case 'search':
        searchOverride = (q) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return SearchResults.fromJson(demoSearch(q));
        };
        openSearch(s, query: Uri.base.queryParameters['q'] ?? 'login');
      case 'provider':
        openPrompt(PromptOptions(title: 'Provider', providerOption: true, project: store.project, onSubmit: (_, _) {}));
    }
  }

  @override
  Widget build(BuildContext context) => OfficeScope(
    store: store,
    net: net,
    settings: Settings(),
    actions: actions,
    child: Stack(
      children: [
        Overlay(
          key: _overlay,
          initialEntries: [OverlayEntry(builder: (_) => const Center(child: Text('Agent Office · worker windows preview')))],
        ),
        const Positioned(top: 16, left: 0, right: 0, child: Center(child: ToastLayer())),
      ],
    ),
  );
}

/// A few laptop screens, as the desks would show them.
class _Laptops extends StatelessWidget {
  const _Laptops();

  @override
  Widget build(BuildContext context) {
    Widget screen(ScreenState? s, String label, {String? placeholder, int zoom = 22}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 512,
          height: 340,
          child: FittedBox(
            child: LaptopScreen(screen: s, placeholder: placeholder, zoomRows: zoom),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: heavy(13)),
      ],
    );
    return Center(
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          screen(demoScreen(), 'Claude Code, zoomed (22)'),
          screen(demoScreen(), 'the whole screen (0)', zoom: 0),
          screen(sparseScreen(), 'a sparse shell'),
          screen(null, 'placeholder', placeholder: 'asleep 💤'),
        ],
      ),
    );
  }
}
