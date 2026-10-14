// The office dog, as everyone on the floor sees it: a port of features/dog/world.ts. A chunky cartoon
// dog of its floor's breed that walks where the server says (see shared/dog.dart), sits, lies down, naps
// with its head on its paws, sniffs, barks at a worker that needs input and wags when it's petted.
// Forward is +z. Every breed is modelled and animated in Blender (`dog-<breed>.glb`, see models.dart, #177
// #220) with the same rig and clips, and loads the first time a floor has one; the woof, the panting,
// blinking, dressing up and the coat's colours are done here. Until a breed's model is in (or if it
// can't be loaded) the code-built pup from before stands in.

import '../audio/sound_model.dart' show DogSounds;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show Alignment, Color;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart' show HolidayTheme;

import 'character.dart' show setEmissive;
import 'collider.dart';
import 'costumes.dart';
import 'geo.dart';
import 'label_widgets.dart';
import 'labels.dart';
import 'models.dart';
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

  DogPoseTarget copy() =>
      DogPoseTarget(drop: drop, sit: sit, front: front, rear: rear, nod: nod, eyes: eyes, tail: tail);

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

/// What it's doing, as its clips have it: one of its acts, or on its way there at a trot or a gallop.
/// Meters a second from which it gallops rather than trots.
const double dogRunFrom = 1.6;

/// Meters a second the walk and run clips carry it at their own pace: played at its speed over this, its
/// paws keep pace with the floor.
const Map<String, double> dogStrideSpeed = {'walk': 0.8, 'run': 1.2};

/// How high its name tag floats over the top of it standing, and its bubbles over that. Both sink as far
/// as the top of it does in what it's doing, a little less for the tag.
const double _tagOver = 0.29;
const double _bubbleOver = 0.57;

/// How tall it's taken to be before its model is in: the pup's height.
const double _pupTop = 0.71;

/// Seconds it takes to go from one clip to the next.
const double _fade = 0.4;

/// The clip for what it's doing: on its way somewhere, a trot or (in a hurry) a gallop.
String dogClip(DogMotion act, double speed) =>
    act == DogMotion.walk ? (speed >= dogRunFrom ? 'run' : 'walk') : act.name;

/// How far the top of it sinks from standing in each clip, as a share of how tall it stands. Upstream
/// poses every fifth vertex of the breed in each clip to measure it; this port has no CPU skinning, so
/// these are the pup's, measured by eye, for every breed.
const Map<String, double> _dogDropShare = {'sniff': 0.12, 'lie': 0.3, 'nap': 0.38};

/// What each part of the model is painted with, by its material's name in `dog-<breed>.glb`: a coat colour
/// (0 body, 1 belly and muzzle, 2 ears, recoloured on sync) or a fixed one. Anything else wears the body's.
const Map<String, Object> dogPaint = {
  'Fur': 0,
  'Light': 1,
  'Ear': 2,
  'Ink': '#1d1d1d',
  'Shine': '#ffffff',
  'Nose': '#1d1d1d',
  'Tongue': '#ff7f9a',
  'Collar': '#ef476f',
  'Tag': '#ffd166',
};

/// The model for [breed].
ModelName dogModel(DogBreed breed) => ModelName.values.firstWhere((m) => m.file == 'dog-${breed.wire}');

/// The coat colours for coat [n]: body, belly and muzzle, ears, each with how much it glows (the white
/// one a little, so it stays white at dusk).
List<({Color color, Color emissive})> dogCoatPaint(int n) {
  final coat = n % dogCoats.length;
  final glow = coat < dogCoatGlow.length ? dogCoatGlow[coat] : 0.0;
  final c = dogCoats[coat];
  return [
    for (final h in [c.$1, c.$2, c.$3])
      (
        color: hex(h),
        emissive: Color.from(alpha: 1, red: hex(h).r * glow, green: hex(h).g * glow, blue: hex(h).b * glow),
      ),
  ];
}

/// costumes.dart puts every piece where it goes on the pup, from its head. Rudolph's nose and the scarf
/// go on the breed's own nose and collar sockets instead, so they're moved back by where those are on
/// the pup (from its socket_head, and the pup collar's half width, which the scarf is sized to).
final vm.Vector3 _pupNose = vm.Vector3(0, 0, 0.207);
final vm.Vector3 _pupCollar = vm.Vector3(0, -0.1138, -0.0864);
const double _pupCollarWidth = 0.119;

/// The loaded model's moving parts.
class _Rig {
  _Rig({
    required this.breed,
    required this.model,
    required this.clips,
    required this.jaw,
    required this.jawRest,
    required this.eyes,
    required this.head,
    required this.back,
    required this.noseTip,
    required this.neck,
    required this.collar,
    required this.nose,
    required this.top,
  });

  final DogBreed breed;
  final Node model;

  /// Each clip and how much of the pose is its: they fade in and out over [_fade], adding up to 1.
  final Map<String, ({AnimationClip clip, double w})> clips;
  final Node jaw;
  final vm.Quaternion jawRest;
  final List<({Node bone, vm.Vector3 rest})> eyes;

  /// Where costumes go: on its head, on its back, on its nose and round its collar.
  final Node head, back, noseTip, neck;

  /// How big its collar is next to the pup's, for the scarf.
  final double collar;

  /// Its own nose, hidden under Rudolph's.
  final List<MeshPrimitive> nose;

  /// How tall it stands.
  final double top;

  double drop(String clip) => (_dogDropShare[clip] ?? 0) * top;
}

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
    Future<Model> Function(DogBreed breed)? load,
  }) : _now = now ?? performanceNow,
       _load = load ?? ((b) => loadModel(dogModel(b))) {
    final c = dogCoats[0];
    _coatMats = [toonUnique(hex(c.$1)), toonUnique(hex(c.$2)), toonUnique(hex(c.$3))];
    root.add(_body);
    _body.add(_code);
    _build();
    root.visible = false;
    tagInteract(root, interactable);
  }

  final Future<Model> Function(DogBreed breed) _load;

  /// Holds the model (or the code-built pup), and lifts it off the floor for the little hop with a woof.
  final Node _body = Node(name: 'dog-body');

  /// The code-built pup, shown until a breed's model is in.
  final Node _code = Node(name: 'dog-code');

  /// The model, once it's loaded.
  _Rig? _rig;

  /// The breed it last synced as, whose model it has on or is loading.
  DogBreed? _wants;
  Future<bool> _loading = Future.value(false);

  /// True once the model of the breed it last synced as is on, false if it couldn't be loaded (or
  /// another breed was asked for meanwhile). Never fails.
  Future<bool> get ready => _loading;

  /// The breed whose model it has on, if any.
  DogBreed? get breed => _rig?.breed;

  /// How far it has sunk toward the floor in its model's clip (see [_Rig.drop]).
  double _sink = 0;

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

  final Completer<void> _firstIn = Completer();

  /// Settles the first time there's a dog to see: the model of the breed it was synced as is on, or
  /// couldn't be loaded, or the first sync had no dog at all. The loading screen waits on it. Never fails.
  Future<void> get firstReady => _firstIn.future;

  void _firstDone() {
    if (!_firstIn.isCompleted) _firstIn.complete();
  }

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
  late final Node _nose;

  /// Dressed up for a holiday (see [setCostume]): what it's wearing, its bat wings, and Rudolph's nose.
  HolidayTheme? _costume;
  final List<Node> _outfit = [];
  List<Pivot> _wings = const [];
  PreprocessedMaterial? _rudolph;

  HolidayTheme? get costume => _costume;

  /// Dresses it up for a holiday: bat wings and a little witch's hat for Halloween, reindeer antlers,
  /// a glowing red nose and a scarf for Christmas. Null takes it all off.
  void setCostume(HolidayTheme? theme) {
    if (theme == _costume) return;
    _costume = theme;
    _dress();
  }

  /// Puts on what [setCostume] last asked for, taking off what it had on: on the model's sockets once
  /// it's in, on the code-built pup's head and back until then.
  void _dress() {
    final theme = _costume;
    for (final o in _outfit) {
      o.detach();
    }
    _outfit.clear();
    _wings = const [];
    _rudolph = null;
    void wear(Node parent, Node o) {
      parent.add(o);
      _outfit.add(o);
    }

    final rig = _rig;
    if (theme == HolidayTheme.halloween) {
      final bat = dogBatWings();
      wear(rig?.back ?? _torso.node, bat.group);
      _wings = bat.wings;
      wear(rig?.head ?? _head.node, dogWitchHat());
    } else if (theme == HolidayTheme.christmas) {
      wear(rig?.head ?? _head.node, dogAntlers());
      final scarf = dogScarf();
      final red = dogRedNose();
      if (rig != null) {
        // Round its own collar, as big as that is; Rudolph's on its own nose.
        scarf
          ..scale = vm.Vector3.all(rig.collar)
          ..position = _pupCollar * -rig.collar;
        wear(rig.neck, scarf);
        red.nose.position = red.nose.position - _pupNose;
        wear(rig.noseTip, red.nose);
      } else {
        wear(_head.node, scarf);
        wear(_head.node, red.nose);
      }
      _rudolph = red.glow;
    }
    _nose.visible = theme != HolidayTheme.christmas;
    for (final n in rig?.nose ?? const <MeshPrimitive>[]) {
      n.visible = theme != HolidayTheme.christmas;
    }
  }

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
      _firstDone();
      return;
    }
    // Another floor's dog (someone took the elevator): its breed's model, once that's in.
    if (state.breed != _wants) _wear(state.breed);
    if (state.coat != _coat) {
      _coat = state.coat;
      for (final (i, c) in dogCoatPaint(state.coat).indexed) {
        setToonColor(_coatMats[i], c.color, emissive: c.emissive);
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

  /// Loads a breed's model and puts it on. The one it has on stays until then, so a floor's dog never
  /// goes missing while another breed loads; one that finishes loading after yet another breed was
  /// asked for is dropped.
  void _wear(DogBreed breed) {
    _wants = breed;
    _loading = _load(breed)
        .then((m) {
          if (_wants != breed) return false;
          _attach(m, breed);
          return true;
        })
        // A file that didn't load, or isn't the model the code knows (a part missing): the code-built pup.
        .catchError((Object e) {
          debugPrint("The office dog's model (${breed.wire}) didn't load: $e");
          return false;
        });
    // On or not coming, unless another breed was asked for meanwhile: then it's that one's turn.
    _loading.then((_) {
      if (_wants == breed) _firstDone();
    });
  }

  /// Puts a loaded model on in place of the one it had: paints it, finds the bones the code moves and
  /// the costume sockets, sets its clips up, and dresses it.
  void _attach(Model m, DogBreed breed) {
    final model = m.scene;
    final nose = <MeshPrimitive>[];
    var collar = _pupCollarWidth;
    var top = 0.0;
    for (final n in walk(model)) {
      final mesh = n.mesh;
      if (mesh == null) continue;
      for (final p in mesh.primitives) {
        final name = p.material.name;
        // Its bind pose, standing: how tall it is, and how big its collar.
        if (p.geometry.isReadable) {
          final pos = p.geometry.extractMeshData().positions;
          var minX = double.infinity, maxX = double.negativeInfinity;
          for (var i = 0; i + 2 < pos.length; i += 3) {
            top = math.max(top, pos[i + 1]);
            minX = math.min(minX, pos[i]);
            maxX = math.max(maxX, pos[i]);
          }
          if (name == 'Collar' && maxX > minX) collar = (maxX - minX) / 2;
        }
        final paint = dogPaint[name] ?? 0;
        p.material = paint is int ? _coatMats[paint] : toon(hex(paint as String));
        if (name == 'Nose') nose.add(p);
      }
      // Culled by bounds worked out standing, it would vanish lying down at the edge of the screen.
      n.frustumCulled = false;
    }
    Node part(String name) => model.getChildByName(name) ?? (throw StateError('dog-${breed.wire}.glb has no $name'));
    final jaw = part('jaw');
    // The code moves the jaw and the eyes itself; the clips would hold them still at rest.
    const coded = {'jaw', 'eye_L', 'eye_R'};
    final clips = <String, ({AnimationClip clip, double w})>{};
    for (final a in m.clips) {
      final clip =
          model.createAnimationClip(
              Animation(
                name: a.name,
                channels: a.channels.where((c) => !coded.contains(c.bindTarget.nodeName)).toList(),
              ),
            )
            ..loop = true
            ..weight = 0;
      clips[a.name] = (clip: clip, w: 0);
    }
    final rig = _Rig(
      breed: breed,
      model: model,
      clips: clips,
      jaw: jaw,
      jawRest: jaw.rotation,
      eyes: [
        for (final e in ['eye_L', 'eye_R']) (bone: part(e), rest: part(e).scale),
      ],
      head: part('socket_head'),
      back: part('socket_back'),
      noseTip: part('socket_nose'),
      neck: part('socket_neck'),
      collar: collar / _pupCollarWidth,
      nose: nose,
      top: top > 0 ? top : _pupTop,
    );
    _rig?.model.detach();
    _body.add(model);
    _code.visible = false;
    _rig = rig;
    _dress();
  }

  void _build() {
    final fur = _coatMats[0], light = _coatMats[1], ear = _coatMats[2];
    final ink = toon(hex('#1d1d1d'));
    _code.add(_hips.node);
    _hips.add(_torso.node);
    _torso.position = vm.Vector3(0, _hipY, _hipZ);

    _torso.add(mesh(capsule(0.15, 0.3, 6, 14), fur, 0, 0.05, 0.19)..rotation = euler(math.pi / 2, 0));
    _torso.add(mesh(sphere(0.12, 14, 10), light, 0, 0.0, 0.4)..scale = vm.Vector3(1, 1.05, 0.7));

    // Head, looking down +z: a round head, a long muzzle, floppy ears.
    _head.position = vm.Vector3(0, 0.26, 0.46);
    _torso.add(_head.node);
    _head.add(mesh(sphere(0.14, 18, 14), fur));
    _head.add(mesh(sphere(0.075, 14, 10), light, 0, -0.035, 0.12)..scale = vm.Vector3(1, 0.85, 1.35));
    _nose = mesh(sphere(0.032, 10, 8), ink, 0, -0.005, 0.22, false);
    _head.add(_nose);
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
      // Under the chest, not out in front of it (#148).
      _front.add(leg(_torso, sx * 0.075, _shoulder.$1, _shoulder.$2 - 0.15, 0.045));
      _rear.add(leg(_hips, sx * 0.095, _hipY + _shoulder.$1, _hipZ, 0.055));
    }
  }

  void _setTag(String name) {
    _tagName = name;
    _labels.remove(_tag);
    _tag = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, (_rig?.top ?? _pupTop) + _tagOver, 0),
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
        offset: vm.Vector3(0, (_rig?.top ?? _pupTop) + _bubbleOver, 0),
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
    final rig = _rig;
    if (rig != null) {
      _animateModel(rig, dt, act, speed);
    } else {
      _animateCode(p, dt, act, speed);
    }
    final drop = rig != null ? _sink : p.drop;
    final top = rig?.top ?? _pupTop;

    // Bat wings flap (fast when it runs or is happy, folded while it naps); Rudolph's nose glows.
    final walking = act == DogMotion.walk;
    final flap = act == DogMotion.nap ? 0.0 : (walking || act == DogMotion.wag || act == DogMotion.bark ? 1.0 : 0.35);
    for (final (i, w) in _wings.indexed) {
      final sx = i > 0 ? 1 : -1;
      w
        ..z = sx * (0.75 + (act == DogMotion.nap ? -0.6 : math.sin(t * (6 + 10 * flap)) * 0.45 * flap))
        ..y = sx * 0.25
        ..apply();
    }
    final nose = _rudolph;
    if (nose != null) setEmissive(nose, hex('#ff1a1a'), 0.7 + math.sin(t * 3) * 0.3);

    // Bubbles: 💤 while it naps, gone when it's up.
    if (act == DogMotion.nap && _bubble == null) _say('nap', '💤', 1e9);
    final b = _bubble;
    if (b != null) {
      if ((b.kind == 'nap' && act != DogMotion.nap) || _t > b.until) {
        _hush();
      } else {
        final rise = b.kind == 'wag' ? (1 - (b.until - _t) / 2.2) * 0.35 : math.sin(t * 2) * 0.03;
        b.label.offset = vm.Vector3(0, top + _bubbleOver - drop + rise, 0);
      }
    }
    _tag?.offset = vm.Vector3(0, top + _tagOver - drop * 0.8, 0);
  }

  /// The model: fades toward the clip for what it's doing, then the jaw and the eyes, which the clips
  /// leave to the code.
  void _animateModel(_Rig rig, double dt, DogMotion act, double speed) {
    final t = _t;
    final k = 1 - math.exp(-dt * 7);
    final clip = dogClip(act, speed);
    _sink += (rig.drop(clip) - _sink) * k;
    _eyesOpen += ((act == DogMotion.nap ? 0 : 1) - _eyesOpen) * k;
    // A little hop with each woof.
    _body.position = vm.Vector3(0, _woofT < 0.25 ? math.sin(_woofT / 0.25 * math.pi) * 0.05 : 0, 0);

    final want = rig.clips.containsKey(clip) ? clip : 'stand';
    final step = dt / _fade;
    var total = 0.0;
    for (final e in rig.clips.entries.toList()) {
      final c = e.value;
      final w = (e.key == want ? c.w + step : c.w - step).clamp(0.0, 1.0);
      if (w > 0 && c.w == 0) c.clip.replay();
      if (w == 0 && c.w > 0) c.clip.stop();
      rig.clips[e.key] = (clip: c.clip, w: w);
      total += w;
    }
    // Weights short of 1 would blend in the model's rest pose, so a fade cut short by another shares out 1.
    for (final c in rig.clips.values) {
      c.clip.weight = total > 0 ? c.w / total : 0;
    }
    // Its legs keep up with how fast it's going.
    final gait = rig.clips[clip];
    final stride = dogStrideSpeed[clip];
    if (gait != null && stride != null) gait.clip.playbackTimeScale = speed / stride;

    // Jaw: snaps open on a woof, hangs open panting when it's happy or after a run, shut asleep.
    final moving = act == DogMotion.walk;
    final woof = _woofT < 0.35 ? math.sin(_woofT / 0.35 * math.pi) : 0.0;
    final pant = act == DogMotion.wag || act == DogMotion.sit || moving ? 0.25 + math.sin(t * 14) * 0.08 : 0.0;
    rig.jaw.rotation = rig.jawRest * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.max(woof * 0.6, pant));
    // Eyes shut to nap; otherwise a blink now and then.
    final blink = _eyesOpen > 0.5 && t % 4.3 < 0.12 ? 0.1 : _eyesOpen;
    for (final e in rig.eyes) {
      e.bone.scale = vm.Vector3(e.rest.x, e.rest.y * math.max(0.12, blink), e.rest.z);
    }
  }

  double _eyesOpen = 1;

  /// The code-built pup, posed by hand.
  void _animateCode(DogPoseTarget p, double dt, DogMotion act, double speed) {
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
    final pant = act == DogMotion.wag || (act == DogMotion.sit && speed == 0) || walking
        ? 0.25 + math.sin(t * 14) * 0.08
        : 0.0;
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
  }

  /// Takes its labels down.
  void dispose() {
    _hush();
    _labels.remove(_tag);
    _tag = null;
  }
}
