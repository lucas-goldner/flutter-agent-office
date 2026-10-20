// The build tower: a small server rack against the south wall, between the balcony doors and the
// stairs, for the floor's Codemagic builds (ui/codemagic_window.dart). A stack light on top says how
// they go: yellow and turning while one runs, green when the last one finished, red when it failed;
// and a light on each of the rack's four slots for the last four builds. Press E at it for the builds.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/codemagic.dart';
import 'package:office_shared/layout.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'parts.dart';

Collider buildTowerCollider() => Collider(
  minX: BuildTower.x - BuildTower.width / 2 - 0.04,
  maxX: BuildTower.x + BuildTower.width / 2 + 0.04,
  minZ: BuildTower.z - BuildTower.depth / 2 - 0.03,
  maxZ: Floor.maxZ,
  top: BuildTower.top,
);

/// Which tier of the stack light is on, and whether it flashes.
enum TowerLight { off, green, yellow, red }

/// The stack light for the floor's builds: yellow while any runs, else the newest one's end.
TowerLight towerLight(CodemagicState s) {
  if (s.builds.isEmpty) return TowerLight.off;
  if (s.running.isNotEmpty) return TowerLight.yellow;
  final last = s.builds.first.status;
  return last.bad ? TowerLight.red : (last == CodemagicStatus.finished ? TowerLight.green : TowerLight.off);
}

class BuildTowerView {
  BuildTowerView._(this.group, this.interactable, this._tiers, this._slots, this._beacon);

  final Node group;

  /// Walk up and press E: the builds window.
  final Interactable interactable;

  final Map<TowerLight, PreprocessedMaterial> _tiers;
  final List<PreprocessedMaterial> _slots;
  final Node _beacon;

  CodemagicState _state = const CodemagicState();
  double _t = 0;

  /// The floor's builds changed.
  void show(CodemagicState s) => _state = s;

  void update(double dt) {
    _t += dt;
    final on = towerLight(_state);
    for (final e in _tiers.entries) {
      final lit = e.key == on && (on != TowerLight.red || (_t % 1.0) < 0.6);
      setEmissive(e.value, _tierColor[e.key]!, lit ? 1.4 : 0.0);
    }
    // A turning beacon inside the yellow tier while a build runs.
    _beacon.visible = on == TowerLight.yellow;
    _beacon.rotation = yaw(_t * 5);
    final builds = _state.builds;
    for (var i = 0; i < _slots.length; i++) {
      final b = i < builds.length ? builds[i] : null;
      final s = b?.status;
      final color = s == null
          ? '#1b1d2e'
          : s.bad
          ? '#ff3b30'
          : s == CodemagicStatus.finished
          ? '#06d6a0'
          : '#ffd166';
      final blink = s != null && !s.done && ((_t + i * 0.3) % 0.9) < 0.45;
      setEmissive(_slots[i], hex(color), s == null ? 0 : (s.done || blink ? 1.0 : 0.3));
    }
  }
}

const _tierDim = {
  TowerLight.green: Color(0xFF145C4A),
  TowerLight.yellow: Color(0xFF7A6326),
  TowerLight.red: Color(0xFF6E2420),
};

const _tierColor = {
  TowerLight.green: Color(0xFF06D6A0),
  TowerLight.yellow: Color(0xFFFFD166),
  TowerLight.red: Color(0xFFFF3B30),
};

BuildTowerView buildBuildTower() {
  const w = BuildTower.width, d = BuildTower.depth, h = BuildTower.height;
  final group = Node(name: 'build-tower')..position = vm.Vector3(BuildTower.x, 0, BuildTower.z);
  // Built facing +z, then turned to face into the room (-z).
  final rack = Node(name: 'build-rack')..rotation = yaw(math.pi);
  final stat = Node(name: 'build-rack-parts');
  final body = tc('#2b2d42');
  final panel = tc('#3d405b');
  final steel = tc('#8d99ae');

  // The rack: a dark cabinet on little feet, four slots on its front, vents down its sides.
  stat.add(mesh(roundedBox(w, h - 0.04, d, 0.03), body, 0, 0.04 + (h - 0.04) / 2, 0));
  for (final sx in [-1, 1]) {
    for (final sz in [-1, 1]) {
      stat.add(mesh(box(0.06, 0.04, 0.06), steel, sx * (w / 2 - 0.06), 0.02, sz * (d / 2 - 0.06), false));
    }
    for (var i = 0; i < 6; i++) {
      stat.add(mesh(box(0.004, 0.02, d - 0.12), panel, sx * (w / 2 + 0.001), 0.35 + i * 0.12, 0, false));
    }
  }
  final slots = <PreprocessedMaterial>[];
  for (var i = 0; i < 4; i++) {
    final y = 0.3 + i * 0.22;
    stat.add(mesh(roundedBox(w - 0.1, 0.17, 0.02, 0.01), panel, 0, y, d / 2 + 0.005, false));
    // Little grille lines on each slot, and its light on the right.
    for (var k = 0; k < 4; k++) {
      stat.add(mesh(box(0.22, 0.008, 0.004), body, -0.08, y - 0.045 + k * 0.03, d / 2 + 0.017, false));
    }
    final m = toonUnique(hex('#1b1d2e'), emissive: hex('#1b1d2e'));
    slots.add(m);
    rack.add(mesh(sphere(0.022, 10, 8), m, w / 2 - 0.12, y, d / 2 + 0.02, false));
  }

  // The stack light: a pole, then green, yellow and red tiers, and a cap.
  stat.add(mesh(cyl(0.02, 0.02, 0.14, 8), steel, 0, h + 0.07, 0, false));
  final tiers = <TowerLight, PreprocessedMaterial>{};
  const tierH = 0.12;
  var y = h + 0.14 + tierH / 2;
  for (final t in [TowerLight.green, TowerLight.yellow, TowerLight.red]) {
    // Dim when off (a lens with no lamp behind it); lit, the lamp's glow comes on top.
    final m = toonUnique(_tierDim[t]!, emissive: _tierColor[t]!);
    tiers[t] = m;
    rack.add(mesh(cyl(0.065, 0.065, tierH - 0.008, 18), m, 0, y, 0, false));
    stat.add(mesh(cyl(0.068, 0.068, 0.008, 18), body, 0, y + tierH / 2, 0, false));
    y += tierH;
  }
  stat.add(mesh(cyl(0.05, 0.068, 0.04, 18), body, 0, y + 0.01, 0, false));
  // The beacon: a bright fin turning inside the yellow tier while a build runs.
  final beacon = Node(name: 'beacon')..position = vm.Vector3(0, h + 0.14 + tierH * 1.5, 0);
  beacon.add(mesh(box(0.11, 0.07, 0.012), tc('#fffaf3', emissive: '#ffd166'), 0, 0, 0, false));
  beacon.visible = false;
  rack.add(beacon);

  rack.add(mergeByMaterial(stat));
  group.add(rack);
  // Its label, on the front of the rack near the top (the wall behind it is a window).
  rack.add(
    place(
      textPlane('🏗️ Builds', const TextOpts(bg: '#fffaf3', size: 44)),
      y: h - 0.13,
      z: d / 2 + 0.012,
      scale: 0.28,
    ),
  );

  final it = Interactable(kind: InteractKind.build, x: BuildTower.x, z: BuildTower.z - 0.95, radius: 0.85);
  tagInteract(rack, it);
  return BuildTowerView._(group, it, tiers, slots, beacon);
}
