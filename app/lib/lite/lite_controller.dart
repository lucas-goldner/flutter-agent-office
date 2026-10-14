// The 2D view (/lite): the office without the 3D, for a phone or a computer the 3D office is too much
// for. Every worker on the floor and how it's doing, the ones waiting on someone first; its terminal,
// with the keys a phone's keyboard hasn't got and a box to send it a prompt; and the boards and the task
// queue. You're in the office as someone on the 2D view (PeerInfo.lite), not standing anywhere in it.
//
// This is lite.ts's logic: the socket, the store and what the windows call back into (OfficeActions).
// pages/lite_page.dart draws it. No flutter_scene here: nothing of the 3D office is built.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:office_shared/layout.dart' show deskById, nextFreeSeat;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart' show isAsleep;

import '../interop/browser.dart';
import '../net/api.dart';
import '../net/office_socket.dart';
import '../notify.dart';
import '../office_scope.dart';
import '../state/store.dart';
import '../ui/ask.dart';
import '../ui/changes.dart';
import '../ui/hud.dart' show watchTabTitle;
import '../ui/modal.dart';
import '../ui/prompt.dart';
import '../ui/provider.dart' show providerLabel;
import '../ui/queue.dart';
import '../ui/repos.dart' show repoChoices, workerRepoFolders;
import '../ui/search.dart';
import '../ui/settings_rows.dart' show SettingsPane;
import '../ui/signins.dart';
import '../ui/terminal.dart';
import '../ui/whereabouts.dart' show clipDoing;
import 'lite_logic.dart';

class LiteController implements OfficeActions, NotInTheOffice {
  /// [net] and [settings]: a test's own.
  LiteController({OfficeSocket? net, Settings? settings}) : settings = settings ?? Settings.load() {
    this.net =
        net ??
        OfficeSocket(
          profile: () => (name: store.profile.name, color: store.profile.color, look: store.profile.look),
          floor: () => store.floor ?? lastFloor(),
          lite: true,
        );
  }

  final Store store = Store();
  late final OfficeSocket net;
  final Settings settings;
  late final OfficeScope scope = OfficeScope(
    store: store,
    net: net,
    settings: settings,
    actions: this,
    child: const SizedBox(),
  );
  late final DesktopNotifier notifier = DesktopNotifier(enabled: () => settings.notify, openWorker: openWorker);

  /// Whether the socket is up (the "Reconnecting…" while it isn't).
  final ValueNotifier<bool> connected = ValueNotifier(true);

  /// Your name, asked for the first time this browser comes in on the shared password (see the page).
  final ValueNotifier<bool> needsName = ValueNotifier(false);

  /// The server version this page was loaded with.
  String _bootVersion = '';

  /// What each worker was last, to tell when one starts waiting on someone.
  final Map<String, WorkerStatus> _lastStatus = {};
  final List<VoidCallback> _unsubscribe = [];
  StreamSubscription<ServerMsg>? _messages;
  StreamSubscription<bool>? _status;
  Timer? _doingTimer;
  String? _doingSent;
  bool _readingSent = false;
  bool _askedToNotify = false;

  /// Who you are, then in: your account's name, the 3D office's profile, or a name you give (see [named]).
  Future<void> init() async {
    // Sent here because this browser can't draw the 3D office.
    if (pageQuery['why'] == 'webgl') {
      if (!desktopApp) replaceUrl(pagePath);
      toast("This browser can't draw the 3D office (WebGL is off or missing), so here's the 2D view", ToastKind.warn);
    }
    // Your name and color from the 3D office, if this browser has been in it. Nobody sees a character of
    // yours from here, so a look is only made up to connect with.
    final saved = loadProfile();
    store.profile
      ..name = saved?.name ?? 'Guest'
      ..color = saved?.color ?? kAvatarColors[1]
      ..look = saved?.look ?? store.profile.look;
    listen();
    try {
      final me = await Api.whoami();
      if (me == null) return goTo(loginUrl('/lite'));
      final m = me['me'];
      if (m is Map<String, dynamic>) store.me = Me.fromJson(m);
    } catch (_) {
      // the welcome message says it too
    }
    // With an account of your own, your name is that account's.
    final account = store.me.account;
    if (account != null) store.profile.name = account.name;
    if (saved != null || account != null) return net.connect();
    needsName.value = true;
  }

  /// Listens to the socket and the store (init does, before it connects).
  void listen() {
    _messages = net.messages.listen(_onMessage);
    _status = net.status.listen((up) => connected.value = up);
    store.topic(Topic.workers).addListener(_noticeWorkers);
    _unsubscribe
      ..add(() => store.topic(Topic.workers).removeListener(_noticeWorkers))
      ..add(watchTabTitle(store));
    // What you have open, for the others (see PeerInfo.doing).
    _doingTimer = Timer.periodic(const Duration(milliseconds: 300), (_) => _sendDoing());
  }

  /// Your name, the first time this browser comes in on the shared password.
  void named(String name) {
    store.profile.name = name;
    // No look: the 3D office still has you pick a character the first time you go in.
    saveNameOnly(name, store.profile.color);
    needsName.value = false;
    net.connect();
  }

  void dispose() {
    for (final f in _unsubscribe) {
      f();
    }
    _messages?.cancel();
    _status?.cancel();
    _doingTimer?.cancel();
    net.close();
  }

  void _onMessage(ServerMsg msg) {
    try {
      store.apply(msg);
    } catch (e, st) {
      debugPrint('store.apply(${msg.runtimeType}) failed: $e\n$st');
    }
    switch (msg) {
      case WelcomeMsg m:
        // Back from a restart on another version: this page's code is stale, so load the new one.
        if (_bootVersion.isEmpty) {
          _bootVersion = m.version;
        } else if (m.version != _bootVersion) {
          return reloadPage();
        }
        _offTheRoof();
        // After a reconnect the server has forgotten what we're doing (the terminal attaches itself again).
        _doingSent = null;
        _readingSent = false;
        _sendDoing();
      case FloorEnterMsg _:
        _offTheRoof();
      case FloorAddedMsg m when m.error != null:
        toast('🛗 ${m.error}', ToastKind.warn);
      case ToastMsg m:
        toast(m.text, switch (m.level) {
          ToastLevel.warn => ToastKind.warn,
          ToastLevel.error => ToastKind.error,
          _ => ToastKind.info,
        });
      case SignInsNeededMsg m:
        openSignIns(scope, m.why);
      case UpgradeMsg m when m.state.phase == UpgradePhase.restarting:
        net.expectRestart();
        toast('⬆️ The office is restarting on its new version. Back in a minute.');
      default:
        break;
    }
  }

  /// Nothing to see up on the roof from here: down to the first floor instead (the 3D office left you up there, say).
  void _offTheRoof() {
    final to = offTheRoof(store.floor, store.floors);
    if (to != null) net.send(FloorGoCmd(to));
  }

  void _sendDoing() {
    if (!net.up) return;
    final what = clipDoing(ModalStack.instance.doingNow);
    final reading = ModalStack.instance.readingNow;
    if (what == _doingSent && reading == _readingSent) return;
    _doingSent = what;
    _readingSent = reading;
    net.send(DoingCmd(what: what, reading: reading ? true : null));
  }

  /// A worker needs input or is done: a notification while you're elsewhere, and a buzz.
  void _noticeWorkers() {
    for (final w in newlyWaiting(store.workers.values, _lastStatus)) {
      notifier.alert(w);
      if (w.status == WorkerStatus.needsInput) vibrate(200);
    }
    notifier.sync(store.workers);
  }

  // ---- Workers ----------------------------------------------------------------------------------

  /// Its terminal, with the keypad, waking it up first if it's asleep.
  void openWorker(String id) {
    final w = store.workers[id];
    if (w == null) return;
    if (w.lost != null) return _fixLostWorktree(w);
    if (isAsleep(w.status)) resumeWorker(w);
    _terminal(id);
  }

  void _terminal(String id) => openTerminal(scope, id, onChanges: () => openWorkerChanges(id), keypad: true);

  @override
  void openWorkerTerminal(String workerId, {({int row, String needle})? find}) {
    final w = store.workers[workerId];
    if (w == null) return;
    if (w.lost != null) return _fixLostWorktree(w);
    if (isAsleep(w.status)) resumeWorker(w);
    openTerminal(scope, workerId, onChanges: () => openWorkerChanges(workerId), find: find, keypad: true);
  }

  @override
  void openWorkerChanges(String workerId, [String? repo]) {
    final w = store.workers[workerId];
    if (w == null) return;
    if (w.lost != null) return _fixLostWorktree(w);
    openChanges(scope, workerId, onTerminal: () => openWorker(workerId), repo: repo);
  }

  /// Its worktree was deleted outside agent-office: put it back (everyone's who lost theirs), or send it home.
  void _fixLostWorktree(WorkerInfo w) {
    final lost = w.lost, wt = w.worktree;
    if (lost == null || wt == null) return;
    final others = store.workers.values.where((o) => o.lost != null && o.id != w.id).toList();
    lostWorktreeDialog(
      LostWorktreeOptions(
        name: w.name,
        worktree: (path: wt.path, branch: wt.branch),
        lost: lost,
        workspace: (w.repos?.isNotEmpty ?? false) ? wt.path.replaceFirst(RegExp(r'[\\/][^\\/]*$'), '') : null,
        others: [for (final o in others) o.name],
        openTerminal: isAsleep(w.status) ? null : () => _terminal(w.id),
        rebuild: (all) {
          toast(all ? 'Rebuilding ${others.length + 1} worktrees…' : "Rebuilding ${w.name}'s worktree…");
          net.send(WorkerRebuildCmd(w.id, all: all));
        },
        sendHome: () => killWorker(w.id),
      ),
    );
  }

  /// ✍️ on a worker's card.
  void promptWorker(String id) {
    final w = store.workers[id];
    if (w == null) return;
    openPrompt(
      PromptOptions(
        title: '✍️ Prompt ${w.name}',
        subtitle: w.status == WorkerStatus.working
            ? "${w.name} is busy, so this waits in its input box until it's done."
            : null,
        placeholder: 'What should it do next?',
        submitLabel: 'Send',
        onSubmit: (text, _) => net.send(WorkerPromptCmd(id, text)),
      ),
    );
  }

  @override
  void hire(
    String deskId, {
    String? prompt,
    bool worktree = false,
    AgentProvider? provider,
    String? model,
    AgentEffort? effort,
    int? issue,
    List<String> repos = const [],
  }) {
    net.send(
      WorkerSpawnCmd(
        deskId: deskId,
        prompt: prompt,
        worktree: worktree,
        provider: provider,
        model: model,
        effort: effort,
        issue: issue,
        repos: repos.isEmpty ? null : repos,
      ),
    );
    // The moment notifications start to matter: ask once (it has to come from a tap).
    if (settings.notify && notifier.permission == NotifyPermission.ask && !_askedToNotify) {
      _askedToNotify = true;
      notifier.askPermission();
    }
  }

  @override
  void killWorker(String workerId) {
    final w = store.workers[workerId];
    if (w == null) return;
    final where = deskById[w.deskId]?.label ?? 'its desk';
    final wt = w.worktree;
    if (wt != null) {
      sendHomeDialog(
        scope,
        SendHomeOptions(
          workerId: workerId,
          name: w.name,
          where: where,
          worktree: (path: wt.path, branch: wt.branch),
          repos: workerRepoFolders(w),
          ask: () => net.send(WorkerWorktreeCmd(workerId)),
          onConfirm: (cleanup) => net.send(WorkerKillCmd(workerId, cleanup: cleanup)),
        ),
      );
      return;
    }
    final session = w.kind == WorkerKind.shell ? 'shared shell' : '${providerLabel(w.provider, store.project)} session';
    confirmDialog(
      'Send ${w.name} home?',
      'This stops the $session at $where for everyone and frees the desk.',
      'Send home',
      () => net.send(WorkerKillCmd(workerId)),
    );
  }

  @override
  void resumeWorker(WorkerInfo w) {
    if (w.lost != null) return _fixLostWorktree(w);
    if (w.sessionId == null && w.kind != WorkerKind.shell) {
      toast('${w.name} has no saved session — starting a fresh one', ToastKind.warn);
    }
    net.send(WorkerResumeCmd(w.id));
  }

  /// There's no desk to walk to from here: its terminal instead.
  @override
  void goToDesk(String deskId) {
    final w = store.workerAtDesk(deskId);
    if (w == null) return;
    ModalStack.instance.closeAll();
    openWorker(w.id);
  }

  /// Nobody's here to carry a card (the issue window has no ✋ on the 2D view, see [NotInTheOffice]).
  @override
  void pickUp(GhIssue issue) =>
      toast('📱 Cards are carried in the 3D office: 🤖 Hand to a worker instead', ToastKind.warn);

  // ---- New work: a prompt for a worker who's here, or a new one at a free desk ---------------------

  /// With [issue], the worker the prompt goes to takes that GitHub issue.
  @override
  void sendToWorker(String title, {String? context, String? initial, int? issue}) {
    if (store.project == null) return toast('Pick a floor first', ToastKind.warn);
    // The back office's desks too, as far as the floor's built out (see Wing).
    final desk = nextFreeSeat((id) => store.workerAtDesk(id) != null, store.floorPlan.wing)?.id;
    final awake = store.workers.values.where((w) => w.kind == WorkerKind.agent && !isAsleep(w.status)).toList();
    if (desk == null && awake.isEmpty) {
      return toast('Every desk and bean bag is taken — send a worker home first', ToastKind.warn);
    }
    openAsk(
      scope,
      AskOptions(
        title: title,
        context: context,
        initial: initial,
        newDesk: desk == null ? null : deskById[desk]!.label,
        workers: [for (final w in awake) AskWorker(id: w.id, name: w.name, color: w.color, status: w.status)],
        worktreeOption: store.project?.branch != null,
        providerOption: true,
        repoOptions: repoChoices(store),
        onSubmit: (prompt, to, worktree, provider, model, effort, repos) {
          if (to != null) {
            net.send(WorkerPromptCmd(to, prompt, issue: issue));
          } else if (desk != null) {
            hire(
              desk,
              prompt: prompt,
              worktree: worktree,
              provider: provider,
              model: model,
              effort: effort,
              issue: issue,
              repos: repos,
            );
          }
        },
      ),
    );
  }

  @override
  void showSearch() => openSearch(scope);

  @override
  void showQueue() => openQueue(scope);

  /// Settings are the 3D office's (the 2D view has nothing to set but notifications, which it asks for).
  @override
  void showSettings([SettingsPane? first]) => toast('⚙️ Settings are in the 3D office (🏢 3D)');

  /// New floors come from the elevator, in the 3D office.
  @override
  void showElevator() => toast('🛗 Add a project from the elevator in the 3D office (🏢 3D)');

  /// Nobody sees a character of yours from here.
  @override
  void editProfile() => toast('🧑 Your character is picked in the 3D office (🏢 3D)');

  @override
  void ride(String floorId) {
    if (floorId != store.floor) net.send(FloorGoCmd(floorId));
  }

  @override
  Future<void> signOut() async {
    await Api.postJson('/api/logout', {}).catchError((_) => ApiResult(0, {}));
    goTo(loginUrl('/lite'));
  }
}
