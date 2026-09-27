// The gong: a brass disc hung in a red lacquered frame, next to the PR board. It rings when a pull
// request merges, and anyone can walk up and hit it.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' as lay;
import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';

const _brassHex = '#e9b949';
const _lacquer = '#b23a48';
const _ink = '#2b2d42';

class Gong {
  Gong._(this.group, this.colliders, this.interactable, this.top, this._pivot, this._disc, this._brass, this._wave, this._waveMat);

  final Node group;
  final List<Collider> colliders;

  /// Walk up and press E.
  final Interactable interactable;

  /// Where confetti bursts from when there's no desk to burst over: just above the frame.
  final vm.Vector3 top;

  final Node _pivot;
  final Node _disc;
  final PreprocessedMaterial _brass;
  final Node _wave;
  final UnlitMaterial _waveMat;

  double _swing = 0;
  double _phase = 0;
  double _glow = 0;
  double _waveT = double.infinity;
  double _waveSize = 1;

  /// Swings the disc and flashes it; [strength] 1 is a good whack.
  void strike([double strength = 1]) {
    // Hit from the front, it swings back towards the wall first.
    _swing = math.min(0.3, _swing * 0.5 + 0.16 * strength);
    _phase = 0;
    _glow = math.min(1, 0.6 + 0.3 * strength);
    _waveT = 0;
    _waveSize = 1 + strength;
  }

  void update(double dt) {
    if (_swing > 0.001) {
      _phase += dt * math.pi * 2 * 0.85;
      _swing *= math.exp(-dt * 0.9);
      _pivot.rotation = euler(_swing * math.sin(_phase));
      // The metal shivers while it rings.
      _disc.position = vm.Vector3(0, -_drop, math.sin(_phase * 40) * 0.012 * _glow);
      _disc.rotation = euler(0, 0, _swing * 0.35 * math.sin(_phase * 1.6));
    } else if (_swing != 0) {
      _swing = 0;
      _pivot.rotation = vm.Quaternion.identity();
      _disc.rotation = vm.Quaternion.identity();
      _disc.position = vm.Vector3(0, -_drop, 0);
    }
    _glow *= math.exp(-dt * 2.5);
    setEmissive(_brass, hex('#ffb703'), _glow * 0.55);
    _waveT += dt;
    _wave.visible = _waveT < 0.9;
    if (_wave.visible) {
      _wave.scale = vm.Vector3.all(1 + _waveT * 2.2 * _waveSize);
      _waveMat.baseColorFactor = linear(hex('#ffe08a'), 0.55 * (1 - _waveT / 0.9));
    }
  }
}

const double _r = 0.62;
const double _drop = 1.02;

Gong buildGong() {
  const x = lay.Gong.x, z = lay.Gong.z, width = lay.Gong.width, height = lay.Gong.height;
  final group = Node(name: 'gong');
  group.position = vm.Vector3(x, 0, z);
  final lacquer = tc(_lacquer);
  final ink = tc(_ink);
  const half = width / 2;
  // The frame and the mallet never move: merged at the end.
  final stat = Node(name: 'frame');

  // The frame: two posts on feet, a beam across the top with its ends turned up, a rail below it.
  for (final sx in [-half, half]) {
    stat.add(mesh(cyl(0.07, 0.08, height, 10), lacquer, sx, height / 2, 0));
    stat.add(mesh(roundedBox(0.2, 0.12, 0.6, 0.04), ink, sx, 0.06, 0));
    stat.add(mesh(sphere(0.09, 10, 8), tc(_brassHex), sx, height + 0.08, 0, false));
  }
  stat.add(mesh(roundedBox(width + 0.5, 0.16, 0.18, 0.05), lacquer, 0, height - 0.08, 0));
  for (final sx in [-1, 1]) {
    stat.add(place(mesh(roundedBox(0.3, 0.1, 0.18, 0.04), lacquer, 0, 0, 0, false), x: sx * (half + 0.33), y: height + 0.02, rot: euler(0, 0, sx * 0.45)));
  }
  stat.add(mesh(box(width, 0.07, 0.08), ink, 0, height - 0.32, 0, false));
  group.add(place(textPlane('🎉 Merge gong', const TextOpts(bg: '#fffaf3', size: 48)), y: height - 0.08, z: 0.1, scale: 0.5));

  // The disc hangs on two cords from a pivot under the beam, so it can swing when it's hit.
  final pivot = Node(name: 'pivot')..position = vm.Vector3(0, height - 0.34, 0);
  group.add(pivot);
  final brass = toonUnique(hex(_brassHex));
  final disc = Node(name: 'disc')..position = vm.Vector3(0, -_drop, 0);
  pivot.add(disc);
  disc.add(mesh(transformed(cyl(_r, _r, 0.05, 40), rotX(math.pi / 2)), brass, 0, 0, 0));
  disc.add(mesh(torusXY(_r, 0.04, 8, 40), brass, 0, 0, 0, false));
  disc.add(mesh(torusXY(_r * 0.55, 0.018, 6, 32), tc('#c9952c'), 0, 0, 0.03, false));
  disc.add(place(mesh(sphere(0.16, 16, 12), brass, 0, 0, 0, false), z: 0.02, scale3: vm.Vector3(1, 1, 0.45)));
  for (final sx in [-1, 1]) {
    final cord = mesh(cyl(0.012, 0.012, _drop - _r + 0.08, 5), ink, 0, 0, 0, false);
    pivot.add(place(cord, x: sx * 0.22, y: -(_drop - _r) / 2, rot: euler(0, 0, sx * 0.2)));
  }

  // The mallet leans against the right post.
  final mallet = Node(name: 'mallet');
  mallet.add(mesh(cyl(0.025, 0.025, 0.9, 6), tc('#8a5a3b'), 0, 0.45, 0, false));
  mallet.add(mesh(sphere(0.1, 12, 10), tc('#ef476f'), 0, 0.92, 0, false));
  stat.add(place(mallet, x: half + 0.18, z: 0.12, rot: euler(0, 0, 0.22)));

  // A ring of sound spreading out from the disc when it's struck.
  final waveMat = seeThrough('#ffe08a', 0);
  const waveY = height - 0.34 - _drop;
  final wave = mesh(ringXY(_r * 0.95, _r * 1.08, 40, true), waveMat, 0, waveY, 0.08, false)..visible = false;
  group.add(wave);

  group.add(mergeByMaterial(stat));
  final interactable = Interactable(kind: InteractKind.gong, x: x, z: z + 1.3, radius: 1.5);
  tagInteract(group, interactable);
  return Gong._(group, gongColliders(), interactable, vm.Vector3(x, height + 0.4, z + 0.3), pivot, disc, brass, wave, waveMat);
}
