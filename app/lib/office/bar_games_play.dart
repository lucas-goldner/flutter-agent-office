// Darts and axes at the rooftop bar (features/bargames/index.ts): stepping up to the line, throws
// landing (yours and everyone's up there) and chalked up on the board, and your best rounds, kept in
// this browser.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:office_shared/bargames.dart';
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../audio/sound.dart' show TossSound;
import '../interop/portable.dart' show storageGet, storageSet;
import '../state/store.dart' show Topic, nowMs;
import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../world/bar_games.dart';
import '../world/collider.dart';
import '../world/space.dart';
import 'controller.dart';
import 'throwing.dart';

const _bestsKey = 'agent-office.bargames';

/// The emote keys, which do nothing mid-throw.
final _digits = {
  PhysicalKeyboardKey.digit1,
  PhysicalKeyboardKey.digit2,
  PhysicalKeyboardKey.digit3,
  PhysicalKeyboardKey.digit4,
  PhysicalKeyboardKey.digit5,
  PhysicalKeyboardKey.digit6,
  PhysicalKeyboardKey.numpad1,
  PhysicalKeyboardKey.numpad2,
  PhysicalKeyboardKey.numpad3,
  PhysicalKeyboardKey.numpad4,
  PhysicalKeyboardKey.numpad5,
  PhysicalKeyboardKey.numpad6,
};

/// Your best round at each game (points), kept in this browser.
Map<BarGame, int> throwBests() {
  try {
    final r = jsonDecode(storageGet(_bestsKey) ?? '{}');
    if (r is! Map) return {};
    return {
      for (final g in BarGame.values)
        if (r[g.wire] is num) g: (r[g.wire] as num).toInt(),
    };
  } catch (_) {
    return {};
  }
}

void _saveBests(Map<BarGame, int> bests) {
  try {
    storageSet(_bestsKey, jsonEncode({for (final e in bests.entries) e.key.wire: e.value}));
  } catch (_) {
    // a private window: it's only for this visit then
  }
}

/// Whether a round's total is one to cheer: a 180, or 30 or more with the axes.
bool greatRound(BarGame game, int total) => game == BarGame.darts ? total == 180 : total >= 30;

/// What the toast says about a round.
String roundText(BarGame game, int total) => game == BarGame.darts
    ? (total == 180 ? 'ONE HUNDRED AND EIGHTY!' : '$total with three darts')
    : '$total of 40 with five axes';

class _Round {
  _Round(this.by, this.name, this.color);
  final String by;
  final String name;
  final String color;
  final List<BarScore> scores = [];
}

class BarGamesPlay {
  BarGamesPlay(this.c);

  final OfficeController c;

  final Map<BarGame, int> _bests = throwBests();

  /// The round being thrown at each game up here: whose, and what each throw of it has scored so far.
  final Map<BarGame, _Round> _rounds = {};

  /// Who's at which line, from what they've done since their peer info (see peer.act).
  final Map<String, BarGame?> _throwing = {};

  late final Thrower thrower = Thrower(
    ThrowHooks(
      holding: (game) => c.net.send(ActCmd(throwing: game, throwingSet: true)),
      toss: (toss, from, turn) {
        c.net.send(TossCmd(game: toss.game, u: toss.u, v: toss.v, stick: toss.stick, n: toss.n));
        _tossHere(c.store.you, toss, from, turn);
      },
      aim: (game, u, v) => _games?.aim(game, u, v),
      done: c.staleHint,
      stand: (game) {
        final p = c.player;
        if (game == null) {
          p.enabled = !ModalStack.instance.open;
          p.input.clear();
          c.me.setThrowing(null);
          // Facing the target: in third person, the camera goes round behind you.
          final s = throwSpot(_lastGame ?? BarGame.darts);
          p
            ..camYaw = s.facing + math.pi
            ..lookPitch = -0.08;
          return;
        }
        _lastGame = game;
        final s = throwSpot(game);
        p
          ..enabled = false
          ..moving = false
          ..facing = s.facing;
        p.input.clear();
        p.pos.setValues(s.x, 0, s.z);
        c.me.setThrowing(game);
      },
      windBack: (k) => c.me.tossBack(k),
      letGo: (release) => c.me.toss(release),
    ),
    now: nowMs,
  );
  BarGame? _lastGame;

  BarGamesView? get _games => c.roofHub.rooftop?.games;

  void init() {
    c.store.topic(Topic.peers).addListener(_syncPeers);
  }

  void dispose() {
    c.store.topic(Topic.peers).removeListener(_syncPeers);
  }

  /// Which game [id] is at the line of, if any.
  BarGame? throwingOf(PeerInfo p) => _throwing.containsKey(p.id) ? _throwing[p.id] : p.throwing;

  /// Everyone up here holds what they're throwing (people arriving, a welcome after a reconnect).
  void _syncPeers() {
    _throwing.removeWhere((id, _) => !c.store.peers.containsKey(id));
    for (final p in c.store.peers.values) {
      if (p.id == c.store.you) continue;
      c.personOf(p.id)?.setThrowing(c.store.onMyFloor(p) ? throwingOf(p) : null);
    }
  }

  /// A message about the games: someone stepping up or back, or throwing.
  void onMessage(ServerMsg msg) {
    switch (msg) {
      case PeerActMsg m when m.throwingSet:
        // Stepped up to the dart board or the axe lane, or back from it.
        _throwing[m.id] = m.throwing;
        c.personOf(m.id)?.setThrowing(m.throwing);
      case TossMsg m:
        _theirToss(m.id, Toss(game: m.game, u: m.u, v: m.v, stick: m.stick, n: m.n));
      default:
        break;
    }
  }

  /// Who's at a game's line up here already, if anyone.
  String? lineTaken(BarGame game) {
    for (final p in c.store.peers.values) {
      if (p.id != c.store.you && throwingOf(p) == game && c.store.onMyFloor(p)) return p.name;
    }
    return null;
  }

  /// E at the dart board or the axe lane: step up to the line with a dart (or an axe) in hand.
  void stepUp(BarGame game) {
    if (thrower.active || c.travelling || c.climber.active) return;
    final other = lineTaken(game);
    if (other != null) {
      return toast('${game == BarGame.darts ? '🎯' : '🪓'} $other is throwing — wait your turn', ToastKind.warn);
    }
    if (c.player.seat != null) c.standUp();
    c.stopWalkingThere();
    thrower.start(game, c.player.camPos, c.player.camTarget);
  }

  /// Every frame: pulled away from the line (sat down, into the elevator), the dart or axe goes back.
  void update(double dt) {
    if (thrower.active &&
        (c.travelling || c.hanger.active || c.climber.active || c.player.seat != null || !c.roofHub.upTop)) {
      thrower.stop();
    }
    thrower.drunk = c.player.drunk;
    final keys = HardwareKeyboard.instance.physicalKeysPressed;
    bool held(PhysicalKeyboardKey a, PhysicalKeyboardKey b) =>
        !ModalStack.instance.open && (keys.contains(a) || keys.contains(b));
    thrower.update(
      dt,
      left: held(PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.arrowLeft),
      right: held(PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.arrowRight),
      up: held(PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.arrowUp),
      down: held(PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.arrowDown),
    );
    if (thrower.active) c.me.root.visible = true;
  }

  /// At the line: E steps back, Space throws, and nothing else is in reach (and no emotes mid-throw).
  bool key(KeyEvent e) {
    if (!thrower.active) return false;
    if (thrower.key(e)) return true;
    final k = e.physicalKey;
    if (k == PhysicalKeyboardKey.keyE) {
      if (e is KeyDownEvent) thrower.stop();
      return true;
    }
    return k == PhysicalKeyboardKey.keyF ||
        k == PhysicalKeyboardKey.keyG ||
        k == PhysicalKeyboardKey.keyP ||
        k == PhysicalKeyboardKey.keyR ||
        k == PhysicalKeyboardKey.keyX ||
        k == PhysicalKeyboardKey.keyB ||
        k == PhysicalKeyboardKey.keyC ||
        k == PhysicalKeyboardKey.keyO ||
        k == PhysicalKeyboardKey.keyL ||
        k == PhysicalKeyboardKey.keyK ||
        k == PhysicalKeyboardKey.keyN ||
        k == PhysicalKeyboardKey.keyQ ||
        _digits.contains(k);
  }

  /// At the dart board or the axe lane: who's throwing, or your best round, and E to step up.
  (String, List<HintPart>) hint(BarGame game) {
    final name = game == BarGame.darts ? '🎯 Darts' : '🪓 Axe throwing';
    final other = lineTaken(game);
    if (other != null) return ('taken|$other', [HintTitle(name), HintAside('${clip(other, 24)} is throwing')]);
    final best = _bests[game];
    final about = best != null
        ? 'your best round: $best'
        : game == BarGame.darts
        ? 'three darts a visit'
        : 'five axes a round';
    return (
      about,
      [
        HintTitle(name),
        HintAside(about),
        HintKey('E', game == BarGame.darts ? 'Step up to the oche' : 'Step up to the line'),
      ],
    );
  }

  /// At the line: how to aim and throw, and how to step back.
  (String, List<HintPart>) throwHint() => thrower.doing == ThrowStage.wind
      ? ('throw|wind', const [HintTitle('Let go in the green!')])
      : ('throw|aim', const [HintKey('Mouse', 'Aim'), HintKey('Space', 'Hold to throw'), HintKey('E', 'Step back')]);

  /// E at either: steps up. True when [it] was one of them.
  bool interact(Interactable it) {
    switch (it.kind) {
      case InteractKind.darts:
        stepUp(BarGame.darts);
        return true;
      case InteractKind.axe:
        stepUp(BarGame.axe);
        return true;
      default:
        return false;
    }
  }

  TossSound _sound(BarGame game, BarScore s, bool stick) => game == BarGame.darts
      ? (s.label == 'Miss' ? TossSound.wall : TossSound.board)
      : (stick ? TossSound.thunk : TossSound.clank);

  /// A throw at a game up here, by you or anyone else: it flies, lands, and goes up on the chalkboard.
  void _tossHere(String by, Toss toss, vm.Vector3 from, double turn) {
    final r = _games;
    if (r == null || !c.roofHub.upTop) return;
    final game = toss.game;
    final mine = by == c.store.you;
    final peer = c.store.peers[by];
    var round = _rounds[game];
    // A new round (or somebody else's): the last one's darts come out of the board first.
    if (toss.n == 1 || round == null || round.by != by) {
      r.clear(game);
      round = _rounds[game] = _Round(
        by,
        mine ? c.store.profile.name : (peer?.name ?? 'Someone'),
        mine ? c.store.profile.color : (peer?.color ?? '#8ecae6'),
      );
      r.chalk(game, (name: round.name, color: round.color, scores: round.scores));
      if (mine) thrower.setInfo('');
    }
    final it = round;
    c.sound.toss(game == BarGame.darts ? TossSound.dart : TossSound.axe, from.x, from.y, from.z);
    r.launch(toss, from, turn, it.color, () {
      final s = barScore(game, toss.u, toss.v, toss.stick);
      final at = r.point(game, toss.u, toss.v);
      c.sound.toss(_sound(game, s, toss.stick), at.x, at.y, at.z);
      // Somebody's next round started while this was on its way: it's still on the board, but not on theirs.
      if (_rounds[game] != it || it.scores.length >= barRound[game]!) return;
      it.scores.add(s);
      r.chalk(game, (name: it.name, color: it.color, scores: it.scores));
      r.pop(game, tossPop(game, s), it.color);
      if (s.label == 'Killshot') {
        final f = targetFrame(game);
        c.sound.toss(TossSound.cheer, at.x, at.y, at.z);
        c.confetti.burst(at.x + f.out.x * 0.3, at.y, at.z + f.out.z * 0.3, 90, 0.5);
      }
      final total = it.scores.fold<int>(0, (a, x) => a + x.points);
      if (mine) thrower.setInfo('${it.scores.map((x) => x.label).join(' · ')}  =  $total');
      if (it.scores.length == barRound[game]) _roundOver(game, it.name, mine, total);
    });
  }

  /// The last throw of a round landed: how it went, and a cheer for a great one.
  void _roundOver(BarGame game, String name, bool mine, int total) {
    final great = greatRound(game, total);
    if (great) {
      final f = targetFrame(game);
      c.sound.toss(TossSound.cheer, f.x, f.y, f.z);
      c.confetti.burst(f.x + f.out.x * 0.5, f.y + 0.4, f.z + f.out.z * 0.5, 200, 0.9);
    }
    final what = roundText(game, total);
    final icon = game == BarGame.darts ? '🎯' : '🪓';
    if (!mine) {
      if (great) toast('$icon $name: $what');
      return;
    }
    final best = _bests[game];
    final beat = best == null || total > best;
    if (beat) {
      _bests[game] = total;
      _saveBests(_bests);
    }
    toast('$icon $what${beat && best != null ? ' — your best yet!' : ''}');
  }

  /// Someone else up here threw one: their arm goes, then it flies from their hand.
  void _theirToss(String id, Toss toss) {
    final p = c.store.peers[id];
    if (p == null || !c.store.onMyFloor(p) || !c.roofHub.upTop) return;
    final person = c.personOf(id);
    void release(vm.Vector3 from, double turn) => _tossHere(id, toss, from, turn);
    if (person != null) {
      person.tossAuto(release);
    } else {
      release(vm.Vector3(p.x, p.y + 1.5, p.z), 0);
    }
  }

  /// Up on the roof again: whatever was thrown up there while you were away, you didn't see, so the boards start clean.
  void freshBoards() {
    final r = _games;
    if (r == null) return;
    for (final g in BarGame.values) {
      r
        ..clear(g)
        ..chalk(g, null);
      _rounds.remove(g);
    }
  }

  /// The mouse button down at the line: draw back. Up: let go.
  void pointerDown() => thrower.windUp();
  void pointerUp() => thrower.letGo();

  /// The free mouse at [ray] (engine space): the aim follows it onto the target.
  bool pointAt(vm.Ray ray) =>
      thrower.pointAt(vm.Ray.originDirection(fromEngine(ray.origin), fromEngine(ray.direction)));
}
