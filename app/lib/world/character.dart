// The people in the office: a port of world/character.ts. [Person] is the chibi human everyone
// plays (walk cycle, sitting, typing, reaching, a mug, a smoke, a talking mouth), [Worker] the little
// AI agent at a desk with its status bulb and task card, and the props they hold.
//
// three.js groups pivot at their origin, so every joint here is a node of its own with the limb
// hung off it, as in the TS; joints the animation turns keep three-style Euler angles ([Pivot]).

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/widgets.dart' show Alignment;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show Drink, DrinkId;
import 'package:office_shared/status.dart';
import 'drinks.dart' show drinkGlass;
import 'geo.dart';
import 'label_widgets.dart';
import 'labels.dart';
import 'player.dart' show kHips;
import 'toon.dart';

enum Pose { stand, walk, sit, type }

/// Voice loudness (RMS) above which someone counts as speaking.
const double kSpeaking = 0.04;

/// How long reaching out to use something takes, in seconds.
const double kReachTime = 0.42;

/// 0 → 1 → 0 over a reach (p = 0..1): a quick jab out, a beat at full stretch, an easy return.
double reachCurve(double p) {
  if (p <= 0 || p >= 1) return 0;
  if (p < 0.28) return 1 - math.pow(1 - p / 0.28, 3).toDouble();
  if (p < 0.5) return 1;
  final u = (p - 0.5) / 0.5;
  return 1 - u * u * (3 - 2 * u);
}

/// On a smoke break, one drag every this many seconds.
const double kSmokeCycle = 6;

/// When, in a smoke cycle, the smoke is blown out.
const double kExhaleAt = 2.5;

/// How far the cigarette hand is up at the mouth (0..1), [c] seconds into a smoke cycle.
double dragCurve(double c) {
  double ease(double x) => x * x * (3 - 2 * x);
  if (c < 0.7) return ease(c / 0.7);
  if (c < 1.7) return 1;
  if (c < 2.3) return 1 - ease((c - 1.7) / 0.6);
  return 0;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Sets a toon material's glow: three's `emissive` colour times `emissiveIntensity`.
void setEmissive(Material m, Color c, [double intensity = 1]) {
  if (m is! PreprocessedMaterial) return;
  final l = linear(c);
  m.parameters.setVec4('emissive', vm.Vector4(l.x * intensity, l.y * intensity, l.z * intensity, 1));
}

/// A full mug of coffee standing on y = 0, with its handle on the -x side.
Node coffeeMug([double scale = 1]) {
  final mug = Node(name: 'mug');
  final r = 0.05 * scale;
  final height = 0.1 * scale;
  final china = toon(hex('#fffaf3'));
  mug.add(mesh(cylinder(r, r * 0.88, height, 16), china, 0, height / 2, 0, false));
  mug.add(mesh(cylinder(r * 0.8, r * 0.8, height * 0.04, 16), toon(hex('#6f4518')), 0, height, 0, false));
  mug.add(mesh(torus(height * 0.28, r * 0.2, 6, 12), china, -r, height / 2, 0, false));
  return mug;
}

/// A cigarette, lit end toward +z, and the material of its glowing tip.
({Node group, PreprocessedMaterial ember}) cigarette() {
  final group = Node(name: 'cigarette');
  group.add(mesh(cylinderData(0.016, 0.016, 0.12, 8).rotateX(math.pi / 2).build(), toon(hex('#fffaf3')), 0, 0, 0.01, false));
  group.add(mesh(cylinderData(0.017, 0.017, 0.045, 8).rotateX(math.pi / 2).build(), toon(hex('#e9a03b')), 0, 0, -0.07, false));
  final ember = toonUnique(hex('#ff6a2b'));
  setEmissive(ember, hex('#ff3b00'), 0.3);
  group.add(mesh(cylinderData(0.017, 0.017, 0.02, 8).rotateX(math.pi / 2).build(), ember, 0, 0, 0.078, false));
  return (group: group, ember: ember);
}

/// An open cardboard box with someone's desk things in it: a plant, a photo, a mug, a rubber duck and
/// some papers. It stands on y = 0 with its front toward +z.
Node boxOfStuff() {
  final g = Node(name: 'box-of-stuff');
  const W = 0.52, H = 0.26, D = 0.3, T = 0.02;
  final card = toon(hex('#c8955c'));
  g.add(mesh(box(W, T, D), card, 0, T / 2, 0));
  for (final s in [-1.0, 1.0]) {
    g.add(mesh(box(W, H, T), card, 0, H / 2, s * (D - T) / 2));
    g.add(mesh(box(T, H, D - 2 * T), card, s * (W - T) / 2, H / 2, 0));
  }
  // Full to the brim.
  g.add(mesh(box(W - 2 * T, 0.01, D - 2 * T), toon(hex('#8b6a47')), 0, H * 0.7, 0, false));
  // Flaps: the front one hangs down over the front, the side ones stick up and out.
  final flapMat = toon(hex('#b5824c'));
  final front = Node()
    ..position = vm.Vector3(0, H, D / 2)
    ..rotation = euler(1.2, 0);
  front.add(mesh(box(W, T, 0.14), flapMat, 0, 0, 0.07));
  g.add(front);
  for (final s in [-1.0, 1.0]) {
    final flap = Node()
      ..position = vm.Vector3(s * W / 2, H, 0)
      ..rotation = euler(0, 0, s * 0.95);
    flap.add(mesh(box(0.13, T, D), flapMat, s * 0.065, 0, 0));
    g.add(flap);
  }

  // A potted plant in the back corner.
  g.add(mesh(cylinder(0.06, 0.045, 0.11, 10), toon(hex('#e76f51')), -0.15, H - 0.03, -0.04, false));
  for (final (x, y, z, r, c) in const [
    (-0.15, 0.1, -0.04, 0.07, '#5fb760'),
    (-0.2, 0.07, 0.0, 0.05, '#3f8f45'),
    (-0.11, 0.15, -0.07, 0.05, '#6fcf6a'),
  ]) {
    g.add(mesh(sphere(r, 10, 8), toon(hex(c)), x, H + y, z, false));
  }
  // Papers sticking up at the back.
  for (final (x, rz) in const [(-0.01, 0.16), (0.05, -0.1)]) {
    final paper = mesh(box(0.17, 0.22, 0.004), toon(hex('#fffaf3')), x, H - 0.01, -0.1, false);
    paper.rotation = euler(-0.1, 0, rz);
    g.add(paper);
  }
  // A framed photo, leaning back.
  final photo = Node();
  photo.add(mesh(box(0.16, 0.13, 0.02), toon(hex('#2b2d42')), 0, 0, 0, false));
  photo.add(mesh(box(0.12, 0.09, 0.005), toon(hex('#8ecae6')), 0, 0, 0.011, false));
  photo.add(mesh(sphere(0.018, 8, 6), toon(hex('#ffd166')), 0.03, 0.02, 0.014, false));
  photo
    ..position = vm.Vector3(0.1, H + 0.04, -0.05)
    ..rotation = euler(-0.3, 0, -0.12);
  g.add(photo);
  // A mug and the rubber duck, up front.
  final mug = coffeeMug(0.9)..position = vm.Vector3(0.0, H - 0.07, 0.07);
  g.add(mug);
  final duck = Node();
  final duckBody = mesh(sphere(0.05, 10, 8), toon(hex('#ffd166')), 0, 0, 0, false)..scale = vm.Vector3(1, 0.8, 1);
  duck.add(duckBody);
  duck.add(mesh(sphere(0.032, 10, 8), toon(hex('#ffd166')), 0, 0.055, 0.02, false));
  duck.add(mesh(coneData(0.014, 0.03, 6).rotateX(math.pi / 2).build(), toon(hex('#f4a261')), 0, 0.05, 0.06, false));
  duck
    ..position = vm.Vector3(0.16, H + 0.01, 0.06)
    ..rotation = euler(0, -0.4);
  g.add(duck);
  return g;
}

/// What a smoker gives off: a wisp from the lit end, or the smoke blown out after a drag.
enum Puff { wisp, exhale }

final math.Random _rng = math.Random();

/// A chibi cartoon person — used for every human in the office. Forward is +z.
class Person {
  Person(this._name, String color, Look look, this._labels) : _look = look {
    shirt = toonUnique(hex(color));
    _skin = toonUnique(hex(skinTones[look.skin]));
    _hairMat = toonUnique(hex(hairColors[look.hair]))..doubleSided = true;
    final skin = _skin;
    final pants = toon(hex('#3d405b'));
    final ink = toon(hex('#1d1d1d'));

    root.add(_body.node);
    // Torso
    _body.add(mesh(capsule(0.26, 0.28, 6, 12), shirt, 0, 0.72, 0));
    // Head
    _head.position = vm.Vector3(0, 1.32, 0);
    _head.add(mesh(sphere(0.34, 20, 16), skin));
    _head.add(_hair);
    _buildHair();
    for (final sx in [-1.0, 1.0]) {
      _head.add(mesh(sphere(0.055, 10, 8), ink, sx * 0.12, 0.02, 0.3, false));
      _head.add(mesh(sphere(0.05, 10, 8), toon(hex('#ff9f9f')), sx * 0.2, -0.08, 0.27, false));
    }
    _smile = mesh(torus(0.06, 0.015, 6, 12, math.pi), ink, 0, -0.08, 0.32, false)..rotation = euler(0, 0, math.pi);
    _head.add(_smile);
    // Talking mouth: a flattened ball pressed into the face, scaled open and shut with the voice.
    _mouth = mesh(sphere(1, 16, 12), toon(hex('#7a2635')), 0, -0.1, 0.295, false);
    final tongue = mesh(sphere(1, 12, 10), toon(hex('#ff8fa3')), 0, -0.5, 0, false)..scale = vm.Vector3(0.6, 0.45, 1.15);
    _mouth.add(tongue);
    _mouth.visible = false;
    _head.add(_mouth);
    _body.add(_head.node);

    Pivot limb(double len, double r, Material mat, double x, double y) {
      final pivot = Pivot()..position = vm.Vector3(x, y, 0);
      pivot.add(mesh(capsule(r, len, 4, 8), mat, 0, -len / 2 - r / 2, 0));
      _body.add(pivot.node);
      return pivot;
    }

    _legL = limb(0.22, 0.1, pants, -0.12, kHips);
    _legR = limb(0.22, 0.1, pants, 0.12, kHips);
    _armL = limb(0.24, 0.08, shirt, -0.33, 0.9);
    _armR = limb(0.24, 0.08, shirt, 0.33, 0.9);
    for (final arm in [_armL, _armR]) {
      arm.add(mesh(sphere(0.085, 12, 10), skin, 0, -0.38, 0));
    }
    // Forward is +z, so the character's left arm is the one on +x. The handle faces the hand.
    final cup = _cup = coffeeMug(1.4)
      ..position = vm.Vector3(0.02, -0.08, 0.1)
      ..rotation = euler(0, -math.pi / 2);
    _mug.add(cup);
    _mug.position = vm.Vector3(0, -0.38, 0);
    _mug.visible = false;
    _armR.add(_mug);
    // For smoke breaks: a cigarette sticking out of the right fist (the arm on -x, see reach), lit end
    // pointing down at your side and up and away when it's at your mouth.
    final cig = cigarette();
    _cig = cig.group;
    _ember = cig.ember;
    final along = vm.Vector3(0, -0.9, -0.44).normalized();
    _cig.rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 0, 1), along);
    _cig.position = vm.Vector3(0, -0.38, 0) + along * 0.07;
    _cig.visible = false;
    _armL.add(_cig);

    // Little mic icon that pops up while speaking
    _mic = mesh(sphere(0.09, 10, 8), toon(hex('#7cf29a'), emissive: hex('#2a9d4b')), 0, 2.25, 0, false);
    _mic.visible = false;
    root.add(_mic);

    for (final p in [_body, _head, _legL, _legR, _armL, _armR]) {
      p.apply();
    }
    setLabel(_name, false);
  }

  final Node root = Node(name: 'person');
  final LabelHub _labels;
  final Pivot _body = Pivot();
  final Pivot _head = Pivot();
  final Node _hair = Node(name: 'hair');

  /// Held in the left hand, kept upright however the arm swings: a mug of coffee or a drink.
  final Node _mug = Node();
  late final Node _cup;
  bool _wantsMug = false;

  /// A drink from the rooftop bar, in the mug's place.
  ({DrinkId id, Node node})? _glass;
  late final Pivot _legL, _legR, _armL, _armR;
  late final PreprocessedMaterial shirt;
  late final PreprocessedMaterial _skin;
  late final PreprocessedMaterial _hairMat;
  late final Node _mic, _smile, _mouth, _cig;
  late final PreprocessedMaterial _ember;
  double _emberGlow = 0.3;
  Look _look;
  String _name;
  WorldLabel? _label;
  bool _speaking = false;
  double _voiceLevel = 0;

  /// 0 = lips together, 1 = wide open. Follows the voice's loudness.
  double _mouthOpen = 0;

  /// Keep the talking mouth up through the short gaps between words.
  double _talkUntil = 0;
  double _walkPhase = 0;
  double _reachT = -1;
  Pose pose = Pose.stand;

  /// Seconds into a smoke break, or -1 when not on one.
  double _smokeT = -1;
  double _wispIn = 0;

  /// Where smoke comes off: the lit end (a wisp) or the mouth, blowing it out along `dir`. Both are
  /// in the space of [root]'s parent (the office), not the engine's (mirrored) world space.
  void Function(Puff kind, vm.Vector3 at, vm.Vector3 dir)? onSmoke;

  /// Hips this high above the feet while sitting (on the seat), or null on their feet.
  double? _hips;

  /// The last seat's, so getting up eases back down from it.
  double _seatHips = kHips;

  /// 0 standing … 1 sitting, eased between so sitting down and getting up take a moment.
  double _sitK = 0;

  String get name => _name;

  void setColor(String color) => setToonColor(shirt, hex(color));

  String get skinColor => skinTones[_look.skin];

  Look get look => _look;

  void setLook(Look look) {
    final restyle = look.style != _look.style;
    _look = look;
    setToonColor(_skin, hex(skinTones[look.skin]));
    setToonColor(_hairMat, hex(hairColors[look.hair]));
    if (restyle) _buildHair();
  }

  /// Hair is a set of shapes on the head (whose center is 0,0,0; the face looks down +z).
  void _buildHair() {
    _hair.removeAll();
    final m = _hairMat;
    Node add(Geometry geo, double x, double y, double z, [double rx = 0, double rz = 0]) {
      final part = mesh(geo, m, x, y, z)..rotation = euler(rx, 0, rz);
      _hair.add(part);
      return part;
    }

    void cap() => add(sphere(0.355, 20, 12, 0, math.pi * 2, 0, math.pi * 0.45), 0, 0.02, -0.02, -0.25);
    switch (hairStyles[_look.style]) {
      case 'Short':
        cap();
      case 'Long':
        cap();
        // A curtain down the back, open at the front so the face shows.
        // Around the head from ear to ear the back way, leaving the face open (phi = π/2 is the face).
        add(sphere(0.37, 20, 14, math.pi * 0.93, math.pi * 1.14, math.pi * 0.3, math.pi * 0.5), 0, -0.06, -0.03).scale =
            vm.Vector3(1.02, 1.35, 1);
      case 'Bun':
        cap();
        add(sphere(0.14, 14, 12), 0, 0.3, -0.2);
      case 'Spiky':
        cap();
        // Two rows of spikes fanned out over the crown.
        for (final (row, n, z, tilt) in const [(0, 5, 0.08, 0.35), (1, 4, -0.12, -0.3)]) {
          for (var i = 0; i < n; i++) {
            final a = -0.85 + (i / (n - 1)) * 1.7;
            add(cone(0.1, 0.3, 8), math.sin(a) * 0.24, 0.33 - a.abs() * 0.08 - row * 0.02, z, tilt, -a * 0.9);
          }
        }
      case 'Curly':
        // Little puffs spread over the top and back of the head, leaving the face clear.
        const n = 70;
        final puff = sphere(0.1, 8, 6);
        for (var i = 0; i < n; i++) {
          final y = 1 - (i / (n - 1)) * 2;
          final r = math.sqrt(1 - y * y);
          final th = i * 2.39996;
          final px = math.cos(th) * r;
          final pz = math.sin(th) * r;
          if (y < -0.15 || (pz > 0.35 && y < 0.55)) continue;
          add(puff, px * 0.36, y * 0.36 + 0.04, pz * 0.36 - 0.02);
        }
      case 'Ponytail':
        cap();
        add(sphere(0.075, 10, 8), 0, 0.12, -0.34);
        add(capsule(0.085, 0.3, 6, 10), 0, -0.1, -0.42, 0.35).scale = vm.Vector3(1, 1, 0.8);
      case 'Bald':
        break;
    }
  }

  /// The name tag over their head; [muted] adds 🔇 or 🎙️ (null: neither).
  void setLabel(String name, bool? muted) {
    _name = name;
    _labels.remove(_label);
    final suffix = muted == null ? '' : (muted ? ' 🔇' : ' 🎙️');
    _label = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 2.0, 0),
        alignment: Alignment.center,
        child: TagPill('$name$suffix', bg: '#fffaf3', size: 40),
      ),
    );
  }

  /// How loud this person is talking right now (0 when silent); drives the mic badge and the mouth.
  void setVoiceLevel(double level) {
    _voiceLevel = level;
    _speaking = level > kSpeaking;
    _mic.visible = _speaking;
  }

  void showLabel(bool v) => _label?.visible = v;

  /// Reach out with the right hand, as if pressing or grabbing something in front of you.
  void reach() => _reachT = 0;

  /// A mug of coffee in the left hand, or not.
  void holdMug(bool on) {
    _wantsMug = on;
    _cup.visible = _glass == null;
    _mug.visible = on || _glass != null;
  }

  /// A drink from the rooftop bar in the left hand (in place of a mug), or none (null).
  void holdDrink(Drink? d) {
    if (d?.id == _glass?.id) return;
    // The glass's shapes are shared (cached by size), so putting it down is letting go of the node.
    _glass?.node.detach();
    _glass = null;
    if (d != null) {
      final node = drinkGlass(d, 1.4)..position = vm.Vector3(0.02, -0.08, 0.1);
      _mug.add(node);
      _glass = (id: d.id, node: node);
    }
    holdMug(_wantsMug);
  }

  bool get smoking => _smokeT >= 0;

  /// Lights a cigarette (or puts it out): it's in their right hand, and they take a drag every few seconds.
  void setSmoking(bool on) {
    if (on == smoking) return;
    _smokeT = on ? 0 : -1;
    _cig.visible = on;
  }

  /// A drag: up to the mouth, hold while the tip glows, back down, then blow the smoke out.
  void _smokeStep(double dt, bool walking, bool airborne) {
    final prev = _smokeT % kSmokeCycle;
    _smokeT += dt;
    final c = _smokeT % kSmokeCycle;
    final k = walking || airborne ? 0.0 : dragCurve(c);
    if (!airborne) {
      _armL.x = _lerp(-0.9, -2.6, k);
      _armL.z = _lerp(0.15, 0.6, k);
    }
    final glow = k > 0.9 ? 1.4 : 0.3;
    _emberGlow += (glow - _emberGlow) * math.min(1, dt * 6);
    setEmissive(_ember, hex('#ff3b00'), _emberGlow);
    final cb = onSmoke;
    if (cb == null) return;
    _wispIn -= dt;
    final exhale = prev < kExhaleAt && c >= kExhaleAt;
    if (_wispIn > 0 && !exhale) return;
    // The joints' latest angles, so the world positions below are this frame's.
    _armL.apply();
    _head.apply();
    if (_wispIn <= 0) {
      _wispIn = 0.16 + _rng.nextDouble() * 0.12;
      cb(Puff.wisp, pointIn(root.parent, _cig, vm.Vector3(0, 0, 0.09)), vm.Vector3(0, 1, 0));
    }
    if (exhale) {
      // (Through a matrix: vector_math's Quaternion.rotated turns the other way from the engine.)
      final dir = vm.Matrix4.compose(vm.Vector3.zero(), root.rotation, vm.Vector3.all(1)).transform3(vm.Vector3(0, 0.25, 1))
        ..normalize();
      cb(Puff.exhale, pointIn(root.parent, _head.node, vm.Vector3(0, -0.1, 0.36)), dir);
    }
  }

  /// Sits down with the hips [hips] above the feet, on a couch or a chair, or gets up (null).
  void sit(double? hips) {
    _hips = hips;
    if (hips != null) _seatHips = hips;
    pose = hips == null ? Pose.stand : Pose.sit;
  }

  /// [pace] speeds up the walk cycle for someone walking faster than usual.
  void update(double dt, double t, bool moving, bool airborne, [double pace = 1]) {
    final target = moving ? 1.0 : 0.0;
    _walkPhase += dt * 11 * target * pace;
    final swing = math.sin(_walkPhase) * 0.7 * target;
    if (airborne) {
      _legL.x = -0.5;
      _legR.x = 0.3;
      _armL.z = -2.4;
      _armR.z = 2.4;
      _armL.x = _armR.x = 0;
    } else {
      _legL.x = swing;
      _legR.x = -swing;
      _armL.x = -swing;
      _armR.x = swing;
      _armL.z = _lerp(_armL.z, -0.1, 0.3);
      _armR.z = _lerp(_armR.z, 0.1, 0.3);
    }
    _sitK += ((_hips == null ? 0 : 1) - _sitK) * math.min(1, dt * 10);
    final sit = _sitK > 0.001 ? _sitK : 0.0;
    if (sit > 0) {
      // Legs out over the edge of the seat, hands in the lap (a cigarette still comes up for a drag).
      for (final leg in [_legL, _legR]) {
        leg.x = _lerp(leg.x, -1.35, sit);
      }
      for (final arm in [_armL, _armR]) {
        arm.x = _lerp(arm.x, -0.55, sit);
      }
    }
    if (_smokeT >= 0) _smokeStep(dt, moving, airborne);
    var reach = 0.0;
    if (_reachT >= 0) {
      _reachT += dt;
      reach = reachCurve(_reachT / kReachTime);
      // Forward is +z, so the character's right arm is the one on -x.
      _armL.x = _lerp(_armL.x, -1.65, reach);
      _armL.z = _lerp(_armL.z, 0.22, reach);
      if (_reachT >= kReachTime) _reachT = -1;
    }
    // Lean into the reach a little.
    _body.x = reach * 0.12;
    if (_mug.visible) _mug.rotation = euler(_armR.x, _armR.y, _armR.z)..inverse();
    var bodyY = moving && !airborne ? math.sin(_walkPhase).abs() * 0.06 : 0.0;
    // Down onto (or up onto) the seat: the hips go where it puts them.
    if (sit > 0) bodyY = _lerp(bodyY, _seatHips - kHips, sit);
    _body.node.position = vm.Vector3(0, bodyY, 0);
    if (_speaking) _mic.scale = vm.Vector3.all(1 + math.sin(t * 14) * 0.2);

    // Lip flap: pop open fast on each syllable, close a little slower.
    final want = ((_voiceLevel - 0.02) / 0.12).clamp(0.0, 1.0);
    _mouthOpen += (want - _mouthOpen) * math.min(1, dt * (want > _mouthOpen ? 35 : 15));
    if (_voiceLevel > kSpeaking * 0.75) _talkUntil = t + 0.4;
    final talking = t < _talkUntil;
    _smile.visible = !talking;
    _mouth.visible = talking;
    if (talking) _mouth.scale = vm.Vector3(0.07 * (1 - _mouthOpen * 0.2), 0.01 + _mouthOpen * 0.045, 0.05);
    _head.x = -_mouthOpen * 0.08;
    for (final p in [_body, _head, _legL, _legR, _armL, _armR]) {
      p.apply();
    }
  }

  /// Takes the name tag down. Call when the person leaves.
  void dispose() {
    _labels.remove(_label);
    _label = null;
  }
}

// -----------------------------------------------------------------------------------------------

const Map<WorkerStatus, String> statusBulb = {
  WorkerStatus.starting: '#adb5bd',
  WorkerStatus.idle: '#8ecae6',
  WorkerStatus.working: '#ffd166',
  WorkerStatus.needsInput: '#ef476f',
  WorkerStatus.done: '#06d6a0',
  WorkerStatus.exited: '#6c757d',
  WorkerStatus.offline: '#6c757d',
};

/// Status pill on a worker's task card: text, background, text colour.
final Map<WorkerStatus, CardChip> taskChip = {
  WorkerStatus.starting: CardChip('⏳ STARTING', statusBulb[WorkerStatus.starting]!, '#2b2d42'),
  WorkerStatus.idle: CardChip('💬 READY', statusBulb[WorkerStatus.idle]!, '#2b2d42'),
  WorkerStatus.working: CardChip('⌨️ WORKING', statusBulb[WorkerStatus.working]!, '#2b2d42'),
  WorkerStatus.needsInput: CardChip('❗ NEEDS YOU', statusBulb[WorkerStatus.needsInput]!, '#ffffff'),
  WorkerStatus.done: CardChip('✅ DONE', statusBulb[WorkerStatus.done]!, '#2b2d42'),
  WorkerStatus.exited: CardChip('💤 ASLEEP', statusBulb[WorkerStatus.exited]!, '#ffffff'),
  WorkerStatus.offline: CardChip('💤 ASLEEP', statusBulb[WorkerStatus.offline]!, '#ffffff'),
};

/// What floats over a worker for its status: the bubble's text ('' for none) and its background.
({String text, String bg}) workerBubble(WorkerStatus status, bool bounce) {
  final hot = status == WorkerStatus.needsInput || (status == WorkerStatus.done && bounce);
  final bg = hot
      ? (status == WorkerStatus.done ? '#caffbf' : '#ffd6e0')
      : status == WorkerStatus.working
      ? '#ffec99'
      : '#fffaf3';
  final text = status == WorkerStatus.needsInput
      ? '❗ needs you'
      : status == WorkerStatus.done && bounce
      ? '✅ done!'
      : status == WorkerStatus.working
      ? '⌨️ working'
      : isAsleep(status)
      ? '💤'
      : '';
  return (text: text, bg: bg);
}

/// Sent home: the box of its things in its arms, and how far into its waddle it is.
class _Leaving {
  _Leaving(this.box);
  final Node box;
  double boxT = 0;
  double stride = 0;
}

/// The little Claude worker that sits at a desk. Forward is +z.
class Worker {
  Worker(String name, String color, this._labels) {
    final skin = toonUnique(hex(color));
    final white = toon(hex('#ffffff'));
    final ink = toon(hex('#1d1d1d'));
    final dark = toon(hex('#2b2d42'));

    root.add(_body.node);
    // Bean-shaped body
    _body.add(mesh(capsule(0.28, 0.3, 8, 16), skin, 0, 0.55, 0));
    // Big cartoon eyes
    for (final sx in [-1.0, 1.0]) {
      final eye = mesh(sphere(0.09, 12, 10), white, sx * 0.11, 0.7, 0.23, false);
      _body.add(eye);
      final pupil = mesh(sphere(0.045, 10, 8), ink, sx * 0.11, 0.7, 0.29, false);
      _body.add(pupil);
      _eyes.add((eye, 0.6));
      _eyes.add((pupil, 1));
      _pupils.add(pupil);
    }
    // Headset: band + mic
    _body.add(mesh(torus(0.29, 0.025, 6, 20, math.pi), dark, 0, 0.72, 0, false)..rotation = euler(0, math.pi / 2));
    for (final sx in [-1.0, 1.0]) {
      _body.add(mesh(sphere(0.07, 10, 8), dark, sx * 0.29, 0.72, 0, false));
    }
    // Antenna with status bulb
    _body.add(mesh(cylinder(0.015, 0.015, 0.22, 6), dark, 0, 1.07, 0, false));
    final c0 = hex(statusBulb[WorkerStatus.starting]!);
    _bulb = toonUnique(c0);
    setEmissive(_bulb, c0, 0.6);
    _bulbMesh = mesh(sphere(0.075, 12, 10), _bulb, 0, 1.2, 0, false);
    _body.add(_bulbMesh);

    Pivot arm(double x) {
      final pivot = Pivot()..position = vm.Vector3(x, 0.55, 0.05);
      pivot.add(mesh(capsule(0.055, 0.16, 4, 8), skin, 0, -0.12, 0));
      _body.add(pivot.node);
      return pivot;
    }

    _armL = arm(-0.3);
    _armR = arm(0.3);
    for (final sx in [-1.0, 1.0]) {
      final foot = mesh(capsule(0.06, 0.1, 4, 8), skin, sx * 0.12, 0.2, 0.05);
      _body.add(foot);
      _feet.add(foot);
    }
    _blink(0);
    setName(name);
  }

  final Node root = Node(name: 'worker');
  final LabelHub _labels;
  final Pivot _body = Pivot();
  late final PreprocessedMaterial _bulb;
  late final Node _bulbMesh;
  late final Pivot _armL, _armR;
  WorldLabel? _bubble;
  String _bubbleKey = '';

  /// The bubble is a task card: it hangs from its tail instead of floating.
  bool _bubbleIsCard = false;
  WorkerTask? _task;
  WorldLabel? _nameTag;

  /// Each eye part and its resting z scale (the whites are squashed flat onto the face).
  final List<(Node, double)> _eyes = [];
  double _blinkAt = _rng.nextDouble() * 4;
  WorkerStatus status = WorkerStatus.starting;
  bool bouncing = false;

  /// You're close enough to read its card: it lands the hop it's in and stands still until you walk away.
  bool held = false;
  double _bounceT = 0;
  double _spawnT = 0;

  /// Seconds left jumping for joy (its pull request just merged).
  double _cheerT = 0;
  final List<Node> _pupils = [];
  final List<Node> _feet = [];
  _Leaving? _leaving;

  /// Sent home and on its way out: it waddles along instead of standing.
  bool walking = false;

  void setName(String name) {
    _labels.remove(_nameTag);
    _nameTag = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.55, 0),
        alignment: Alignment.center,
        child: TagPill(name, bg: '#2b2d42', color: '#fffaf3', size: 36, border: '#fffaf3'),
      ),
    );
  }

  void setStatus(WorkerStatus status, bool bounce) {
    this.status = status;
    bouncing = bounce;
    final c = hex(statusBulb[status] ?? '#adb5bd');
    setToonColor(_bulb, c);
    setEmissive(_bulb, c, 0.7);
    _drawBubble();
  }

  /// Jumps for joy, arms up, for a few seconds.
  void cheer([double seconds = 3]) => _cheerT = seconds;

  /// What it's working on, shown on a card over its head in place of the status bubble.
  void setTask(WorkerTask? task) {
    _task = task;
    _drawBubble();
  }

  WorkerTask? get task => _task;

  /// Sent home: its light goes out, its face falls, and its things pop into a box in its arms.
  /// [farewell] goes over its head.
  void leave(String farewell) {
    if (_leaving != null) return;
    bouncing = false;
    _cheerT = 0;
    _bounceT = 0;
    setToonColor(_bulb, hex(statusBulb[WorkerStatus.exited]!));
    setEmissive(_bulb, const Color(0xFF000000));
    _labels.remove(_bubble);
    _bubbleKey = 'leaving';
    _bubbleIsCard = false;
    _bubble = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.95, 0),
        alignment: Alignment.center,
        child: TagPill(farewell, bg: '#e9ecef', size: 34),
      ),
    );
    // Looking down, brows up in the middle.
    for (final p in _pupils) {
      p.position = p.position + vm.Vector3(0, -0.035, 0);
    }
    for (final sx in [-1.0, 1.0]) {
      final brow = mesh(capsule(0.014, 0.08, 4, 6), toon(hex('#1d1d1d')), sx * 0.11, 0.83, 0.228, false)
        ..rotation = euler(0, 0, math.pi / 2 - sx * 0.4);
      _body.add(brow);
    }
    // Hugged to its belly, the arms round the sides.
    final box = boxOfStuff()
      ..position = vm.Vector3(0, 0.22, 0.33)
      ..scale = vm.Vector3.all(0.001);
    _body.add(box);
    _leaving = _Leaving(box);
  }

  bool get isLeaving => _leaving != null;

  void _drawBubble() {
    if (_leaving != null) return;
    final task = _task;
    final b = workerBubble(status, bouncing);
    final key = task != null ? '${status.wire}|$bouncing|${task.name}|${task.summary}' : b.text;
    if (key == _bubbleKey) return;
    _bubbleKey = key;
    _labels.remove(_bubble);
    _bubble = null;
    _bubbleIsCard = task != null;
    if (task != null) {
      _bubble = WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.74, 0),
        alignment: Alignment.bottomCenter,
        child: TaskCard(
          chip: taskChip[status] ?? taskChip[WorkerStatus.idle],
          title: task.name,
          body: task.summary,
          bg: isAsleep(status) ? '#e9ecef' : b.bg,
        ),
      );
    } else if (b.text.isNotEmpty) {
      _bubble = WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.95, 0),
        alignment: Alignment.center,
        child: TagPill(b.text, bg: b.bg, size: 38),
      );
    }
    if (_bubble != null) _labels.add(_bubble!);
  }

  void update(double dt, double t) {
    final l = _leaving;
    if (l != null) return _carry(l, dt, t);
    _cheerT = math.max(0, _cheerT - dt);
    // Jump up and down when done / waiting on a human (except while held), or cheering.
    if (bouncing || _cheerT > 0) {
      final landAt = (_bounceT / math.pi).ceil() * math.pi;
      _bounceT += dt * 7;
      if (held && _cheerT == 0 && _bounceT >= landAt) _bounceT = 0;
    } else {
      _bounceT = 0;
    }
    final hopping = _bounceT > 0;
    final working = status == WorkerStatus.working && !hopping;
    // Pop-in when hired
    _spawnT = math.min(1, _spawnT + dt * 2.5);
    final pop = _spawnT < 1 ? 1 + math.sin(_spawnT * math.pi) * 0.35 : 1.0;
    // Typing arms
    if (working) {
      _armL.x = -1.2 + math.sin(t * 22) * 0.25;
      _armR.x = -1.2 + math.sin(t * 22 + 1.7) * 0.25;
    } else {
      _armL.x = _lerp(_armL.x, hopping || bouncing ? -2.6 : -0.3, 0.2);
      _armR.x = _lerp(_armR.x, hopping || bouncing ? -2.6 : -0.3, 0.2);
    }
    var bodyY = 0.0;
    if (hopping) {
      final s = math.sin(_bounceT).abs();
      bodyY = s * 0.55;
      final squash = s < 0.15 ? 1 - (0.15 - s) * 1.6 : 1.0;
      _body.node.scale = vm.Vector3(pop * (2 - squash), pop * squash, pop * (2 - squash));
      _body.y = math.sin(_bounceT * 0.5) * 0.3;
    } else {
      bodyY = working ? math.sin(t * 11).abs() * 0.02 : math.sin(t * 2) * 0.015;
      _body.node.scale = vm.Vector3.all(pop);
      _body.y = _lerp(_body.y, 0, 0.1);
    }
    _body.node.position = vm.Vector3(0, bodyY, 0);
    _blink(dt);
    _bulbMesh.scale = vm.Vector3.all(status == WorkerStatus.needsInput ? 1 + math.sin(t * 8).abs() * 0.5 : 1);
    if (isAsleep(status)) _body.z = math.sin(t * 1.5) * 0.08;
    _body.apply();
    _armL.apply();
    _armR.apply();
    final lift = hopping ? bodyY : 0.0;
    _bubble?.offset = vm.Vector3(0, (_bubbleIsCard ? 1.74 : 1.95) + lift + math.sin(t * 3) * 0.03, 0);
    _nameTag?.offset = vm.Vector3(0, 1.55 + lift, 0);
  }

  /// Sent home: head hung, the box in its arms, waddling along while [walking].
  void _carry(_Leaving l, double dt, double t) {
    // The box pops in, overshooting a little.
    l.boxT = math.min(1, l.boxT + dt * 2.5);
    final u = l.boxT - 1;
    l.box.scale = vm.Vector3.all(math.max(0.001, 1 + 2.7 * u * u * u + 1.7 * u * u));
    final k = math.min(1.0, dt * 10);
    _armL.x += (-1 - _armL.x) * k;
    _armR.x += (-1 - _armR.x) * k;
    _armL.z += (0.12 - _armL.z) * k;
    _armR.z += (-0.12 - _armR.z) * k;
    if (walking) l.stride += dt * 9;
    final s = walking ? math.sin(l.stride) : 0.0;
    for (var i = 0; i < _feet.length; i++) {
      final step = i > 0 ? -s : s;
      final f = _feet[i];
      f.position = vm.Vector3(f.position.x, 0.2 + math.max(0, step) * 0.05, 0.05 + step * 0.08);
    }
    _body.node.position = vm.Vector3(0, s.abs() * 0.05, 0);
    _body.z = s * 0.1;
    _body.x += (0.15 - _body.x) * math.min(1, dt * 4);
    _body.y += -_body.y * k;
    _body.node.scale = vm.Vector3.all(1);
    _bulbMesh.scale = vm.Vector3.all(1);
    _blink(dt);
    _body.apply();
    _armL.apply();
    _armR.apply();
    _bubble?.offset = vm.Vector3(0, 1.95 + math.sin(t * 3) * 0.03, 0);
    _nameTag?.offset = vm.Vector3(0, 1.55, 0);
  }

  void _blink(double dt) {
    _blinkAt -= dt;
    final blinking = _blinkAt < 0.12 && _blinkAt > 0;
    if (_blinkAt < 0) _blinkAt = 2 + _rng.nextDouble() * 4;
    for (final (e, z) in _eyes) {
      e.scale = vm.Vector3(1, blinking ? 0.1 : 1, z);
    }
  }

  /// Takes its labels down.
  void dispose() {
    _labels.remove(_bubble);
    _labels.remove(_nameTag);
    _bubble = _nameTag = null;
  }
}
