// Shooting hoops (main.ts's basketball): pick the ball up with E, hold E (or the mouse, in first
// person) to wind up while a meter runs up and down, and let go to shoot; Q drops it. The office
// keeps who has it and passes every throw on; the flying is world/hoop.dart's.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:office_shared/hoop.dart';
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../state/store.dart' show nowMs;
import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../world/collider.dart';
import '../world/hoop.dart';
import '../world/label_widgets.dart';
import '../world/labels.dart';
import '../world/player.dart' show ViewMode;

import 'package:flutter_scene/scene.dart' show Node;

import 'controller.dart';

/// The wind-up meter while you hold E: where it is (0–1), and whether you're shooting at the hoop
/// (then it shows the green band where the shot drops in).
typedef ShotMeter = ({double at, bool aimed});

class BallPlay {
  BallPlay(this.c, this.hoop, List<Collider> Function() colliders)
    : ball = Basketball(() => solidsOf(colliders().where((x) => !_isBoard(x)))) {
    final t = ball.tracker;
    t.onHit = (hit, at) {
      if (hit.kind == BallHitKind.score) {
        hoop.swish();
        c.sound.ball('score', Hoop.rim.x, Hoop.rim.y, Hoop.rim.z, hit.speed);
      } else if (hit.speed > 0.6) {
        c.sound.ball(hit.kind.name, at.x, at.y, at.z, hit.speed);
      }
    };
    t.onThrow = (by) => c.personOf(by)?.reach();
    t.onMiss = (by) {
      if (by == c.store.you && _shooting) streak = 0;
    };
    t.onBasket = _basket;
    _rim.position = vm.Vector3(Hoop.rim.x + 0.4, Hoop.rim.y + 0.9, Hoop.rim.z);
  }

  final OfficeController c;
  final HoopView hoop;
  final Basketball ball;

  /// Ball messages of yours the office hasn't answered yet (it answers every one): until it has, what
  /// you did stands, so picking it up and shooting quickly doesn't snap it back into your hands.
  int _pending = 0;

  /// Baskets of yours in a row, and whether your last throw was a shot at the hoop.
  int streak = 0;
  bool _shooting = false;

  /// When you started winding up a shot ([nowMs]), or 0.
  double _windFrom = 0;
  final Node _rim = Node(name: 'rim-pops');

  /// The meter over the hint while you wind up (null otherwise).
  final ValueNotifier<ShotMeter?> meterShown = ValueNotifier(null);

  bool get holding => ball.tracker.holder == c.store.you;

  Node get node => ball.node;
  Node get popsAnchor => _rim;

  /// The office said where the ball is.
  void news() {
    final r = c.store.rooms;
    if (r.ballFromEnter) {
      if (holding && r.ball.holder != c.store.you) {
        toast('🏀 The ball stayed behind, back under the other floor’s hoop');
      }
      _pending = 0;
    } else if (_pending > 0 && --_pending > 0) {
      return;
    }
    ball.tracker.set(r.ball, nowMs());
  }

  /// E at the ball: it's yours, if nobody beats you to it.
  void take() {
    if (ball.tracker.holder != null) return;
    c.sound.ball('bounce', ball.at.x, ball.at.y, ball.at.z, 1.5);
    ball.tracker.takeNow(c.store.you);
    _pending++;
    c.net.send(const BallTakeCmd());
  }

  /// How a shot of yours goes from where you are: out of your hands, which way, how steep, and how
  /// hard it takes to sink it (null: you're not shooting at the hoop).
  ({vm.Vector3 from, double heading, double pitch, double? ideal}) _aim() {
    const rim = Hoop.rim;
    final p = c.player;
    final first = p.view == ViewMode.first;
    // First person, the ball goes where you look; third, from over your head the way you face.
    final facing = first ? p.camYaw + math.pi : p.facing;
    final from = first ? p.camPos.clone() : vm.Vector3(p.pos.x, p.pos.y + 1.95, p.pos.z);
    from.x += math.sin(facing) * 0.3;
    from.z += math.cos(facing) * 0.3;
    final f = (x: from.x, y: from.y, z: from.z);
    final toRim = math.atan2(rim.x - from.x, rim.z - from.z);
    final off = math.atan2(math.sin(toRim - facing), math.cos(toRim - facing)).abs();
    final far = math.sqrt(math.pow(rim.x - from.x, 2) + math.pow(rim.z - from.z, 2));
    final atHoop = off < (first ? 0.35 : 0.6) && far < 16 && far > 0.4;
    if (first) {
      final look = throwPitch(p.lookPitch);
      final pitch = atHoop ? underCeiling(f, look) : look;
      return (from: from, heading: facing, pitch: pitch, ideal: atHoop ? idealSpeed(f, pitch) : null);
    }
    // Facing about the right way, your character squares up to the hoop.
    if (!atHoop) return (from: from, heading: facing, pitch: throwPitch(0.15), ideal: null);
    final pitch = underCeiling(f, throwPitch(lookAtRim(f)));
    return (from: from, heading: toRim, pitch: pitch, ideal: idealSpeed(f, pitch));
  }

  void windUp() {
    if (!holding || _windFrom > 0) return;
    _windFrom = nowMs();
  }

  /// Let go: it flies as hard as the meter says (right in the green, it drops in).
  void letFly() {
    if (_windFrom == 0) return;
    final power = meter((nowMs() - _windFrom) / 1000);
    _windFrom = 0;
    if (!holding) return;
    final a = _aim();
    final ideal = a.ideal;
    _shooting = ideal != null;
    _release(a.from, a.heading, a.pitch, ideal != null ? shotSpeed(ideal, power) : tossSpeed(power));
    if (c.player.view == ViewMode.first) {
      c.hands.reach();
    } else {
      c.me.reach();
    }
  }

  /// Q with the ball: it drops out of your hands in front of you.
  void drop() {
    if (!holding) return;
    _windFrom = 0;
    final p = c.player;
    final f = p.view == ViewMode.first ? p.camYaw + math.pi : p.facing;
    final from = handsOf(c.store.you) ?? _inView();
    _shooting = false;
    _release(from, f, 0, 0.25);
  }

  void _release(vm.Vector3 from, double heading, double pitch, double speed) {
    final cp = math.cos(pitch);
    final s = (
      x: from.x,
      y: from.y,
      z: from.z,
      vx: math.sin(heading) * cp * speed,
      vy: math.sin(pitch) * speed,
      vz: math.cos(heading) * cp * speed,
    );
    ball.tracker.throwNow(s, c.store.you, nowMs());
    _pending++;
    c.net.send(BallThrowCmd(x: s.x, y: s.y, z: s.z, vx: s.vx, vy: s.vy, vz: s.vz));
  }

  /// In front of your eyes, a little down: your own ball in first person.
  vm.Vector3 _inView() {
    final p = c.player;
    final look = (p.camTarget - p.camPos)..normalize();
    return p.camPos + look * 0.45 - vm.Vector3(0, 0.25, 0);
  }

  /// Where the ball is in [id]'s hands, or null when you can't see them.
  vm.Vector3? handsOf(String id) {
    if (id == c.store.you) {
      if (c.player.view == ViewMode.first) return _inView();
      return _held(c.me.root.position, c.player.facing);
    }
    final person = c.personOf(id);
    if (person == null) return null;
    final q = person.root.rotation;
    final f = q.rotated(vm.Vector3(0, 0, 1));
    return _held(person.root.position, math.atan2(f.x, f.z));
  }

  vm.Vector3 _held(vm.Vector3 at, double yaw) =>
      vm.Vector3(at.x + math.sin(yaw) * inHands.z, at.y + inHands.y, at.z + math.cos(yaw) * inHands.z);

  void _basket(Basket b) {
    final mine = b.by == c.store.you;
    final points = b.three ? 3 : 2;
    final peer = c.store.peers[b.by];
    final how = b.swish
        ? 'SWISH! '
        : b.bank
        ? 'BANK! '
        : '';
    _pop(
      mine ? '$how+$points' : '${clip(peer?.name ?? 'Someone', 16)} $how+$points',
      mine ? c.store.profile.color : (peer?.color ?? '#ff6b1a'),
    );
    if (mine) {
      streak++;
      final said = b.swish
          ? 'Swish!'
          : b.bank
          ? 'Off the glass!'
          : 'In off the rim!';
      toast('🏀 $said +$points from ${b.distance.toStringAsFixed(1)} m${streak > 1 ? ' · 🔥 $streak in a row' : ''}');
    }
    if (b.three || (mine && streak >= 3)) c.confetti.burst(Hoop.rim.x + 0.3, Hoop.rim.y, Hoop.rim.z, 140, 0.7);
  }

  /// Points floating up off the hoop, for a couple of seconds.
  void _pop(String text, String bg) {
    final l = c.labels.add(
      WorldLabel(
        anchor: _rim,
        child: TagPill(text, bg: bg, color: '#ffffff', size: 40),
      ),
    );
    Timer(const Duration(seconds: 2), () => c.labels.remove(l));
  }

  /// Every frame: the ball flies on (or goes wherever whoever has it goes).
  void update(double now) {
    ball.update(now, handsOf);
    if (!holding) _windFrom = 0;
    final on = _windFrom > 0 && !ModalStack.instance.open;
    final next = on ? (at: meter((now - _windFrom) / 1000), aimed: _aim().ideal != null) : null;
    if (next != meterShown.value) meterShown.value = next;
  }

  /// With the ball in your hands, E winds up a shot (let go to shoot) and Q drops it. True when it was the ball's.
  bool key(KeyEvent e) {
    if (!holding) return false;
    final k = e.physicalKey;
    if (k != PhysicalKeyboardKey.keyE && k != PhysicalKeyboardKey.keyQ) return false;
    if (e is KeyDownEvent) {
      if (k == PhysicalKeyboardKey.keyE) {
        windUp();
      } else {
        drop();
      }
    } else if (e is KeyUpEvent && k == PhysicalKeyboardKey.keyE) {
      letFly();
    }
    return true;
  }

  /// A click with the ball in your hands: the first winds up, the next lets go.
  bool click() {
    if (!holding) return false;
    if (_windFrom > 0) {
      letFly();
    } else {
      windUp();
    }
    return true;
  }

  /// With the ball in your hands: how to shoot, and how to put it down.
  (String, List<HintPart>) hint() {
    final first = c.player.view == ViewMode.first;
    final winding = _windFrom > 0;
    return (
      'ball!$streak|$first|$winding',
      [
        const HintTitle('🏀 Ball in hand'),
        if (streak > 1) HintAside('🔥 $streak in a row'),
        winding ? const HintAside('let go in the green!') : HintKey(first ? 'E / Click' : 'E', 'Hold to shoot'),
        const HintKey('Q', 'Drop it'),
      ],
    );
  }

  /// The hint at the ball itself.
  (String, List<HintPart>) ballHint() {
    final still = ball.tracker.still;
    return (
      '$still',
      [
        const HintTitle('🏀 Basketball'),
        if (still) const HintAside('shoot some hoops'),
        HintKey('E', still ? 'Pick it up' : 'Catch it!'),
      ],
    );
  }

  /// In first person, a ball at your feet is yours to pick up without looking right at it.
  Interactable? atFeet() {
    final it = ball.interactable;
    if (it.off) return null;
    final p = ball.at, me = c.player.pos;
    final dy = p.y - me.y;
    return math.sqrt(math.pow(p.x - me.x, 2) + math.pow(p.z - me.z, 2)) < 1.1 && dy < 1.2 && dy > -0.5 ? it : null;
  }
}

/// The hoop's own backboard collider, which the ball meets as [backboard] (bouncing harder) instead.
bool _isBoard(Collider x) =>
    x.maxX == Hoop.face && x.minX == Hoop.face - Hoop.board.thick && x.bottom == Hoop.board.bottom;
