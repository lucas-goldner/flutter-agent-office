// The arcade cabinet in the lounge (ui/cabinet.ts). Press E there and the camera glides up to its
// screen, where you play BLOCKFALL (ui/blocks.dart) on the keyboard. Everyone else on the floor sees
// your game on the cabinet as you play, and can walk up and press E to watch it up close. One of your
// workers needing input pauses it and says who; walking away leaves it paused for when you come back.
// Its score goes on the building's high-score table when you walk away and when the game ends.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:office_shared/cabinet.dart';
import 'package:office_shared/layout.dart' show deskById;
import 'package:office_shared/protocol.dart';

import '../state/store.dart';
import '../world/office/office.dart' show Face;
import 'arcade.dart';
import 'blocks.dart';
import 'modal.dart';
import 'theme.dart';

/// What the cabinet makes a noise about: a piece landing, lines clearing (how many), the game ending.
enum CabinetSound { land, clear, over }

/// Your game goes out to everyone watching at most this often (ms).
const double _frameMs = 90;

enum _Key { left, right, down, turn, back, drop, hold, pause, go }

/// Keys for the game.
final Map<PhysicalKeyboardKey, _Key> _keys = {
  PhysicalKeyboardKey.arrowLeft: _Key.left,
  PhysicalKeyboardKey.keyA: _Key.left,
  PhysicalKeyboardKey.arrowRight: _Key.right,
  PhysicalKeyboardKey.keyD: _Key.right,
  PhysicalKeyboardKey.arrowDown: _Key.down,
  PhysicalKeyboardKey.keyS: _Key.down,
  PhysicalKeyboardKey.arrowUp: _Key.turn,
  PhysicalKeyboardKey.keyW: _Key.turn,
  PhysicalKeyboardKey.keyX: _Key.turn,
  PhysicalKeyboardKey.keyZ: _Key.back,
  PhysicalKeyboardKey.space: _Key.drop,
  PhysicalKeyboardKey.keyC: _Key.hold,
  PhysicalKeyboardKey.shiftLeft: _Key.hold,
  PhysicalKeyboardKey.shiftRight: _Key.hold,
  PhysicalKeyboardKey.keyP: _Key.pause,
  PhysicalKeyboardKey.enter: _Key.go,
  PhysicalKeyboardKey.numpadEnter: _Key.go,
};

enum _Mode { play, watch }

/// Whether the office let go of the game you asked it to carry on with ([asked], '' for a new one):
/// it restarted, or gave up waiting for you, and started game [id] for you instead.
bool lostGame(String asked, String id) => asked != '' && id != asked;

class ArcadeCabinet {
  ArcadeCabinet(Face screen, {required this.store, required this.send, required this.openTerminal, required this.sound})
    : view = ScreenZoom(screen) {
    _texture = ScreenTexture(
      screen,
      blocksWidth,
      blocksHeight,
      (c) => paintBlocksScreen(c, _screen(_now())),
      pixels: 0.64,
    );
    store.rooms.cabinetChanged.addListener(_onState);
    store.rooms.cabinetFrameChanged.addListener(_onFrame);
    store.topic(Topic.workers).addListener(_onWorkers);
  }

  final Store store;
  final void Function(ClientMsg msg) send;
  final void Function(String workerId) openTerminal;
  final void Function(CabinetSound kind, [int lines]) sound;
  final ScreenZoom view;
  late final ScreenTexture _texture;

  _Mode? _mode;
  ModalHandle? _modal;

  /// Your game: the one you're playing, or the one you left paused.
  Blocks? _game;

  /// The game you last asked the office to carry on with, until it says which one you're on ('' for a new one).
  String _asked = '';

  /// Its game-over sound has played.
  bool _ended = false;
  ({int version, double at}) _sent = (version: -1, at: 0);

  /// The worker whose question paused your game.
  final ValueNotifier<WorkerInfo?> waiting = ValueNotifier(null);

  /// Who you're watching.
  String _watching = '';
  bool _dirty = true;
  int _painted = -1;
  int _blink = -1;

  /// The last frame from whoever's playing, to hear what changed.
  CabinetFrame? _heard;

  /// Bumped whenever the screen up close needs drawing again.
  final ValueNotifier<int> version = ValueNotifier(0);

  double _now() => nowMs();

  void dispose() {
    store.rooms.cabinetChanged.removeListener(_onState);
    store.rooms.cabinetFrameChanged.removeListener(_onFrame);
    store.topic(Topic.workers).removeListener(_onWorkers);
  }

  /// Anywhere between your view and the screen: your first-person hands would cover it.
  bool get zoomed => view.zoomed;

  /// Your game's score, while you've left it paused here.
  int? get leftAt {
    final g = _game;
    return g != null && !g.over && _mode != _Mode.play ? g.score : null;
  }

  /// E at the cabinet: play, or carry on with the game you left; watch whoever's on it already.
  void play() {
    if (_modal != null || store.floor == null) return;
    final p = store.rooms.cabinet.player;
    if (p != null && p.id != store.you) return _open(_Mode.watch);
    if (_game == null || _game!.over) _newGame();
    _ask(_game!.id);
    _open(_Mode.play);
  }

  /// One of your workers started waiting on an answer: your game stops for it, and says who.
  void needsYou(WorkerInfo w) {
    if (_mode != _Mode.play || _game == null) return;
    _game!.pause(true);
    waiting.value = w;
    _dirty = true;
  }

  /// Runs the game, sends it to everyone watching, keeps the screens drawn and moves the camera. Call
  /// it once the player has placed the camera; returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, Size size) {
    final g = _game;
    final now = _now();
    if (_mode == _Mode.play && g != null) {
      g.update(dt);
      if (g.over && !_ended) {
        _ended = true;
        sound(CabinetSound.over);
      }
      if (g.version != _sent.version && now - _sent.at >= _frameMs) _sendFrame();
      if (g.version != _painted) _dirty = true;
    }
    // The blinking "press E" with nobody playing.
    final blink = (now / 1000 * 1.6).floor() % 2;
    if (blink != _blink) {
      _blink = blink;
      if (_idle()) _dirty = true;
    }
    if (_dirty) _paint();
    return view.update(camera, dt, size, _modal != null);
  }

  void _newGame() {
    final g = Blocks();
    g.onLand = (lines) => lines > 0 ? sound(CabinetSound.clear, lines) : sound(CabinetSound.land);
    _game = g;
    _ended = false;
    _sent = (version: -1, at: 0);
  }

  /// Asks the office to carry on with game [id], or to start a new one (''): it says which you're on in `cabinet`.
  void _ask(String id) {
    _asked = id;
    send(CabinetPlayCmd(game: id.isEmpty ? null : id));
  }

  /// Your game as it looks now, to everyone watching, unless they've seen it already. The office goes
  /// by these for your score too, so the last one goes out before you step away.
  void _sendFrame() {
    final g = _game;
    if (g == null || g.version == _sent.version) return;
    _sent = (version: g.version, at: _now());
    send(CabinetFrameCmd(g.frame()));
  }

  void _resume() {
    waiting.value = null;
    _game?.pause(false);
  }

  void _open(_Mode mode) {
    _mode = mode;
    _watching = mode == _Mode.watch ? (store.rooms.cabinet.player?.name ?? '') : '';
    final tip = mode == _Mode.play
        ? '← → move · ↑ turn · ↓ faster · Space drop · C hold · P pause'
        : '👀 Watching $_watching';
    _modal = ModalStack.instance.show(
      (modal) => ScreenBox(
        rect: view.rect,
        screen: _CabinetScreen(cabinet: this, keys: mode == _Mode.play),
        over: _CallBar(cabinet: this),
        bar: screenBar('🕹️ $cabinetGame', tip, mode == _Mode.play ? '✕ Stop playing' : '✕ Stop watching', modal.close),
      ),
      backdropCloses: false,
      clear: true,
      onClose: _closed,
    )..doing = mode == _Mode.play ? '🕹️ playing $cabinetGame' : '👀 watching $_watching play $cabinetGame';
    _dirty = true;
  }

  /// Stepped away: your game waits, paused, with its score on the table so far.
  void _closed() {
    final was = _mode;
    _mode = null;
    _modal = null;
    waiting.value = null;
    _watching = '';
    _dirty = true;
    if (was != _Mode.play) return;
    final g = _game;
    // A game you never got going isn't worth coming back to.
    if (g != null && g.pieces == 0 && g.score == 0) {
      _game = null;
    } else {
      _sendFrame();
    }
    send(const CabinetLeaveCmd());
    g?.pause(true);
  }

  /// A key while you play. True when it was the game's.
  bool _key(KeyEvent e) {
    final k = _keys[e.physicalKey];
    final g = _game;
    final hk = HardwareKeyboard.instance;
    if (k == null || g == null || hk.isMetaPressed || hk.isControlPressed || hk.isAltPressed) return false;
    if (e is KeyUpEvent) {
      if (k == _Key.left) {
        g.release(-1);
      } else if (k == _Key.right) {
        g.release(1);
      } else if (k == _Key.down) {
        g.softDrop(false);
      }
      return true;
    }
    // Held keys slide and drop on their own time, not the keyboard's repeat.
    if (e is! KeyDownEvent) return true;
    if (g.over) {
      if (k == _Key.go || k == _Key.drop) {
        _newGame();
        // A new game for the office to follow, and name.
        _ask('');
        _dirty = true;
      }
      return true;
    }
    if (g.state == PlayState.paused) {
      if (k == _Key.pause || k == _Key.go) _resume();
      return true;
    }
    switch (k) {
      case _Key.left:
        g.press(-1);
      case _Key.right:
        g.press(1);
      case _Key.down:
        g.softDrop(true);
      case _Key.turn:
        g.rotate(1);
      case _Key.back:
        g.rotate(-1);
      case _Key.drop:
        g.hardDrop();
      case _Key.hold:
        g.hold();
      case _Key.pause:
        g.pause(true);
      case _Key.go:
        break;
    }
    return true;
  }

  /// Who's at the cabinet changed.
  void _onState() {
    final p = store.rooms.cabinet.player;
    _heard = store.rooms.cabinetFrame;
    if (_mode == _Mode.play) {
      if (p != null && p.id != store.you) {
        // Someone else got there first: watch them instead.
        _modal?.close();
        _open(_Mode.watch);
      } else if (p == null) {
        // The office forgot (a dropped connection): still here.
        _ask(_game?.id ?? '');
      } else if (_game != null) {
        // It can't follow the old game on from where it was, so a new one for the new game it started.
        if (lostGame(_asked, p.game)) {
          _newGame();
          toast("🕹️ The office lost track of your game, so here's a new one");
        }
        _asked = '';
        _game!.id = p.game;
      }
    } else if (_mode == _Mode.watch && (p == null || p.id == store.you || p.name != _watching)) {
      if (p == null) toast('$_watching stepped away from the arcade');
      _modal?.close();
    }
    _dirty = true;
  }

  /// Someone else's game moved on: hear it land, clear lines and end.
  void _onFrame() {
    final f = store.rooms.cabinetFrame;
    final was = _heard;
    _heard = f;
    _dirty = true;
    if (f == null || was == null) return;
    if (f.lines > was.lines) {
      sound(CabinetSound.clear, f.lines - was.lines);
    } else if (f.pieces > was.pieces) {
      sound(CabinetSound.land);
    }
    if (f.state == PlayState.over && was.state != PlayState.over) sound(CabinetSound.over);
  }

  /// The worker that paused your game got its answer from someone else.
  void _onWorkers() {
    final w = waiting.value;
    if (w == null || store.workers[w.id]?.status == WorkerStatus.needsInput) return;
    waiting.value = null;
    _dirty = true;
  }

  /// Nobody's game on the screen, just the high scores.
  bool _idle() {
    final p = store.rooms.cabinet.player;
    return !(_mode == _Mode.play && _game != null) &&
        !(p != null && p.id != store.you && store.rooms.cabinetFrame != null);
  }

  /// What the screen shows: your game, someone else's, or the high scores with nobody playing.
  ScreenView _screen(double now) {
    final c = store.rooms.cabinet;
    final g = _game;
    final t = now / 1000;
    if (_mode == _Mode.play && g != null) {
      final rank = c.scores.indexWhere((s) => s.game == g.id) + 1;
      final w = waiting.value;
      return ScreenView(
        frame: g.frame(),
        player: store.profile.name,
        scores: c.scores,
        mine: g.id,
        note: w != null ? '${w.name} needs you${_deskOf(w)}' : 'P to carry on',
        prompt: rank > 0 ? '🏆 #$rank on the table! Enter: again' : 'Enter to play again',
        t: t,
      );
    }
    final p = c.player;
    if (p != null && p.id != store.you) {
      final f = store.rooms.cabinetFrame;
      return ScreenView(
        frame: f,
        player: p.name,
        scores: c.scores,
        mine: p.game,
        note: 'Back in a moment',
        prompt: f != null ? null : '▶ ${p.name.toUpperCase()}',
        t: t,
      );
    }
    return ScreenView(
      scores: c.scores,
      mine: g?.id,
      prompt: leftAt != null ? 'PRESS E TO CARRY ON' : 'PRESS E TO PLAY',
      t: t,
    );
  }

  /// Draws the screen up close while you play or watch, and on the cabinet otherwise (the close one covers it).
  void _paint() {
    _dirty = false;
    if (_game != null) _painted = _game!.version;
    if (_modal != null) {
      version.value++;
    } else {
      _texture.paint();
    }
  }
}

/// " at Desk 3", or nothing when it's not at a desk here.
String _deskOf(WorkerInfo w) {
  final d = deskById[w.deskId];
  return d == null ? '' : ' at ${d.station != null ? 'the ${d.label}' : d.label}';
}

/// The screen you play or watch on up close, drawn at the size it shows on the page so it stays crisp.
class _CabinetScreen extends StatelessWidget {
  const _CabinetScreen({required this.cabinet, required this.keys});
  final ArcadeCabinet cabinet;
  final bool keys;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) => keys && cabinet._key(e) ? KeyEventResult.handled : KeyEventResult.ignored,
    onFocusChange: (on) {
      if (!on) cabinet._game?.releaseAll();
    },
    child: ValueListenableBuilder<int>(
      valueListenable: cabinet.version,
      builder: (context, v, _) =>
          CustomPaint(size: Size.infinite, painter: _ScreenPainter(cabinet._screen(cabinet._now()), v)),
    ),
  );
}

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.view, this.version);
  final ScreenView view;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / blocksWidth, size.height / blocksHeight);
    paintBlocksScreen(canvas, view);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScreenPainter old) => old.version != version;
}

/// Over the screen while a worker waits on you: who, and a way to its terminal.
class _CallBar extends StatelessWidget {
  const _CallBar({required this.cabinet});
  final ArcadeCabinet cabinet;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<WorkerInfo?>(
    valueListenable: cabinet.waiting,
    builder: (context, w, _) {
      if (w == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(
          color: Swatch.paper,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Swatch.ink, width: kBorder),
          boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text('🙋 ${w.name} needs input${_deskOf(w)}', style: heavy(13))),
            const SizedBox(width: 10),
            OfficeButton(
              label: '💬 Open its terminal',
              kind: BtnKind.primary,
              onPressed: () {
                cabinet._modal?.close();
                cabinet.openTerminal(w.id);
              },
            ),
            const SizedBox(width: 6),
            OfficeButton(label: '▶ Carry on', onPressed: cabinet._resume),
          ],
        ),
      );
    },
  );
}
