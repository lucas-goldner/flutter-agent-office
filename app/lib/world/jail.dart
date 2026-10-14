// Whoever's locked up in the dungeon (see office_shared's maps/dungeon.dart and the floor's JailState):
// each one sat in its cell where it was thrown, thinner the longer it's been there, then dead, keeled
// over and rotting down to its bones. Once every seat in every cell has been taken, the ones from before
// are a heap of bones in the corner. One on its way down there with the Kingsguard isn't shown till it's
// thrown in (see [Jail.hold]). A port of features/workers/jail.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart' show JailState, Prisoner;
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show Worker;
import 'geo.dart';
import 'labels.dart';
import 'toon.dart';
import 'worker_jail.dart' show Jailed;
import 'world.dart' show DungeonSite;

/// How often (s) how far gone they are is worked out again: it changes over hours.
const double _refresh = 2;

/// What they mutter, now and then, while you're down there with them.
const List<String> _mutters = [
  '🍞 …bread?',
  '💧 water…',
  '🙏 let me out',
  '😩 I can fix it, I swear',
  '🐀 hello, rat',
  '🥶 so cold…',
  '📜 I’ll write the tests!',
  '😵 …',
  '🎵 99 bugs in the code…',
  '🕯️ is it day?',
  '😢 I miss my desk',
  '🔑 psst… the key?',
];

/// How close (m) you have to be to hear one.
const double _earshot = 9;

final math.Random _rng = math.Random();

/// How far gone someone locked up at [at] is by [now], on a map that keeps them as [plan] says.
Jailed wastingOf(int at, num now, SendHomePlan plan) => wasting(at, now, starveMs: plan.starveMs, rotMs: plan.rotMs);

class _Inmate {
  _Inmate(this.prisoner, this.model, this.seat);
  final Prisoner prisoner;
  final Worker model;
  final CellSeat seat;
}

/// A heap of [n] skulls and bones: the more, the bigger the heap.
Node boneHeap(int n) {
  final g = Node(name: 'ossuary');
  final shown = math.min(60, n);
  var seed = 7;
  double rand() => (seed = (seed * 16807) % 2147483647) / 2147483647;
  final radius = 0.35 + 0.12 * math.sqrt(shown);
  final bone = toon(hex('#e3dac0')), socket = toon(hex('#241c16'));
  for (var i = 0; i < shown; i++) {
    // Piled in a cone: the first at the bottom and out to the edge, the later ones on top.
    final k = i / math.max(1, shown - 1);
    final r = radius * (1 - k) * math.sqrt(rand());
    final a = rand() * math.pi * 2;
    final y = 0.1 + k * radius * 0.9;
    final skull = Node(name: 'skull')..add(mesh(sphere(0.13, 10, 8), bone));
    for (final sx in const [-1, 1]) {
      skull.add(mesh(sphere(0.035, 6, 5), socket, sx * 0.05, 0.02, 0.11, false));
    }
    skull
      ..position = vm.Vector3(math.cos(a) * r, y, math.sin(a) * r)
      ..rotation = euler((rand() - 0.5) * 0.8, rand() * math.pi * 2, (rand() - 0.5) * 0.8);
    g.add(skull);
    if (i.isEven) {
      g.add(
        mesh(capsule(0.03, 0.4, 3, 6), bone, math.cos(a + 1) * r * 0.8, y - 0.02, math.sin(a + 1) * r * 0.8)
          ..rotation = euler(math.pi / 2 + (rand() - 0.5), rand() * math.pi),
      );
    }
  }
  return g;
}

class Jail {
  Jail(this._state, this._now, this._dress, this._labels);

  /// Who's locked up on the floor you're on.
  final JailState Function() _state;

  /// The office's clock (ms).
  final num Function() _now;

  /// How to dress one: the map's outfit, and how worn out it had got working.
  final void Function(Worker model, Prisoner p) _dress;
  final LabelHub _labels;

  final Map<String, _Inmate> _inmates = {};

  /// On their way down with the Kingsguard: not in their cells yet.
  final Set<String> _held = {};
  DungeonSite? _dungeon;
  SendHomePlan? _plan;
  ({Node group, int n})? _heap;
  double _refreshIn = 0;
  double _mutterIn = 5;

  /// Shows the floor's prisoners in [dungeon]'s cells (none, without one), as far gone as [plan] says they are.
  void sync(DungeonSite? dungeon, SendHomePlan? plan) {
    if (!identical(dungeon, _dungeon) || !identical(plan, _plan)) {
      clear();
      _dungeon = dungeon;
      _plan = plan;
    }
    final state = _state();
    final d = dungeon?.plan;
    if (dungeon == null || d == null || plan == null) return;
    final total = state.bones + state.prisoners.length;
    final want = <String, ({Prisoner prisoner, CellSeat seat})>{};
    var heaped = state.bones;
    for (var i = 0; i < state.prisoners.length; i++) {
      final p = state.prisoners[i];
      final seat = prisonSeat(d, state.bones + i, total);
      if (seat == null) {
        heaped++;
      } else if (!_held.contains(p.id)) {
        want[p.id] = (prisoner: p, seat: seat);
      }
    }
    for (final id in _inmates.keys.toList()) {
      final m = _inmates[id]!;
      final w = want[id];
      if (w != null && w.prisoner.at == m.prisoner.at && w.seat == m.seat) continue;
      _drop(m);
      _inmates.remove(id);
    }
    for (final e in want.entries) {
      if (_inmates.containsKey(e.key)) continue;
      final w = e.value;
      final model = Worker(w.prisoner.name, w.prisoner.color, _labels);
      _dress(model, w.prisoner);
      final spot = w.seat.spot;
      model.root
        ..position = vm.Vector3(spot.x, spot.y, spot.z)
        ..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), spot.rotY);
      model.setJailed(wastingOf(w.prisoner.at, _now(), plan));
      dungeon.inside.add(model.root);
      _inmates[e.key] = _Inmate(w.prisoner, model, w.seat);
    }
    _pile(d, heaped);
  }

  /// [id] is on its way down (being marched off by the escort): not in its cell till it's thrown in ([release]).
  void hold(String id) {
    _held.add(id);
    final m = _inmates.remove(id);
    if (m != null) _drop(m);
  }

  /// [id] has been thrown in: it's in its cell from now on.
  void release(String id) {
    if (!_held.remove(id)) return;
    sync(_dungeon, _plan);
  }

  /// Where [id] sits, once it's locked up: which cell, and where in it.
  CellSeat? seatOf(String id) {
    final d = _dungeon?.plan;
    final s = _state();
    final i = s.prisoners.indexWhere((p) => p.id == id);
    if (d == null || i < 0) return null;
    return prisonSeat(d, s.bones + i, s.bones + s.prisoners.length);
  }

  /// How many are down there.
  int get count => _inmates.length;

  /// Every so often, how far gone they are; and, while you're down there, their moaning. [eye] is where
  /// you're looking from.
  void update(double dt, double t, vm.Vector3 eye) {
    final dungeon = _dungeon, plan = _plan;
    if (dungeon == null || plan == null || _inmates.isEmpty) return;
    _refreshIn -= dt;
    if (_refreshIn <= 0) {
      _refreshIn = _refresh;
      final now = _now();
      for (final m in _inmates.values) {
        m.model.setJailed(wastingOf(m.prisoner.at, now, plan));
      }
    }
    // Nobody down there to see them: they needn't move.
    if (!dungeon.inside.visible) return;
    for (final m in _inmates.values) {
      m.model.update(dt, t);
    }
    final below = eye.y < dungeon.plan.ceiling;
    _mutterIn -= dt;
    if (below && _mutterIn <= 0) {
      _mutterIn = 5 + _rng.nextDouble() * 7;
      final near = [
        for (final m in _inmates.values)
          if (math.sqrt(math.pow(m.seat.spot.x - eye.x, 2) + math.pow(m.seat.spot.z - eye.z, 2)) < _earshot &&
              !wastingOf(m.prisoner.at, _now(), plan).dead)
            m,
      ];
      if (near.isNotEmpty) near[_rng.nextInt(near.length)].model.mutter(_mutters[_rng.nextInt(_mutters.length)]);
    }
  }

  /// Everyone out of the cells (off to another floor, or another map). Whoever was on their way down is let go too.
  void clear() {
    for (final m in _inmates.values) {
      _drop(m);
    }
    _inmates.clear();
    _held.clear();
    _heap?.group.detach();
    _heap = null;
  }

  /// The heap of bones, [n] of them, where the dungeon has one.
  void _pile(DungeonPlan d, int n) {
    final size = n <= 0 ? 0 : math.min(60, n);
    if ((_heap?.n ?? 0) == size) return;
    _heap?.group.detach();
    _heap = null;
    final at = d.ossuary;
    final dungeon = _dungeon;
    if (size == 0 || at == null || dungeon == null) return;
    final group = boneHeap(size)..position = vm.Vector3(at.$1, d.floor, at.$2);
    dungeon.inside.add(group);
    _heap = (group: group, n: size);
  }

  void _drop(_Inmate m) {
    m.model.root.detach();
    m.model.dispose();
  }
}
