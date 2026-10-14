// Whoever's been blown out of a station's airlock (see office_shared's maps/airlock.dart and the floor's
// JailState, which keeps them as it keeps a dungeon's prisoners): each one adrift outside, off on a
// heading of its own and turning over as it goes, further off by the hour, and wasting away as it would
// in a cell: thinner, then dead, then bones. Only the latest are still to be seen; the ones from before
// them have drifted out of sight. One on its way to the airlock with Security isn't shown till it's
// blown out (see [Drifters.hold]). A port of features/workers/adrift.ts.

import 'dart:math' as math;

import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart' show JailState, Prisoner;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:flutter_scene/scene.dart' show Node;

import 'character.dart' show Worker;
import 'geo.dart' show euler;
import 'jail.dart' show wastingOf;
import 'labels.dart';
import 'world.dart' show AirlockSite;

/// How often (s) how far gone they are is worked out again: it changes over hours.
const double _refresh = 2;

/// A worker's middle is this far above its feet: what it turns about, out there.
const double _middle = 0.45;

/// How big they are: as they were at their seats.
const double adriftScale = 0.82;

/// What they say, now and then, while there's breath in them and you're near enough to see.
const List<String> _mutters = [
  '🥶 so cold…',
  '👋 hello? anyone?',
  '🫁 …air?',
  '🌍 nice view, though',
  '😩 I can fix it, I swear',
  '📡 mayday… mayday…',
  '🧑‍🚀 should’ve worn a suit',
  '😵 …',
  '🎵 ground control to…',
  '📜 I’ll write the tests!',
];
const double _earshot = 34;

final math.Random _rng = math.Random();

/// Puts [root] (a worker, [scale] big) where [d] has it: its middle there, turned over the way it has
/// tumbled (or turned [q]).
void float(Node root, Drift d, double scale, [vm.Quaternion? q]) {
  final turn = q ?? euler(d.rx, d.ry, d.rz);
  root.rotation = turn;
  root.scale = vm.Vector3.all(scale);
  final up = turn.rotated(vm.Vector3(0, _middle * scale, 0));
  root.position = vm.Vector3(d.x - up.x, d.y - up.y, d.z - up.z);
}

class _Drifter {
  _Drifter(this.prisoner, this.model);
  final Prisoner prisoner;
  final Worker model;
}

class Drifters {
  Drifters(this._state, this._now, this._dress, this._labels);

  /// Who's been kept on the floor you're on.
  final JailState Function() _state;

  /// The office's clock (ms).
  final num Function() _now;

  /// How to dress one: the map's outfit, and how worn out it had got working.
  final void Function(Worker model, Prisoner p) _dress;
  final LabelHub _labels;

  final Map<String, _Drifter> _out = {};

  /// On their way to the airlock: not out there yet.
  final Set<String> _held = {};
  AirlockSite? _lock;
  SendHomePlan? _plan;
  double _refreshIn = 0;
  double _mutterIn = 6;

  /// Shows whoever's been kept adrift outside [lock] (nobody, without one), as far gone as [plan] says they are.
  void sync(AirlockSite? lock, SendHomePlan? plan) {
    if (!identical(lock, _lock) || !identical(plan, _plan)) {
      clear();
      _lock = lock;
      _plan = plan;
    }
    if (lock == null || plan == null) return;
    final prisoners = _state().prisoners;
    final want = {
      for (final p in prisoners.skip(adriftFrom(prisoners.length)))
        if (!_held.contains(p.id)) p.id: p,
    };
    for (final id in _out.keys.toList()) {
      if (want[id]?.at == _out[id]!.prisoner.at) continue;
      _drop(_out.remove(id)!);
    }
    for (final e in want.entries) {
      if (_out.containsKey(e.key)) continue;
      final p = e.value;
      final model = Worker(p.name, p.color, _labels);
      _dress(model, p);
      model.setJailed(wastingOf(p.at, _now(), plan));
      float(model.root, adrift(lock.plan, e.key, _now() - p.at), adriftScale);
      lock.outside.add(model.root);
      _out[e.key] = _Drifter(p, model);
    }
  }

  /// [id] is on its way to the airlock: not out there till it's blown out ([release]).
  void hold(String id) {
    _held.add(id);
    final d = _out.remove(id);
    if (d != null) _drop(d);
  }

  /// [id] has been blown out: it's adrift from now on.
  void release(String id) {
    if (!_held.remove(id)) return;
    sync(_lock, _plan);
  }

  /// Where [id] is out there by now (or would be, while it's still on its way to the airlock), if it's one
  /// that's kept.
  Drift? where(String id) {
    final p = _state().prisoners.where((q) => q.id == id).firstOrNull;
    final lock = _lock;
    return p != null && lock != null ? adrift(lock.plan, id, _now() - p.at) : null;
  }

  /// How many are out there to be seen.
  int get count => _out.length;

  /// Every frame: where each has got to; every so often, how far gone they are; and, from near enough,
  /// what they have to say about it.
  void update(double dt, double t, vm.Vector3 eye) {
    final lock = _lock, plan = _plan;
    if (lock == null || plan == null || _out.isEmpty) return;
    final now = _now();
    _refreshIn -= dt;
    final refresh = _refreshIn <= 0;
    if (refresh) _refreshIn = _refresh;
    for (final e in _out.entries) {
      final d = e.value;
      if (refresh) d.model.setJailed(wastingOf(d.prisoner.at, now, plan));
      d.model.update(dt, t);
      float(d.model.root, adrift(lock.plan, e.key, now - d.prisoner.at), adriftScale);
    }
    _mutterIn -= dt;
    if (_mutterIn > 0) return;
    _mutterIn = 6 + _rng.nextDouble() * 8;
    final near = [
      for (final d in _out.values)
        if (d.model.root.position.distanceTo(eye) < _earshot && !wastingOf(d.prisoner.at, now, plan).dead) d,
    ];
    if (near.isNotEmpty) near[_rng.nextInt(near.length)].model.mutter(_mutters[_rng.nextInt(_mutters.length)]);
  }

  /// Nobody's out there (off to another floor, or another map). Whoever was on their way to the airlock is
  /// let go too.
  void clear() {
    for (final d in _out.values) {
      _drop(d);
    }
    _out.clear();
    _held.clear();
  }

  void _drop(_Drifter d) {
    d.model.root.detach();
    d.model.dispose();
  }
}
