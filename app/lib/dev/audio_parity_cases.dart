// The cases of the desktop app's sound parity check (lib/dev/audio_parity.dart renders them with Web
// Audio, test/audio/parity_test.dart with the Dart synth): how long each renders, and where you
// stand: a metre and a half west of the sound, facing north, so it's on your right.

import 'package:office_shared/layout.dart' show Cabinet;

import '../audio/sound_model.dart';

/// Where the dog, the ball and the drink are put for the check.
const Pos parityNear = Pos(0, 0.5, -2);

SoundListener _westOf(Pos p) => SoundListener(x: p.x - 1.5, y: p.y, z: p.z, fx: 0, fz: -1);

/// Name → (seconds, where you stand).
final Map<String, (double, SoundListener)> parityCases = {
  'room': (4, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'ding.done': (0.45, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'ding.needsInput': (0.6, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'gong.merged': (8, _westOf(gongAt)),
  'gong.hit': (8, _westOf(gongAt)),
  'gong.queue': (10, _westOf(gongAt)),
  'coffee': (7, _westOf(coffeeMachine)),
  'bark3': (1.2, _westOf(parityNear)),
  'yip': (0.15, _westOf(parityNear)),
  'steps6': (0.3, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'stepAt': (0.3, _westOf(const Pos(0, 0.1, -2))),
  'thunder': (7, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'pour': (1.6, _westOf(const Pos(0, 1, -2))),
  'hiccup': (0.2, const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1)),
  'arcade.clear3': (0.45, _westOf(const Pos(Cabinet.x, 1.4, Cabinet.z))),
  'arcade.over': (0.8, _westOf(const Pos(Cabinet.x, 1.4, Cabinet.z))),
  'ball.bounce': (0.25, _westOf(const Pos(0, 1, -2))),
  'ball.score': (0.45, _westOf(const Pos(0, 1, -2))),
};
