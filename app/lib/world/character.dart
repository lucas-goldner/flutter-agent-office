// The people in the office: a port of world/character.ts. [Person] is the chibi human everyone
// plays (walk cycle, sitting, typing, reaching, a mug, a smoke, a talking mouth), [Worker] the little
// AI agent at a desk with its status bulb and task card, and the props they hold.
//
// three.js groups pivot at their origin, so every joint here is a node of its own with the limb
// hung off it, as in the TS; joints the animation turns keep three-style Euler angles ([Pivot]).

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/widgets.dart' show Alignment, HSLColor;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/avatar.dart';
import 'package:office_shared/emotes.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

import 'costumes.dart';
import 'emoji_pop.dart';
import 'geo.dart';
import 'label_widgets.dart';
import 'card.dart';
import 'labels.dart';
import 'worker_pr.dart';
import 'player.dart' show kHips;
import 'toon.dart';
import 'worker_acts.dart';

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

/// 0 → 1 → 0 over an emote [t] seconds into it: eased in quickly, out a little slower at the end.
double emoteEnvelope(double t, double seconds) {
  final k = math.min(t / 0.18, (seconds - t) / 0.3).clamp(0.0, 1.0);
  return k * k * (3 - 2 * k);
}

/// Overshoots 1 a little on the way there (p = 0..1), for things that pop in.
double popCurve(double p) {
  final u = math.min(1.0, p) - 1;
  return 1 + 2.7 * u * u * u + 1.7 * u * u;
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
    final cup = coffeeMug(1.4)
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
    // Along the arm (the fist's -y) the finger points; the thumb sticks out of the front of the fist,
    // which is up once the arm is out in front.
    _thumb = mesh(capsuleData(0.035, 0.07, 4, 8).rotateX(math.pi / 2).build(), skin, 0, -0.38, 0.1, false);
    _finger = mesh(capsule(0.03, 0.09, 4, 8), skin, 0, -0.5, 0.02, false);
    for (final m in [_thumb, _finger]) {
      m.visible = false;
      _armL.add(m);
    }

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

  /// Held in the left hand, kept upright however the arm swings.
  final Node _mug = Node();
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

  /// The emote being played, how far into it (seconds), and its emoji over their head.
  ({Emote emote, WorldLabel pop})? _emoting;
  double _emoteT = 0;

  /// A thumb up and a pointing finger on the right hand, out only for those emotes.
  late final Node _thumb, _finger;

  /// How much higher (meters) an emote's emoji pops up, to clear a chat bubble over their head.
  double emojiLift = 0;

  /// Dressed up for a holiday (see [setCostume]): a warlock's hat and undead skin, or a Santa hat.
  HolidayTheme? _costume;
  Node? _hat;

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
    setToonColor(_hairMat, hex(hairColors[look.hair]));
    if (restyle) _buildHair();
    _dress();
  }

  HolidayTheme? get costume => _costume;

  /// Dresses up for a holiday: a crooked warlock's hat and undead skin for Halloween, a Santa hat for
  /// Christmas. Null takes it off.
  void setCostume(HolidayTheme? theme) {
    if (theme == _costume) return;
    _costume = theme;
    _hat?.detach();
    _hat = switch (theme) {
      HolidayTheme.halloween => warlockHat(),
      HolidayTheme.christmas => santaHat(),
      null => null,
    };
    if (_hat != null) _head.add(_hat!);
    _dress();
  }

  /// The skin and hair under the costume: hair that would poke through a hat's crown hides under it.
  void _dress() {
    var skin = hex(skinTones[_look.skin]);
    if (_costume == HolidayTheme.halloween) skin = mixColor(skin, kUndeadSkin, 0.7);
    setToonColor(_skin, skin);
    final style = hairStyles[_look.style];
    _hair.visible = _costume == null || !(style == 'Spiky' || style == 'Bun' || style == 'Curly');
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
        offset: vm.Vector3(0, 2.0 + _doingLift, 0),
        alignment: Alignment.center,
        child: TagPill('$name$suffix', bg: '#fffaf3', size: 40),
      ),
    );
  }

  // ---- The line under the name tag: what they have open, or where they are (see whereabouts) ----

  WorldLabel? _doing;
  String _doingText = '';

  /// How far the line under the name tag lifts the name tag (and the mic badge, and chat bubbles).
  double get _doingLift => _doing != null ? 0.25 : 0;

  /// Where a chat bubble goes: over the name tag, however high it sits.
  double get bubbleY => 2.45 + _doingLift;

  /// Puts a smaller line under the name tag, like "💻 in Pixel's terminal"; null (or '') takes it away.
  void setDoing(String? text) {
    text ??= '';
    if (text == _doingText) return;
    _doingText = text;
    _labels.remove(_doing);
    _doing = null;
    if (text.isNotEmpty) {
      _doing = _labels.add(
        WorldLabel(
          anchor: root,
          offset: vm.Vector3(0, 1.95, 0),
          alignment: Alignment.center,
          child: TagPill(text, bg: '#e9ecef', size: 26),
        )..visible = _label?.visible ?? true,
      );
    }
    // The name tag and the mic badge move up out of the way of the line under them.
    _label?.offset = vm.Vector3(0, 2.0 + _doingLift, 0);
    _mic.position = vm.Vector3(_mic.position.x, 2.25 + _doingLift, _mic.position.z);
  }

  /// How loud this person is talking right now (0 when silent); drives the mic badge and the mouth.
  void setVoiceLevel(double level) {
    _voiceLevel = level;
    _speaking = level > kSpeaking;
    _mic.visible = _speaking;
  }

  void showLabel(bool v) {
    _label?.visible = v;
    _doing?.visible = v;
  }

  /// Reach out with the right hand, as if pressing or grabbing something in front of you.
  void reach() => _reachT = 0;

  /// A mug of coffee in the left hand, or not. It waits while the hands are full (a card).
  void holdMug(bool on) {
    _wantsMug = on;
    _mug.visible = on && !(_card?.held ?? false);
  }

  bool _wantsMug = false;

  /// An issue card off the board, held out in front in both hands (see carry).
  HeldCard? _card;

  /// Carries an issue card in both hands, or puts it down (null). The mug waits while the hands are full.
  void carry(CarriedIssue? card) {
    if (card == null && _card == null) return;
    _card ??= () {
      // Between the hands when both arms are out in front (see update), its front to whoever they walk up to.
      final holder = Node(name: 'card-holder')
        ..position = vm.Vector3(0, 0.8, 0.36)
        ..rotation = euler(-0.1, 0, 0);
      _body.add(holder);
      return HeldCard(holder, 0.46);
    }();
    _card!.set(card);
    holdMug(_wantsMug);
  }

  /// Waves, gives a thumbs up, claps…: the gesture, with its emoji popping up over their head.
  void emote(Emote e) {
    _endEmote();
    final pop = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 2.42 + emojiLift, 0),
        alignment: Alignment.center,
        child: EmojiPop(e.emoji, scale: 0.001),
        priority: 1,
      ),
    );
    _emoting = (emote: e, pop: pop);
    _emoteT = 0;
    _thumb.visible = e == Emote.thumbs;
    _finger.visible = e == Emote.point;
  }

  /// The emote playing now, if any.
  Emote? get emoting => _emoting?.emote;

  void _endEmote() {
    final e = _emoting;
    if (e == null) return;
    _labels.remove(e.pop);
    _emoting = null;
    _thumb.visible = _finger.visible = false;
  }

  /// Poses the emote over whatever the arms were doing (walking, sitting, a drag on a cigarette),
  /// `k` of the way. The dance's bounce and steps only happen with both feet on the floor ([still]).
  void _emoteStep(double dt, double still) {
    final e = _emoting!;
    _emoteT += dt;
    final seconds = e.emote.seconds;
    final u = _emoteT;
    if (u >= seconds) return _endEmote();
    final k = emoteEnvelope(u, seconds);
    void pose(Pivot arm, double x, double z) {
      arm.x = _lerp(arm.x, x, k);
      arm.z = _lerp(arm.z, z, k);
    }

    var lift = 0.0;
    // Forward is +z, so the character's right arm is the one on -x (armL), as in reach.
    switch (e.emote) {
      case Emote.wave:
        pose(_armL, -0.35, -2.55 + math.sin(u * 12) * 0.35);
        _head.z = -0.1 * k;
      case Emote.thumbs:
        // Out in front, with a little pump that settles.
        pose(_armL, -1.75 - math.exp(-u * 3) * math.sin(u * 14) * 0.25, 0.2);
        _head.z = -0.08 * k;
      case Emote.clap:
        // Both hands out in front, meeting in the middle about three times a second.
        final c = 0.5 - 0.5 * math.cos(u * 19);
        pose(_armL, -1.25, 0.3 + 0.42 * c);
        pose(_armR, -1.25, -0.3 - 0.42 * c);
        lift = math.sin(u * 9.5).abs() * 0.02 * k * still;
      case Emote.dance:
        // Two beats a second: arms up by turns, a hop on every beat, hips swaying, a knee up.
        final b = u * math.pi * 2;
        final s = math.sin(b);
        pose(_armL, -0.3, _lerp(-0.35, -2.7, (s + 1) / 2));
        pose(_armR, -0.3, _lerp(0.35, 2.7, (1 - s) / 2));
        final m = k * still;
        lift = math.sin(b).abs() * 0.08 * m;
        _body.z = s * 0.12 * m;
        _body.y = math.sin(b / 2) * 0.45 * m;
        _legL.x = _lerp(_legL.x, -math.max(0, s) * 0.7, m);
        _legR.x = _lerp(_legR.x, -math.max(0, -s) * 0.7, m);
        _head.z = -s * 0.1 * k;
      case Emote.point:
        // Arm straight out at whatever you face, with a jab to start.
        pose(_armL, -1.6 - math.exp(-u * 4) * math.sin(u * 16) * 0.15, 0.05);
      case Emote.facepalm:
        // Hand to the face, head down and shaking slowly.
        pose(_armL, -2.4, 0.62);
        _body.x += 0.1 * k;
        _head.x += 0.3 * k;
        _head.y = math.sin(u * 5) * 0.15 * k;
    }
    if (lift != 0) _body.node.position = _body.node.position + vm.Vector3(0, lift, 0);
    // The emoji pops in over their head, rises a little, wobbles, and fades at the end.
    e.pop
      ..offset = vm.Vector3(0, 2.42 + emojiLift + math.min(u, 1.5) * 0.12, 0)
      ..child = EmojiPop(
        e.emote.emoji,
        scale: popCurve(u / 0.3),
        angle: math.sin(u * 7) * 0.12,
        opacity: ((seconds - u) / 0.4).clamp(0.0, 1.0),
      );
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
    if (_card?.held ?? false) {
      // Both arms out in front, hands on the card's edges: it doesn't swing while they walk.
      _armL
        ..x = -1.25
        ..y = 0
        ..z = 0.3;
      _armR
        ..x = -1.25
        ..y = 0
        ..z = -0.3;
    }
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
    _head.y = _head.z = 0;
    _body.y = _body.z = 0;
    if (_emoting != null) _emoteStep(dt, moving || airborne ? 0 : 1 - sit);
    for (final p in [_body, _head, _legL, _legR, _armL, _armR]) {
      p.apply();
    }
  }

  /// Takes the name tag down. Call when the person leaves.
  void dispose() {
    _endEmote();
    _labels.remove(_label);
    _label = null;
    _labels.remove(_doing);
    _doing = null;
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

/// A stack of papers held up to read, bound at the top; its top sheet flips over. The sheets face -z.
({Node group, Node page}) _papersProp() {
  final group = Node(name: 'papers');
  const w = 0.34, h = 0.44;
  final ink = toon(hex('#8d99ae'));
  const shades = ['#f1ece2', '#f7f3ea', '#fffaf3'];
  for (var i = 0; i < 3; i++) {
    group.add(
      mesh(box(w, h, 0.008), toon(hex(shades[i])), (i - 1) * 0.012, -h / 2 - i * 0.006, 0.02 - i * 0.012, false)
        ..rotation = euler(0, 0, (i - 1) * 0.04),
    );
  }
  void lines(Node on, double z) {
    for (var i = 0; i < 6; i++) {
      final short = i % 3 == 2;
      on.add(
        mesh(box(w * (short ? 0.45 : 0.72), 0.018, 0.004), ink, short ? -w * 0.135 : 0, -0.07 - i * 0.055, z, false),
      );
    }
  }

  lines(group, -0.01);
  // The top sheet hangs from the binding, so it flips up over the top.
  final page = Node(name: 'page');
  page.add(mesh(box(w, h, 0.008), toon(hex('#fffaf3')), 0, -h / 2, -0.016, false));
  lines(page, -0.022);
  group.add(page);
  group.add(mesh(box(w * 0.5, 0.05, 0.05), toon(hex('#adb5bd')), 0, 0, 0, false));
  return (group: group, page: page);
}

/// A little globe: blue sea, green blobs of land and a gold ring round its middle.
({Node group, Node ball, Node ring}) _globeProp() {
  final group = Node(name: 'globe');
  final ball = Node(name: 'ball');
  const r = 0.26;
  ball.add(mesh(sphere(r, 20, 14), toon(hex('#4cc9f0')), 0, 0, 0, false));
  final land = toon(hex('#6fcf6a'));
  for (final (lat, lon, size) in const [
    (0.5, 0.2, 0.5),
    (0.1, 0.9, 0.4),
    (-0.4, 0.5, 0.45),
    (0.3, 2.4, 0.6),
    (-0.2, 3.3, 0.4),
    (0.6, 4.4, 0.45),
    (-0.5, 5.2, 0.35),
  ]) {
    ball.add(
      mesh(
        sphere(size * r, 10, 8),
        land,
        math.cos(lat) * math.sin(lon) * r * 0.86,
        math.sin(lat) * r * 0.86,
        math.cos(lat) * math.cos(lon) * r * 0.86,
        false,
      )..scale = vm.Vector3(1.2, 0.8, 1.2),
    );
  }
  group.add(ball);
  final ring = mesh(torus(r * 1.35, 0.016, 6, 32), toon(hex('#ffd166'), emissive: hex('#7a5b00')), 0, 0, 0, false);
  group.add(ring);
  return (group: group, ball: ball, ring: ring);
}

/// Where a worker climbs up to dance, in the frame of the seat it sits in (see DeskView.stage).
class Stage {
  const Stage(this.pos, this.yaw);
  final vm.Vector3 pos;

  /// Which way it faces up there, turned from the way it faces in its seat.
  final double yaw;
}

/// Where [stage] is from [seat], both anywhere under the same root: the transform between them.
Stage stageFrom(Node seat, Node stage) {
  final m = vm.Matrix4.inverted(seat.globalTransform) * stage.globalTransform as vm.Matrix4;
  final ahead = m.rotated3(vm.Vector3(0, 0, 1));
  return Stage(m.getTranslation(), math.atan2(ahead.x, ahead.z));
}

class _Dance {
  _Dance(this.stage);
  Stage stage;
  double t = 0;
}

/// The little Claude worker that sits at a desk. Forward is +z.
class Worker {
  Worker(String name, String color, this._labels) : _color = hex(color) {
    final skin = _skin = toonUnique(_color);
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

    // What it acts out with: papers in its hands, and a globe beside its laptop.
    _papers = _papersProp();
    _papers.group
      ..position = vm.Vector3(0, 0.86, 0.4)
      ..rotation = euler(0.35, 0);
    _body.add(_papers.group);
    _globe = _globeProp();
    _papers.group.visible = _globe.group.visible = false;
    root.add(_globe.group);

    _blink(0);
    setName(name);
  }

  final Node root = Node(name: 'worker');
  final LabelHub _labels;
  final Color _color;
  late final PreprocessedMaterial _skin;
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

  /// Up on its desk dancing (a pull request merged): where, and how many seconds in.
  _Dance? _dancing;

  /// On its way out (sent home) or in (called to a meeting): it waddles along instead of standing.
  bool walking = false;

  /// What its latest tool call was (see [setAction]), and what it's acting out right now.
  final ActionTimer _actions = ActionTimer();
  final StanceBlend _blend = StanceBlend();

  /// Seconds it has been waiting on you, for the jump / tap-its-foot cycle.
  double _waitT = 0;
  double _turnY = 0;

  /// Seconds into its finishing spin, or -1.
  double _twirlT = -1;
  double _flipT = 0;
  late final ({Node group, Node page}) _papers;
  late final ({Node group, Node ball, Node ring}) _globe;

  /// Beside its laptop, where the globe floats (see [setPropSpot]).
  vm.Vector3 _spot = vm.Vector3(-1, 1.1, 1.3);

  /// Dressed up for a holiday (see [setCostume]), and what it's wearing.
  HolidayTheme? _costume;
  final List<Node> _outfit = [];

  /// Where it is in its own shamble, so a room full of zombies doesn't sway in step.
  final double _phase = _rng.nextDouble() * math.pi * 2;

  /// How far through its stride it is, walking in.
  double _stride = 0;

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

  /// Where the globe floats, in its own space: beside its laptop, where the card over its head doesn't hide it.
  void setPropSpot(vm.Vector3 at) => _spot = at.clone();

  /// What its latest tool call was, to act out while it's working.
  void setAction(WorkerAction? action) => _actions.next = action;

  /// What it's acting out right now (its latest tool call, held a moment so quick ones don't flicker).
  WorkerAction? get action => _actions.current;

  /// Just finished: a quick spin and a hop.
  void celebrate() {
    _twirlT = 0;
    cheer(1.2);
  }

  HolidayTheme? get costume => _costume;

  /// Dresses it up for a holiday (a zombie for Halloween, an elf for Christmas), or back in its own skin (null).
  void setCostume(HolidayTheme? theme) {
    if (theme == _costume) return;
    _costume = theme;
    _undress();
    void wear(Node parent, Node o) {
      parent.add(o);
      _outfit.add(o);
    }

    var c = _color;
    if (theme == HolidayTheme.halloween) c = scaleColor(mixColor(c, kZombie, 0.6), 0.85);
    setToonColor(_skin, c);
    if (theme == HolidayTheme.halloween) {
      wear(_body.node, zombieWorker(_skin));
    } else if (theme == HolidayTheme.christmas) {
      wear(_body.node, elfHat());
      wear(_body.node, elfWorker(_skin));
      for (final f in _feet) {
        wear(f, elfBoot());
      }
    }
  }

  void _undress() {
    for (final o in _outfit) {
      o.detach();
    }
    _outfit.clear();
  }

  void setStatus(WorkerStatus status, bool bounce) {
    this.status = status;
    bouncing = bounce;
    if (_dancing == null) _paintBulb();
    _drawBubble();
  }

  void _paintBulb() {
    final c = hex(statusBulb[status] ?? '#adb5bd');
    setToonColor(_bulb, c);
    setEmissive(_bulb, c, 0.7);
  }

  /// Jumps for joy, arms up, for a few seconds.
  void cheer([double seconds = 3]) => _cheerT = seconds;

  /// Hops up on to [stage] (its desk), dances for a few seconds with its light flashing like a disco
  /// ball, and hops back down into its seat. Asked again mid-dance, it stays up and dances on.
  void dance(Stage stage) {
    if (_leaving != null) return;
    final d = _dancing;
    if (d == null) {
      _dancing = _Dance(stage);
      // The dance has a twirl of its own, so a finishing spin it cut into doesn't play after it.
      _twirlT = -1;
    } else {
      d.t = danceAgain(d.t);
    }
  }

  bool get isDancing => _dancing != null;

  /// Back in its seat at once, mid-dance or not (it's being sent home).
  void stopDancing() {
    if (_dancing == null) return;
    _dancing = null;
    _settle();
  }

  /// What it's working on, shown on a card over its head in place of the status bubble.
  void setTask(WorkerTask? task) {
    _task = task;
    _drawBubble();
  }

  WorkerTask? get task => _task;

  /// On its way out: says something else over its head in place of its farewell.
  void say(String text) {
    if (_leaving == null) return;
    _labels.remove(_bubble);
    _bubble = _labels.add(
      WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.95, 0),
        alignment: Alignment.center,
        child: TagPill(text, bg: '#e9ecef', size: 34),
      ),
    );
  }

  /// Sent home: its light goes out, its face falls, and its things pop into a box in its arms.
  /// [farewell] goes over its head.
  void leave(String farewell) {
    if (_leaving != null) return;
    bouncing = false;
    _cheerT = 0;
    _bounceT = 0;
    _twirlT = -1;
    _papers.group.visible = _globe.group.visible = false;
    _armL.position = vm.Vector3(-0.3, 0.55, 0.05);
    _armR.position = vm.Vector3(0.3, 0.55, 0.05);
    for (var i = 0; i < _feet.length; i++) {
      _feet[i].position = vm.Vector3(i > 0 ? 0.12 : -0.12, 0.2, 0.05);
    }
    for (final p in _pupils) {
      p.position = vm.Vector3(p.position.x, 0.7, p.position.z);
    }
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

  /// Its pull request, open or merged: its bubble is outlined (and labelled, while it rests) to match.
  WorkerPr? _pr;

  void setPr(WorkerPr? pr) {
    if (pr == _pr) return;
    _pr = pr;
    _drawBubble();
  }

  void _drawBubble() {
    if (_leaving != null) return;
    final task = _task;
    final b = workerBubble(status, bouncing);
    final pr = _pr;
    final border = pr != null ? prInk[pr.state] : null;
    // Not working on or waiting for something more: its pull request in place of ready / done / asleep.
    final prText = prLabel(pr, status);
    final text = prText ?? b.text;
    final key = '$border|$prText|${task != null ? '${status.wire}|$bouncing|${task.name}|${task.summary}' : text}';
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
          chip: prText != null ? CardChip(prText.toUpperCase(), border!, '#ffffff') : taskChip[status] ?? taskChip[WorkerStatus.idle],
          title: task.name,
          body: task.summary,
          bg: isAsleep(status) ? '#e9ecef' : b.bg,
          border: border,
        ),
      );
    } else if (text.isNotEmpty) {
      _bubble = WorldLabel(
        anchor: root,
        offset: vm.Vector3(0, 1.95, 0),
        alignment: Alignment.center,
        child: TagPill(text, bg: b.bg, size: 38, border: border ?? '#2b2d42'),
      );
    }
    if (_bubble != null) _labels.add(_bubble!);
  }

  void update(double dt, double t) {
    final l = _leaving;
    if (l != null) return _carry(l, dt, t);
    final d = _dancing;
    if (d != null) return _boogie(d, dt, t);
    _cheerT = math.max(0, _cheerT - dt);
    // Waiting on you: a couple of seconds of jumping, then arms crossed and a tapping foot, and round again.
    _waitT = status == WorkerStatus.needsInput ? _waitT + dt : 0;
    final tapping = status == WorkerStatus.needsInput && (held || _waitT % kWaitCycle >= kWaitHops);
    // Jump up and down when done / waiting on a human (except while held or tapping), or cheering.
    if (bouncing || _cheerT > 0) {
      final landAt = (_bounceT / math.pi).ceil() * math.pi;
      _bounceT += dt * 7;
      if ((held || tapping) && _cheerT == 0 && _bounceT >= landAt) _bounceT = 0;
    } else {
      _bounceT = 0;
    }
    final hopping = _bounceT > 0;
    // Pop-in when hired
    _spawnT = math.min(1, _spawnT + dt * 2.5);
    final pop = _spawnT < 1 ? 1 + math.sin(_spawnT * math.pi) * 0.35 : 1.0;

    final action = _actions.step(dt);
    final act = pickAct(status: status, hopping: hopping, bouncing: bouncing, action: action);
    final s = _blend.pose(act, dt, t);
    // A zombie at rest stands with its arms out in front of it, groping, listing to one side and swaying.
    final shamble = _costume == HolidayTheme.halloween ? math.min(1.0, _blend.weight(Act.rest)) : 0.0;
    if (shamble > 0) {
      s.armLx += (-1.4 + math.sin(t * 1.6 + _phase) * 0.12 - s.armLx) * shamble;
      s.armRx += (-1.4 + math.sin(t * 1.6 + _phase + 1.3) * 0.12 - s.armRx) * shamble;
      s.roll += (0.09 + math.sin(t * 1.1 + _phase) * 0.05) * shamble;
    }

    _armL
      ..x = s.armLx
      ..y = 0
      ..z = s.armLz;
    _armR
      ..x = s.armRx
      ..y = 0
      ..z = s.armRz;
    _armL.position = vm.Vector3(-0.3 + s.reach * 0.07, 0.55 - s.drop, 0.05 + s.reach * 0.12);
    _armR.position = vm.Vector3(0.3 - s.reach * 0.07, 0.55 - s.drop + s.reach * 0.04, 0.05 + s.reach * 0.14);
    for (var i = 0; i < _feet.length; i++) {
      final r = i > 0;
      _feet[i].position = vm.Vector3(
        r ? 0.12 : -0.12,
        0.2 + (r ? s.tap * 0.07 : 0),
        0.05 + s.kick + (r ? s.tap * 0.03 : 0),
      );
    }
    for (final p in _pupils) {
      p.position = vm.Vector3(p.position.x, 0.7 + s.look, p.position.z);
    }
    _body.x = s.lean;
    var twirl = 0.0;
    if (_twirlT >= 0) {
      _twirlT += dt;
      twirl = easeInOut(math.min(1, _twirlT / kTwirlTime)) * math.pi * 2;
      if (_twirlT >= kTwirlTime) _twirlT = -1;
    }
    var bodyY = 0.0;
    if (hopping) {
      final h = math.sin(_bounceT).abs();
      bodyY = h * 0.55;
      final squash = h < 0.15 ? 1 - (0.15 - h) * 1.6 : 1.0;
      _body.node.scale = vm.Vector3(pop * (2 - squash), pop * squash, pop * (2 - squash));
      _turnY = math.sin(_bounceT * 0.5) * 0.3;
    } else {
      bodyY = s.lift;
      _body.node.scale = vm.Vector3.all(pop);
      _turnY += (s.turn - _turnY) * math.min(1, dt * 6);
    }
    _body.y = _turnY + twirl;
    _body.z = isAsleep(status) ? math.sin(t * 1.5) * 0.08 : s.roll;
    _props(dt, t);
    _blink(dt, s.lid);
    _bulbMesh.scale = vm.Vector3.all(status == WorkerStatus.needsInput ? 1 + math.sin(t * 8).abs() * 0.5 : 1);
    final lift = hopping ? bodyY : 0.0;
    _bubble?.offset = vm.Vector3(0, (_bubbleIsCard ? 1.74 : 1.95) + lift + math.sin(t * 3) * 0.03, 0);
    _nameTag?.offset = vm.Vector3(0, 1.55 + lift, 0);
    // Walking in to a meeting: the same waddle as on the way out, without the box.
    if (walking || _stride != 0) {
      _stride = walking ? _stride + dt * 9 : 0;
      final w = math.sin(_stride);
      for (var i = 0; i < _feet.length; i++) {
        final step = i > 0 ? -w : w;
        final f = _feet[i];
        f.position = vm.Vector3(f.position.x, 0.2 + math.max(0, step) * 0.05, 0.05 + step * 0.08);
      }
      bodyY += w.abs() * 0.05;
      _body.z = w * 0.1;
    }
    _body.node.position = vm.Vector3(0, bodyY, 0);
    _body.apply();
    _armL.apply();
    _armR.apply();
  }

  /// The papers and the globe come and go with the act they belong to.
  void _props(double dt, double t) {
    bool show(Node prop, Act act) {
      final w = _blend.weight(act);
      prop.visible = w > 0.02;
      if (prop.visible) prop.scale = vm.Vector3.all(math.max(0.001, popIn(w)));
      return prop.visible;
    }

    if (show(_papers.group, Act.read)) {
      // A page every second or so, flipped up and over the top.
      _flipT = (_flipT + dt) % 1.1;
      final f = math.min(1.0, _flipT / 0.45);
      _papers.page.rotation = euler(-easeInOut(f) * math.pi * 1.1, 0);
      _papers.page.visible = f < 1;
    }
    if (show(_globe.group, Act.web)) {
      _globe.group.position = _spot + vm.Vector3(0, math.sin(t * 2) * 0.03, 0);
      _globe.ball.rotation = euler(0, t * 2.2, 0.41);
      _globe.ring.rotation = euler(math.pi / 2 - 0.2, 0, t * 0.6);
    }
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

  /// Up on the desk dancing: hop up, groove side to side, twirl, jump twice, hop back down.
  void _boogie(_Dance d, double dt, double t) {
    d.t += dt;
    if (d.t >= kDanceTime) {
      _dancing = null;
      _settle();
      return update(0, t);
    }
    final m = danceAt(d.t);
    // Between the seat (0) and the stage (1), with a hop's arc over the line between them.
    final e = easeInOut(m.on);
    final pos = d.stage.pos;
    root.position = vm.Vector3(pos.x * e, pos.y * m.on + m.arc, pos.z * e);
    root.rotation = euler(0, d.stage.yaw * e);

    // Whatever it was acting out waits: shoulders back in place, eyes ahead, the papers and globe put away.
    _armL.position = vm.Vector3(-0.3, 0.55, 0.05);
    _armR.position = vm.Vector3(0.3, 0.55, 0.05);
    for (final p in _pupils) {
      p.position = vm.Vector3(p.position.x, 0.7, p.position.z);
    }
    _papers.group.visible = _globe.group.visible = false;
    final k = 1 - math.exp(-dt * 18);
    for (final (i, a) in [_armL, _armR].indexed) {
      a.x += (m.armX[i] - a.x) * k;
      a.z += (m.armZ[i] - a.z) * k;
    }
    _body.node.position = vm.Vector3(m.sway * 0.3, m.lift, 0);
    _body
      ..x = 0
      ..y = m.twist
      ..z = m.sway;
    // Squashed a little as it lands.
    final squash = m.beat >= 0 && m.lift < 0.03 ? 1 - (0.03 - m.lift) * 3 : 1.0;
    _body.node.scale = vm.Vector3(2 - squash, squash, 2 - squash);
    for (var i = 0; i < _feet.length; i++) {
      final f = _feet[i];
      f.position = vm.Vector3(f.position.x, 0.2 + math.max(0, i > 0 ? -m.step : m.step) * 0.07, 0.05);
    }
    // Its light flashes through the colours like a disco ball.
    final disco = HSLColor.fromAHSL(1, (t * 1.3) % 1 * 360, 1, 0.5).toColor();
    setToonColor(_bulb, disco);
    setEmissive(_bulb, disco, 0.5);
    _bulbMesh.scale = vm.Vector3.all(1 + math.sin(t * 12).abs() * 0.3);
    _blink(dt);
    _body.apply();
    _armL.apply();
    _armR.apply();
    _bubble?.offset = vm.Vector3(0, (_bubbleIsCard ? 1.74 : 1.95) + m.lift + math.sin(t * 3) * 0.03, 0);
    _nameTag?.offset = vm.Vector3(0, 1.55 + m.lift, 0);
  }

  /// Back in its seat, standing straight, its light showing its status again.
  void _settle() {
    root.position = vm.Vector3.zero();
    root.rotation = vm.Quaternion.identity();
    _body.node.position = vm.Vector3.zero();
    _body
      ..x = 0
      ..y = 0
      ..z = 0
      ..apply();
    _body.node.scale = vm.Vector3.all(1);
    for (final a in [_armL, _armR]) {
      a
        ..z = 0
        ..apply();
    }
    for (final f in _feet) {
      f.position = vm.Vector3(f.position.x, 0.2, 0.05);
    }
    _bulbMesh.scale = vm.Vector3.all(1);
    _paintBulb();
  }

  /// [lid] narrows the eyes (1 = wide open) between blinks.
  void _blink(double dt, [double lid = 1]) {
    _blinkAt -= dt;
    final blinking = _blinkAt < 0.12 && _blinkAt > 0;
    if (_blinkAt < 0) _blinkAt = 2 + _rng.nextDouble() * 4;
    for (final (e, z) in _eyes) {
      e.scale = vm.Vector3(1, blinking ? 0.1 : lid, z);
    }
  }

  /// Takes its labels down.
  void dispose() {
    _labels.remove(_bubble);
    _labels.remove(_nameTag);
    _bubble = _nameTag = null;
    _undress();
  }
}
