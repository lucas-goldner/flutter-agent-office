// The games and rooms on your floor, wired into the office (main.ts's parts for them): the board
// agents at their kiosks, the arcade cabinet, the machine monitor, the basketball, the golf tee, the
// bookshelf and the meeting room. The controller hands it what you aim at and the keys you press, and
// it moves the camera when you're up at a screen.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:office_shared/cabinet.dart';
import 'package:office_shared/layout.dart' hide Cabinet;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

import '../ui/arcade.dart' show ScreenTexture;
import '../state/store.dart' show nowMs;
import '../ui/bookshelf.dart';
import '../ui/bookshelf_logic.dart' show githubUrl;
import '../ui/cabinet.dart';
import '../ui/meeting.dart';
import '../ui/hud_parts.dart' hide statusLabel;
import '../ui/modal.dart';
import '../ui/prompt.dart';
import '../ui/provider.dart' show resolvedProvider;
import '../ui/usage.dart' show usageLabel, usageTitle;
import '../ui/worker_text.dart' show statusLabel;
import '../world/character.dart';
import '../world/collider.dart';
import '../world/machine.dart';
import '../world/meeting.dart';
import '../world/office/rooms.dart';
import 'ball_play.dart';
import 'golf_play.dart';
import 'controller.dart';

/// What each board agent is for: its board's icon, what it offers on the card over its head, and an example ask.
const Map<StationKind, ({String icon, String offer, String does, String example})> stationInfo = {
  StationKind.issues: (
    icon: '📌',
    offer: 'Ask me about issues',
    does: 'I file, find, triage, label and close them',
    example: 'File an issue: the dog walks straight through the jukebox',
  ),
  StationKind.pulls: (
    icon: '🔀',
    offer: 'Ask me about PRs',
    does: 'I sum up, review, comment on and merge them',
    example: 'Review the newest PR and tell me if it’s ready to merge',
  ),
  StationKind.queue: (
    icon: '📋',
    offer: 'Ask me to queue work',
    does: 'I turn it into tasks for fresh workers',
    example: 'Queue every open bug issue, most important first',
  ),
};

/// Whether you set [w] going, or were the last to type to it: its questions are yours to answer.
bool yours(WorkerInfo w, String name) =>
    w.createdBy == name || w.createdBy == '$name (queue)' || w.lastInput?.by == name;

class RoomsHub {
  RoomsHub(this.c);

  final OfficeController c;
  late final RoomsView view;
  late final ArcadeCabinet cabinet;
  late final BallPlay ball;
  late final GolfPlay golf;
  late final ScreenTexture _machine;
  late final ScreenTexture _meetingBoard;
  late final ScreenTexture _meetingSign;
  final MachinePainter _machinePainter = MachinePainter();
  final List<({Worker model, String deskId})> _idleAgents = [];

  void init() {
    view = addRooms(c.office);
    cabinet = ArcadeCabinet(
      view.cabinetScreen,
      store: c.store,
      send: c.net.send,
      openTerminal: c.openWorkerTerminal,
      sound: (kind, [lines = 1]) => c.sound.arcade(kind.name, lines),
    );
    _machine = ScreenTexture(
      view.machineScreen,
      machineWidth,
      machineHeight,
      (g) => paintMachine(g, c.store.rooms.machine),
      pixels: 0.7,
    );
    _machine.paint();
    c.store.rooms.machineChanged.addListener(() {
      if (_machinePainter.changed(c.store.rooms.machine)) _machine.paint();
    });

    // The meeting room's board and door sign, drawn again whenever the meeting moves on.
    _meetingBoard = ScreenTexture(
      view.meetingBoard,
      boardWidth,
      boardHeight,
      (g) => paintMeetingBoard(g, c.store.rooms.meeting),
      pixels: 0.8,
    );
    _meetingSign = ScreenTexture(
      view.meetingSign,
      signWidth,
      signHeight,
      (g) => paintMeetingSign(g, c.store.rooms.meeting),
      pixels: 0.6,
    );
    void paintMeeting() {
      _meetingBoard.paint();
      _meetingSign.paint();
    }

    paintMeeting();
    c.store.rooms.meetingChanged.addListener(paintMeeting);

    // The floor's basketball, by the hoop.
    ball = BallPlay(c, view.hoop, () => c.office.colliders);
    c.office.group
      ..add(ball.node)
      ..add(ball.popsAnchor);
    c.office.interactables.add(ball.ball.interactable);
    c.store.rooms.ballChanged.addListener(ball.news);

    // Golf off the balcony.
    golf = GolfPlay(c, view.teeBall);
    c.office.group.add(golf.balls.group);

    // The board agents waiting by their boards before anyone has asked them anything.
    for (final def in stations) {
      final kind = def.station!;
      final agent = stationAgent[kind]!;
      final model = Worker(agent.name, agent.color, c.labels)
        ..setStatus(WorkerStatus.idle, false)
        ..setTask(WorkerTask(name: stationInfo[kind]!.offer, summary: stationInfo[kind]!.does));
      view.idleAgentSpots[def.id]!.add(model.root);
      _idleAgents.add((model: model, deskId: def.id));
    }
  }

  void dispose() {
    cabinet.dispose();
    golf.dispose();
  }

  /// The golf panel while you're at the tee (null otherwise).
  ValueListenable<GolfPanel?> get golfPanel => golf.panel;

  /// The wind-up meter to show over the hint (null when you're not winding up).
  ValueListenable<ShotMeter?> get meter => ball.meterShown;

  /// Anywhere between your view and a screen you're using: your first-person hands would cover it.
  bool get zoomed => cabinet.zoomed || golf.active;

  /// Moves things on, and the camera toward whichever screen you're using. Returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, double t, Size size) {
    view.hoop.update(dt);
    ball.update(nowMs());
    for (final a in _idleAgents) {
      final desk = c.office.desks[a.deskId];
      if (desk != null && desk.vacancy.visible) a.model.update(dt, t);
    }
    camera = cabinet.update(camera, dt, size);
    return golf.update(camera, dt);
  }

  /// A worker's status changed to [w]'s: one of yours needing input stops your game at the arcade.
  void workerChanged(WorkerInfo w) {
    if (w.status == WorkerStatus.needsInput && yours(w, c.store.peers[c.store.you]?.name ?? c.store.profile.name)) {
      cabinet.needsYou(w);
    }
  }

  /// A key at [it]. True when it was one of the rooms' own things.
  bool interact(Interactable it, DeskKey key) {
    switch (it.kind) {
      case InteractKind.station when it.deskId != null:
        final w = c.store.workerAtDesk(it.deskId!);
        if (key == DeskKey.e || key == DeskKey.p) {
          _askStation(it.deskId!);
        } else if (key == DeskKey.o && w != null) {
          c.openWorkerTerminal(w.id);
        } else if (key == DeskKey.x && w != null) {
          c.killWorker(w.id);
        }
        return true;
      case InteractKind.cabinet:
        if (key == DeskKey.e) cabinet.play();
        return true;
      case InteractKind.ball:
        if (key == DeskKey.e) ball.take();
        return true;
      case InteractKind.bookshelf:
        if (key == DeskKey.e) showBookshelf();
        return true;
      case InteractKind.meeting:
        if (key == DeskKey.e) showMeeting();
        return true;
      case InteractKind.golf:
        if (key == DeskKey.e) golf.start();
        return true;
      default:
        return false;
    }
  }

  /// A key (down or up) before the office's own: the ball in your hands takes E and Q.
  bool key(KeyEvent e) => golf.key(e) || ball.key(e);

  /// A click on the scene: with the ball in your hands, it winds up and shoots.
  bool click() => golf.active || ball.click();

  /// What the hint says whatever you look at: with the ball in hand, how to shoot.
  (String, List<HintPart>)? heldHint() => golf.active
      ? golf.hint()
      : ball.holding
      ? ball.hint()
      : null;

  /// Something to use that's near without aiming at it: the ball at your feet.
  Interactable? nearby() => ball.atFeet();

  /// E at the meeting room: how the meeting's going, or the form that calls one.
  void showMeeting([MeetingPreset? preset]) => openMeeting(
    store: c.store,
    send: c.net.send,
    openTerminal: c.openWorkerTerminal,
    openPr: (id) => c.net.send(WorkerPrCmd(id)),
    preset: preset,
  );

  /// E at the bookshelf: the floor's project's docs, to read.
  void showBookshelf() {
    final floor = c.store.floor;
    if (floor == null) return toast('Take the elevator to a floor first');
    openBookshelf(
      floor: floor,
      project: c.store.project?.name,
      repoUrl: githubUrl(c.store.project?.remote),
      // What you're reading goes under your name tag for everyone on the floor.
      onReading: (what) => c.net.send(DoingCmd(what: what, reading: what != null)),
    );
  }

  /// E at a board agent: type it a request. It's hired with it when nobody is there yet.
  void _askStation(String deskId) {
    final kind = deskById[deskId]?.station;
    if (kind == null) return;
    final w = c.store.workerAtDesk(deskId);
    final name = stationAgent[kind]!.name;
    final info = stationInfo[kind]!;
    // A prompt typed into a question it's asking would answer it.
    if (w?.status == WorkerStatus.needsInput) {
      toast("The $name is waiting on an answer — here's its terminal", ToastKind.warn);
      return c.openWorkerTerminal(w!.id);
    }
    final subtitle = w == null
        ? '${info.does}, in a terminal of my own: press O at the kiosk to watch.'
        : isAsleep(w.status)
        ? 'The $name is asleep: this wakes it up, and it carries on where it left off.'
        : isBusy(w.status)
        ? "The $name is busy. Your prompt waits in its input box until it's done."
        : null;
    openPrompt(
      PromptOptions(
        title: '${info.icon} Ask the $name',
        subtitle: subtitle,
        placeholder: 'e.g. ${info.example}',
        submitLabel: 'Send ✨',
        onSubmit: (text, _) => c.net.send(StationPromptCmd(deskId: deskId, prompt: text)),
      ),
    );
  }

  /// What the hint says at [it], or null when it's not one of the rooms' things.
  (String, List<HintPart>)? hint(Interactable it) {
    switch (it.kind) {
      case InteractKind.ball:
        return ball.ballHint();
      case InteractKind.golf:
        return golf.teeHint();
      case InteractKind.meeting:
        final m = c.store.rooms.meeting.current;
        if (m == null) {
          return (
            'free',
            [const HintTitle('🤝 Meeting room'), const HintAside('free'), const HintKey('E', 'Call a meeting')],
          );
        }
        final running = m.status == MeetingStatus.running;
        return (
          '${m.id}|${m.status}|${m.round}',
          [
            const HintTitle('🤝 Meeting room'),
            HintAside(
              running ? '${clip(m.title, 32)} · ${meetingStage(m)}' : '${clip(m.title, 32)} · ${m.status.wire}',
            ),
            HintKey('E', running ? 'How it’s going' : 'See it'),
          ],
        );
      case InteractKind.bookshelf:
        final names = [
          for (final p in c.store.peers.values)
            if (p.reading == true && p.id != c.store.you && c.store.onMyFloor(p)) p.name,
        ].join(', ');
        return (
          names,
          [
            const HintTitle('📚 Bookshelf'),
            HintAside(names.isNotEmpty ? '📖 ${clip(names, 40)} reading' : "the project's docs"),
            const HintKey('E', 'Read the docs'),
          ],
        );
      case InteractKind.station:
        return it.deskId == null ? ('', const []) : _stationHint(it.deskId!);
      case InteractKind.cabinet:
        final s = c.store.rooms;
        final p = s.cabinet.player;
        final f = s.cabinetFrame;
        if (p != null && p.id != c.store.you) {
          return (
            '${p.name}|${f?.score}',
            [
              const HintTitle('🕹️ Arcade'),
              HintAside('▶ ${clip(p.name, 24)} is playing${f != null ? ' · ${scoreText(f.score)}' : ''}'),
              const HintKey('E', 'Watch'),
            ],
          );
        }
        final left = cabinet.leftAt;
        final best = s.cabinet.scores.firstOrNull;
        final about = left != null
            ? "your game's paused at ${scoreText(left)}"
            : best != null
            ? '🏆 ${clip(best.name, 24)} · ${scoreText(best.score)}'
            : 'no high score yet';
        return (
          '$left|${best?.name}|${best?.score}',
          [const HintTitle('🕹️ $cabinetGame'), HintAside(about), HintKey('E', left != null ? 'Carry on' : 'Play')],
        );
      default:
        return null;
    }
  }

  (String, List<HintPart>) _stationHint(String deskId) {
    final kind = deskById[deskId]?.station;
    if (kind == null) return ('', const []);
    final w = c.store.workerAtDesk(deskId);
    final info = stationInfo[kind]!;
    if (w == null) {
      return (
        '',
        [
          HintTitle('${info.icon} ${stationAgent[kind]!.name}'),
          HintAside(info.offer.replaceFirst(RegExp(r'^Ask me '), '')),
          const HintKey('E', 'Prompt'),
        ],
      );
    }
    final doing = w.activity != null ? clip(w.activity!, 48) : '';
    final provider = resolvedProvider(w.provider, c.store.project);
    final spent = w.usage != null ? usageLabel(w.usage!, provider) : '';
    return (
      '${w.status}${w.id}$doing$spent',
      [
        HintTitle('${info.icon} ${w.name} · ${statusLabel(w.status)}'),
        if (doing.isNotEmpty) HintAside(doing),
        if (spent.isNotEmpty) HintCost(spent, tooltip: usageTitle(w.usage!, provider)),
        HintKey('E', isAsleep(w.status) ? 'Wake with a prompt' : 'Prompt'),
        const HintKey('O', 'Terminal'),
        const HintKey('X', 'Send home'),
      ],
    );
  }
}
