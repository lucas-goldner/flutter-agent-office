// The office dog, as everyone on the floor sees it: a port of world/dog.ts. A chunky cartoon pup
// that walks where the server says (see shared/dog.dart), sits, lies down, naps with its head on its
// paws, sniffs, barks at a worker that needs input and wags when it's petted. Forward is +z.

import '../audio/sound_model.dart' show DogSounds;
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Alignment;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/dog.dart';
import 'collider.dart';
import 'geo.dart';
import 'label_widgets.dart';
import 'labels.dart';
import 'toon.dart';

/// What the body eases toward for each thing it does.
class DogPoseTarget {
  DogPoseTarget({
    required this.drop,
    required this.sit,
    required this.front,
    required this.rear,
    required this.nod,
    required this.eyes,
    required this.tail,
  });

  /// How far the whole dog sinks toward the floor.
  double drop;

  /// How far the front end tips up, sitting.
  double sit;

  /// Front legs swung forward (lying down).
  double front;

  /// Back legs folded forward under it.
  double rear;

  /// Head tipped down (+) or up (-).
  double nod;

  /// Eyes open (1) or shut (0).
  double eyes;

  /// How far back the tail leans from straight up.
  double tail;

  DogPoseTarget copy() => DogPoseTarget(drop: drop, sit: sit, front: front, rear: rear, nod: nod, eyes: eyes, tail: tail);

  /// Eases every part toward [target] by [k] (0..1).
  void easeToward(DogPoseTarget target, double k) {
    drop += (target.drop - drop) * k;
    sit += (target.sit - sit) * k;
    front += (target.front - front) * k;
    rear += (target.rear - rear) * k;
    nod += (target.nod - nod) * k;
    eyes += (target.eyes - eyes) * k;
    tail += (target.tail - tail) * k;
  }
}

/// What the dog is doing this frame: one of its acts, or on its way somewhere.
enum DogMotion { walk, stand, wag, sniff, sit, bark, lie, nap }

DogMotion dogMotion(DogAct act, bool moving) => moving ? DogMotion.walk : DogMotion.values.byName(act.name);

final Map<DogMotion, DogPoseTarget> dogPoses = {
  DogMotion.walk: DogPoseTarget(drop: 0, sit: 0, front: 0, rear: 0, nod: 0, eyes: 1, tail: 0.8),
  DogMotion.stand: DogPoseTarget(drop: 0, sit: 0, front: 0, rear: 0, nod: 0, eyes: 1, tail: 0.8),
  DogMotion.wag: DogPoseTarget(drop: 0, sit: 0, front: 0, rear: 0, nod: -0.15, eyes: 1, tail: 0.55),
  DogMotion.sniff: DogPoseTarget(drop: 0, sit: 0, front: 0, rear: 0, nod: 0.75, eyes: 1, tail: 0.7),
  DogMotion.sit: DogPoseTarget(drop: 0.13, sit: 0.55, front: 0, rear: 1.35, nod: 0, eyes: 1, tail: 1.5),
  DogMotion.bark: DogPoseTarget(drop: 0.13, sit: 0.55, front: 0, rear: 1.35, nod: -0.3, eyes: 1, tail: 1.1),
  DogMotion.lie: DogPoseTarget(drop: 0.19, sit: 0, front: 1.45, rear: 1.25, nod: 0.1, eyes: 1, tail: 1.45),
  DogMotion.nap: DogPoseTarget(drop: 0.19, sit: 0, front: 1.45, rear: 1.25, nod: 0.45, eyes: 0, tail: 1.6),
};

/// Where the torso hinges (at the back hips), above the floor when standing.
const double _hipY = 0.3;
const double _hipZ = -0.17;

/// The front shoulders, from the hinge.
const (double, double) _shoulder = (-0.02, 0.53);
const double _leg = 0.27;

/// How many woofs are behind it, [sinceArrivalS] seconds after it got to a worker that needs input
/// (a page opened halfway through picks up where it's at). The next is due at arrival + that many
/// times [barkEveryS].
int barksBehind(double sinceArrivalS) => sinceArrivalS <= 0.3 ? 0 : (sinceArrivalS / barkEveryS).ceil();

/// The front legs' stretch to reach the floor while sitting (1 standing), from the pose.
double frontReach(DogPoseTarget p) {
  final shoulderY = _hipY - p.drop + _shoulder.$1 * math.cos(p.sit) + _shoulder.$2 * math.sin(p.sit);
  final reach = (shoulderY / (_hipY + _shoulder.$1)).clamp(0.3, 2.0);
  final lying = math.min(1.0, p.front / dogPoses[DogMotion.lie]!.front);
  return reach + (1 - reach) * lying;
}

/// Tail wag for each motion: speed (rad/s) and swing (rad).
(double, double) tailWag(DogMotion m) => switch (m) {
  DogMotion.wag => (22, 0.75),
  DogMotion.nap => (0, 0),
  DogMotion.lie => (3, 0.2),
  DogMotion.walk => (12, 0.4),
  _ => (8, 0.35),
};

class _Bubble {
  _Bubble(this.label, this.kind, this.text, this.until);
  final WorldLabel label;
  final String kind;
  final String text;
  double until;
}

final Stopwatch _clock = Stopwatch()..start();

/// performance.now(): milliseconds on a steady clock. [Dog.sync]'s `start` is on this clock unless
/// the dog is given another.
double performanceNow() => _clock.elapsedMicroseconds / 1000;

class Dog {
  Dog(
    this._sounds,
    /// Someone already has this worker's terminal open, so there's no one to bark for.
    this._hushed,
    this._labels, {
    double Function()? now,
  }) : _now = now ?? performanceNow {
    final c = dogCoats[0];
    _coatMats = [toonUnique(hex(c.$1)), toonUnique(hex(c.$2)), toonUnique(hex(c.$3))];
    _build();
    root.visible = false;
    tagInteract(root, interactable);
  }

  final Node root = Node(name: 'dog');
  final Interactable interactable = Interactable(kind: InteractKind.dog, x: 0, z: 0, radius: 1.5);
  final DogSounds _sounds;
  final bool Function(String workerId) _hushed;
  final LabelHub _labels;
  final double Function() _now;

  final Pivot _hips = Pivot();
  final Pivot _torso = Pivot();
  final Pivot _head = Pivot();
  final Pivot _jaw = Pivot();
  final Pivot _tail = Pivot();
  final List<Pivot> _front = [];
  final List<Pivot> _rear = [];
  final List<Pivot> _ears = [];
  final List<Node> _eyes = [];
  late final List<PreprocessedMaterial> _coatMats;
  int _coat = -1;
  WorldLabel? _tag;
  String _tagName = '';
  _Bubble? _bubble;

  DogState? _state;

  /// [_now] when the current leg began.
  double _start = 0;
  double _arriveAt = 0;
  double _nextBark = 0;
  int _barks = 0;
  final DogPoseTarget _pose = dogPoses[DogMotion.lie]!.copy();
  double _phase = 0;

  /// Seconds since the last woof, for the jaw and the hop.
  double _woofT = 9;
  double _t = 0;
  bool _placed = false;
  double _heading = 0;

  /// Nothing to pet in a building without floors.
  List<Interactable> get interactables => _state != null ? [interactable] : const [];

  String get name => _state?.name ?? '';

  DogState? get state => _state;

  /// A new leg of its day from the server; [start] is when it began, on [performanceNow]'s clock.
  void sync(DogState? state, double start) {
    _state = state;
    _start = start;
    root.visible = state != null;
    if (state == null) {
      _placed = false;
      return;
    }
    if (state.coat != _coat) {
      _coat = state.coat;
      final c = dogCoats[state.coat % dogCoats.length];
      for (final (i, hexc) in [c.$1, c.$2, c.$3].indexed) {
        setToonColor(_coatMats[i], hex(hexc));
      }
    }
    if (state.name != _tagName) _setTag(state.name);
    _arriveAt = start + legSeconds(state.path, state.speed) * 1000;
    // The next woof on its schedule (a page opened halfway through picks up where it's at).
    final k = barksBehind((_now() - _arriveAt) / 1000);
    _nextBark = _arriveAt + k * barkEveryS * 1000;
    _barks = k;
    // Just petted (not a pat from before this page loaded).
    if (state.act == DogAct.wag && state.petBy != null && _now() - start < 1000) {
      final p = dogAt(state, 0);
      _sounds.yip(p.x, p.z);
      _say('wag', '❤️', 2.2);
    }
  }

  /// What it's up to, for the hint bar: "napping under Ada's desk".
  String doing(String? Function(String id) workerName, String? Function(String id) personName) {
    final s = _state;
    if (s == null) return '';
    final moving = _now() < _arriveAt;
    final w = s.workerId != null ? (workerName(s.workerId!) ?? 'a worker') : 'a worker';
    if (s.following != null) return 'following ${personName(s.following!) ?? 'someone'}';
    return switch (s.act) {
      DogAct.bark => moving ? 'running to $w, who needs input' : 'barking at $w: needs input',
      DogAct.nap => moving ? 'off for a nap' : "napping under $w's desk",
      DogAct.wag => s.petBy != null ? 'wagging at ${s.petBy}' : 'wagging',
      DogAct.lie => moving ? 'trotting to the lounge' : 'lounging',
      DogAct.sniff => moving ? 'trotting about' : 'sniffing around',
      DogAct.sit => 'sitting',
      _ => '',
    };
  }

  void update(double dt) {
    final s = _state;
    if (s == null) return;
    _t += dt;
    final now = _now();
    final at = dogAt(s, (now - _start) / 1000);
    var pos = root.position;
    if (!_placed || math.sqrt(math.pow(pos.x - at.x, 2) + math.pow(pos.z - at.z, 2)) > 3) {
      pos = vm.Vector3(at.x, 0, at.z);
      _heading = at.heading;
      _placed = true;
    } else {
      final k = 1 - math.exp(-dt * 12);
      pos = vm.Vector3(pos.x + (at.x - pos.x) * k, 0, pos.z + (at.z - pos.z) * k);
      var turn = at.heading - _heading;
      turn = math.atan2(math.sin(turn), math.cos(turn));
      _heading += turn * (1 - math.exp(-dt * 9));
    }
    root.position = pos;
    root.rotation = euler(0, _heading);
    interactable
      ..x = pos.x
      ..z = pos.z;

    // Woof, on schedule, while nobody's seeing to the worker yet.
    if (!at.moving &&
        s.act == DogAct.bark &&
        s.workerId != null &&
        now >= _nextBark &&
        now - _arriveAt < barkForS * 1000) {
      if (!_hushed(s.workerId!)) {
        _sounds.bark(at.x, at.z, _barks == 0 ? 3 : 2);
        _woofT = 0;
        _say('woof', _barks == 0 ? 'Woof! Woof! Woof!' : 'Woof! Woof!', 1.4);
      }
      _barks++;
      _nextBark = _arriveAt + _barks * barkEveryS * 1000;
    }
    _woofT += dt;
    _animate(dt, dogMotion(s.act, at.moving), at.moving ? s.speed : 0);
  }

  // ---- The model ----------------------------------------------------------------------------------

  void _build() {
    final fur = _coatMats[0], light = _coatMats[1], ear = _coatMats[2];
    final ink = toon(hex('#1d1d1d'));
    root.add(_hips.node);
    _hips.add(_torso.node);
    _torso.position = vm.Vector3(0, _hipY, _hipZ);

    _torso.add(mesh(capsule(0.15, 0.3, 6, 14), fur, 0, 0.05, 0.19)..rotation = euler(math.pi / 2, 0));
    _torso.add(mesh(sphere(0.12, 14, 10), light, 0, 0.0, 0.4)..scale = vm.Vector3(1, 1.05, 0.7));

    // Head, looking down +z: a round head, a long muzzle, floppy ears.
    _head.position = vm.Vector3(0, 0.26, 0.46);
    _torso.add(_head.node);
    _head.add(mesh(sphere(0.14, 18, 14), fur));
    _head.add(mesh(sphere(0.075, 14, 10), light, 0, -0.035, 0.12)..scale = vm.Vector3(1, 0.85, 1.35));
    _head.add(mesh(sphere(0.032, 10, 8), ink, 0, -0.005, 0.22, false));
    for (final sx in [-1.0, 1.0]) {
      final eye = mesh(sphere(0.026, 10, 8), ink, sx * 0.062, 0.035, 0.115, false);
      _eyes.add(eye);
      _head.add(eye);
      final pivot = Pivot()..position = vm.Vector3(sx * 0.105, 0.08, -0.01);
      pivot.add(mesh(capsule(0.045, 0.1, 4, 8), ear, 0, -0.08, 0)..scale = vm.Vector3(0.55, 1, 1));
      pivot.z = sx * 0.3;
      pivot.apply();
      _ears.add(pivot);
      _head.add(pivot.node);
    }
    // The jaw drops open to bark and to pant; the tongue shows when it's happy.
    _jaw.position = vm.Vector3(0, -0.075, 0.07);
    _jaw.add(mesh(sphere(0.055, 12, 8), light, 0, -0.01, 0.07)..scale = vm.Vector3(1, 0.5, 1.3));
    _jaw.add(mesh(sphere(0.03, 10, 8), toon(hex('#ff7f9a')), 0, 0.005, 0.12, false)..scale = vm.Vector3(1, 0.4, 1.4));
    _head.add(_jaw.node);
    _head.add(
      mesh(torusData(0.1, 0.022, 6, 18).build(), toon(hex('#ef476f')), 0, -0.11, -0.05, false)
        ..rotation = euler(math.pi / 2 + 0.5, 0),
    );

    // Tail, up and back from the hips.
    _tail.position = vm.Vector3(0, 0.13, -0.09);
    _tail.add(mesh(capsule(0.03, 0.18, 4, 8), fur, 0, 0.11, 0));
    _torso.add(_tail.node);

    Pivot leg(Pivot parent, double x, double y, double z, double r) {
      final pivot = Pivot()..position = vm.Vector3(x, y, z);
      pivot.add(mesh(capsule(r, _leg - 2 * r - 0.03, 4, 8), fur, 0, -(_leg - 0.03) / 2, 0));
      pivot.add(mesh(sphere(0.052, 10, 8), light, 0, -_leg + 0.03, 0.02)..scale = vm.Vector3(1, 0.7, 1.25));
      parent.add(pivot.node);
      return pivot;
    }

    for (final sx in [-1.0, 1.0]) {
      _front.add(leg(_torso, sx * 0.085, _shoulder.$1, _shoulder.$2, 0.045));
      _rear.add(leg(_hips, sx * 0.095, _hipY + _shoulder.$1, _hipZ, 0.055));
    }
  }

  void _setTag(String name) {
    _tagName = name;
    _labels.remove(_tag);
    _tag = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.0, 0),
        alignment: Alignment.center,
        child: TagPill('🐶 $name', bg: '#fffaf3', size: 30),
      ),
    );
  }

  /// A bubble over its head for a moment: "Woof!", ❤️, 💤.
  void _say(String kind, String text, double seconds) {
    final b = _bubble;
    if (b != null && b.kind == kind && b.text == text) {
      b.until = _t + seconds;
      return;
    }
    _hush();
    final label = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.28, 0),
        alignment: Alignment.center,
        child: TagPill(text, bg: kind == 'woof' ? '#ffd6e0' : '#ffffff', size: 34),
      ),
    );
    _bubble = _Bubble(label, kind, text, _t + seconds);
  }

  void _hush() {
    _labels.remove(_bubble?.label);
    _bubble = null;
  }

  void _animate(double dt, DogMotion act, double speed) {
    final target = dogPoses[act]!;
    final p = _pose..easeToward(target, 1 - math.exp(-dt * 7));
    final t = _t;

    // Gait: a trot, diagonal legs together, faster the faster it goes.
    final walking = act == DogMotion.walk;
    if (walking) _phase += dt * (5 + speed * 4.5);
    final stride = walking ? math.min(0.9, 0.35 + speed * 0.18) : 0.0;
    final swing = math.sin(_phase) * stride;
    final hop = _woofT < 0.25 ? math.sin(_woofT / 0.25 * math.pi) * 0.05 : 0.0;
    _hips.node.position = vm.Vector3(0, -p.drop + (walking ? math.sin(_phase).abs() * 0.035 : 0) + hop, 0);
    _torso.x = -p.sit + (walking ? math.sin(_phase * 2) * 0.03 : 0);

    // Front legs stay upright when it sits (and stretch to reach the floor); lying, they reach forward.
    final reach = frontReach(p);
    _front[0].x = p.sit - p.front + swing;
    _front[1].x = p.sit - p.front - swing;
    for (final f in _front) {
      f.node.scale = vm.Vector3(1, reach, 1);
    }
    _rear[0].x = -p.rear - swing;
    _rear[1].x = -p.rear + swing;

    // Head: level when sitting, down to sniff (with a busy little bob), resting on its paws asleep.
    final sniffing = act == DogMotion.sniff;
    _head.x = p.sit * 0.85 + p.nod + (sniffing ? math.sin(t * 9) * 0.12 : 0);
    _head.position = vm.Vector3(0, 0.26 - p.nod * 0.08 - (act == DogMotion.nap ? 0.05 : 0), 0.46);
    _head.y = sniffing ? math.sin(t * 2.3) * 0.35 : (act == DogMotion.lie ? math.sin(t * 0.4) * 0.4 : 0);

    // Jaw: snaps open on a woof, hangs open panting when it's happy or after a run.
    final woof = _woofT < 0.35 ? math.sin(_woofT / 0.35 * math.pi) : 0.0;
    final pant = act == DogMotion.wag || (act == DogMotion.sit && speed == 0) || walking ? 0.25 + math.sin(t * 14) * 0.08 : 0.0;
    _jaw.x = math.max(woof * 0.6, pant * (act == DogMotion.nap ? 0 : 1));

    // Ears perk up to bark, flop while trotting.
    final perk = act == DogMotion.bark ? 0.6 : 0.0;
    for (var i = 0; i < _ears.length; i++) {
      final sx = i > 0 ? 1.0 : -1.0;
      _ears[i]
        ..z = sx * (0.3 + perk * 0.5) + (walking ? math.sin(_phase + i) * 0.15 * sx : 0)
        ..x = perk * 0.5;
    }

    // Eyes shut to nap; otherwise a blink now and then.
    final blink = p.eyes > 0.5 && t % 4.3 < 0.12 ? 0.1 : p.eyes;
    for (final e in _eyes) {
      e.scale = vm.Vector3(1, math.max(0.12, blink), 1);
    }

    // Tail: a lazy sway, a happy wag, a blur when petted, still in its sleep.
    final (wagSpeed, wagSwing) = tailWag(act);
    _tail
      ..x = -p.tail
      ..z = math.sin(t * wagSpeed) * wagSwing;
    _hips.y = act == DogMotion.wag ? math.sin(t * 11) * 0.1 : 0;
    // Breathing, asleep.
    _torso.node.scale = vm.Vector3.all(act == DogMotion.nap ? 1 + math.sin(t * 2.2) * 0.02 : 1);
    for (final j in [_hips, _torso, _head, _jaw, _tail, ..._front, ..._rear, ..._ears]) {
      j.apply();
    }

    // Bubbles: 💤 while it naps, gone when it's up.
    if (act == DogMotion.nap && _bubble == null) _say('nap', '💤', 1e9);
    final b = _bubble;
    if (b != null) {
      if ((b.kind == 'nap' && act != DogMotion.nap) || _t > b.until) {
        _hush();
      } else {
        final rise = b.kind == 'wag' ? (1 - (b.until - _t) / 2.2) * 0.35 : math.sin(t * 2) * 0.03;
        b.label.offset = vm.Vector3(0, 1.28 - p.drop + rise, 0);
      }
    }
    _tag?.offset = vm.Vector3(0, 1.0 - p.drop * 0.8, 0);
  }

  /// Takes its labels down.
  void dispose() {
    _hush();
    _labels.remove(_tag);
    _tag = null;
  }
}
