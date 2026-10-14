// The castle's workers getting up and walking about the hall (see MapPlan.lineup). One waiting on
// someone (done, or stuck on a question) gets up from its seat and joins the line in front of the
// throne, first come first served, shuffling forward as the ones ahead are seen to, and goes back to
// its seat once it has been. A new one runs in from wherever it was sent out from (the herald by the
// throne, or the doors) to its seat. While it's up, its seat is empty but still its own, and the spot
// it stands in is somewhere to walk up to it ([interactables]), as good as its seat. A port of
// world/court.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan;
import 'package:office_shared/nav.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show Worker;
import 'collider.dart';
import 'office/office.dart' show DeskView;

/// Walking pace (m/s), and running, for a new worker sent out to its seat.
const double _walk = 2.6;
const double _run = 4;

/// Seconds hopping down off its seat, or up onto it.
const double _hop = 0.5;

/// A worker's feet are this far above its origin (see leaving.dart).
const double _feet = 0.07;

/// Where it's going: its seat (null), or a spot in line (its index).
typedef _Goal = int?;

enum _State { seated, down, walk, up, stand }

class _Courtier {
  _Courtier(this.id, this.model, this.desk);
  final String id;
  final Worker model;
  final DeskView desk;
  _Goal goal;
  _State state = _State.seated;
  List<Pt> way = const [];
  int next = 0;

  /// Seconds into a hop, and where it hopped from.
  double hop = 0;
  vm.Vector3 from = vm.Vector3.zero();
  double heading = 0;
  double stepIn = 0;

  /// m/s, before its age slows it down.
  double pace = _walk;

  /// Where it is and which way it faces, in the hall's space (its root's, once it's up).
  vm.Vector3 pos = vm.Vector3.zero();
  double yaw = 0;
}

double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
double _lerp(double a, double b, double t) => a + (b - a) * t;

/// The heading of a transform: which way its +z points, round y.
double yawOf(vm.Matrix4 m) {
  final f = m.rotated3(vm.Vector3(0, 0, 1));
  return math.atan2(f.x, f.z);
}

class Court {
  Court(this._parent, this._plan, this._nav, this._ground, this._footstep)
    : interactables = [
        for (final s in _plan.lineup) Interactable(kind: InteractKind.desk, x: s.x, z: s.z, radius: 1.3, off: true),
      ];

  final Node _parent;
  final MapPlan _plan;
  final NavGrid _nav;

  /// The top of whatever is underfoot at (x, z) for feet at `y`.
  final double Function(double x, double z, double y) _ground;
  final void Function(double x, double y, double z) _footstep;

  /// One for each spot in line: walk up to whoever stands there, as at its seat.
  final List<Interactable> interactables;
  final Map<String, _Courtier> _people = {};

  /// A worker sitting at [desk] now. [from] is where it comes in from, running to its seat, or null:
  /// it's in its seat already.
  void add(String id, Worker model, DeskView desk, [Pt? from]) {
    final c = _Courtier(id, model, desk);
    _people[id] = c;
    if (from == null) return;
    // Out into the hall where it comes in, then off to its seat at a run.
    _detach(c);
    final (x, z) = from;
    c.pos = vm.Vector3(x, _ground(x, z, 2) - _feet, z);
    _pose(c);
    c.pace = _run;
    // On its feet in the hall (not in its seat), so it sets off for it.
    c.state = _State.stand;
    _walkTo(c, null);
  }

  /// Stops walking [id] about (it's gone, or being sent home), leaving its model wherever it is. Where it
  /// stood, if it was up.
  Pt? release(String id) {
    final c = _people.remove(id);
    if (c == null) return null;
    c.model.walking = false;
    c.model.gait = 1;
    tagInteract(c.model.root, null);
    _freeSpots();
    if (c.state == _State.seated) return null;
    return (c.pos.x, c.pos.z);
  }

  /// Whether [id] is up out of its seat.
  bool away(String id) {
    final c = _people[id];
    return c != null && c.state != _State.seated;
  }

  /// Where [id] is in line, or on its way to (0 is at the front), or -1.
  int spotOf(String id) {
    final c = _people[id];
    return c != null && c.state != _State.seated && c.goal != null ? c.goal! : -1;
  }

  /// Who's waiting on someone, the one who's waited longest first: they line up in that order, as many as
  /// there are spots.
  void line(List<String> waiting) {
    final spots = _plan.lineup.length;
    final order = waiting.where(_people.containsKey).take(spots).toList();
    for (final c in _people.values) {
      final i = order.indexOf(c.id);
      final goal = i >= 0 ? i : null;
      if (goal == c.goal) continue;
      c.pace = _walk;
      _walkTo(c, goal);
    }
  }

  /// Everyone walking about, for the doors to open.
  List<vm.Vector3> positions() => [
    for (final c in _people.values)
      if (c.state != _State.seated) c.pos,
  ];

  void update(double dt) {
    for (final c in _people.values) {
      _step(c, dt);
    }
  }

  /// Each spot in line points at whoever's standing in it, and so does a click on them (the model carries
  /// its spot's interactable, as a desk's group does its own). Run whenever someone takes a spot or leaves one.
  void _freeSpots() {
    for (final it in interactables) {
      it.off = true;
      it.deskId = null;
    }
    for (final c in _people.values) {
      final spot = c.goal;
      final it = c.state == _State.stand && spot != null ? interactables[spot] : null;
      if (it != null) {
        it.off = false;
        it.deskId = c.desk.def.id;
      }
      tagInteract(c.model.root, it);
    }
  }

  void _pose(_Courtier c) {
    final root = c.model.root;
    root.position = c.pos.clone();
    root.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), c.yaw);
  }

  /// Out of its seat, into the hall, keeping where it is in the world.
  void _detach(_Courtier c) {
    final root = c.model.root;
    final local = vm.Matrix4.inverted(_parent.globalTransform) * root.globalTransform as vm.Matrix4;
    final scale = local.getColumn(0).xyz.length;
    root.parent?.remove(root);
    _parent.add(root);
    c.pos = local.getTranslation();
    // Upright, facing the way it was (as a heading, so turning from here never flips it round).
    c.heading = c.yaw = yawOf(local);
    root.scale = vm.Vector3.all(scale);
    _pose(c);
  }

  /// Where [desk]'s seat is in the hall's space.
  vm.Vector3 _seatAt(DeskView desk) =>
      (vm.Matrix4.inverted(_parent.globalTransform) * desk.seatAnchor.globalTransform as vm.Matrix4).getTranslation();

  /// Sets off for [goal] from wherever it is: down off its seat first if it's in it.
  void _walkTo(_Courtier c, _Goal goal) {
    c.goal = goal;
    c.model.stopDancing();
    final target = goal != null ? (_plan.lineup[goal].x, _plan.lineup[goal].z) : null;
    if (c.state == _State.seated) {
      if (target == null) return;
      _detach(c);
      c.way = _nav.wayFrom(c.desk.def, target);
      c.from = c.pos.clone();
      c.state = _State.down;
      c.hop = 0;
      c.next = 0;
      return;
    }
    final Pt here = (c.pos.x, c.pos.z);
    // Mid-hop onto its seat and wanted back in line: it finishes the hop, and gets straight down again.
    if (c.state == _State.up && target != null) {
      _seat(c);
      return _walkTo(c, goal);
    }
    // Still getting down: from where it lands, it heads the new way.
    if (c.state == _State.down) {
      final land = c.way[0];
      c.way = [land, ...(target != null ? _nav.route(land, target) : _nav.wayTo(land, c.desk.def)).skip(1)];
      return;
    }
    final left = c.state == _State.stand;
    c.way = target != null ? _nav.route(here, target) : _nav.wayTo(here, c.desk.def);
    c.next = 1;
    c.state = _State.walk;
    // Out of its spot in line: it's no longer there to walk up to.
    if (left) _freeSpots();
  }

  void _step(_Courtier c, double dt) {
    if (c.state == _State.seated) return;
    final pos = c.pos;
    if (c.state == _State.down) {
      // Down off the seat in a little arc, turning to face the way it's going.
      c.hop = math.min(1, c.hop + dt / _hop);
      final (x0, z0) = c.way[0];
      final floor = _ground(x0, z0, c.from.y + 0.5) - _feet;
      pos.setValues(
        _lerp(c.from.x, x0, c.hop),
        _lerp(c.from.y, floor, c.hop) + math.sin(c.hop * math.pi) * 0.3,
        _lerp(c.from.z, z0, c.hop),
      );
      final (x1, z1) = c.way.length > 1 ? c.way[1] : c.way[0];
      c.heading = math.atan2(x1 - x0, z1 - z0);
      c.yaw += _wrap(c.heading - c.yaw) * math.min(1, dt * 8);
      if (c.hop >= 1) {
        c.state = _State.walk;
        c.next = 1;
      }
      _pose(c);
      return;
    }
    if (c.state == _State.up) {
      // Up onto the seat in a little arc, turning to face the table.
      c.hop = math.min(1, c.hop + dt / _hop);
      final seat = _seatAt(c.desk);
      pos.setValues(
        _lerp(c.from.x, seat.x, c.hop),
        _lerp(c.from.y, seat.y, c.hop) + math.sin(c.hop * math.pi) * 0.3,
        _lerp(c.from.z, seat.z, c.hop),
      );
      c.yaw += _wrap(c.desk.def.rotY + math.pi - c.yaw) * math.min(1, dt * 9);
      if (c.hop >= 1) {
        _seat(c);
      } else {
        _pose(c);
      }
      return;
    }
    if (c.state == _State.walk) {
      var move = c.pace * c.model.pace * dt;
      while (move > 0 && c.next < c.way.length) {
        final (x, z) = c.way[c.next];
        final dx = x - pos.x, dz = z - pos.z;
        final d = math.sqrt(dx * dx + dz * dz);
        if (d > 1e-4) c.heading = math.atan2(dx, dz);
        if (d <= move) {
          pos.x = x;
          pos.z = z;
          move -= d;
          c.next++;
        } else {
          pos.x += dx / d * move;
          pos.z += dz / d * move;
          move = 0;
        }
      }
      c.model.walking = c.next < c.way.length;
      // Its feet go as fast as it does: quicker running, slower shuffling.
      c.model.gait = c.pace / _walk;
      if (c.model.walking) {
        c.stepIn -= dt;
        if (c.stepIn <= 0) {
          c.stepIn += math.pi / (9 * c.model.pace * c.model.gait);
          _footstep(pos.x, pos.y, pos.z);
        }
      } else if (c.goal == null) {
        // Beside its seat: up onto it.
        c.state = _State.up;
        c.hop = 0;
        c.from = pos.clone();
      } else {
        c.state = _State.stand;
        _freeSpots();
      }
    }
    // Up and down the dais steps as it goes, and facing the way it's walking, or the throne once it's in line.
    final g = _ground(pos.x, pos.z, pos.y + _feet + 0.35) - _feet;
    pos.y += (g - pos.y) * math.min(1, dt * 14);
    final spot = c.goal;
    final face = c.state == _State.stand && spot != null ? _plan.lineup[spot].rotY : c.heading;
    c.yaw += _wrap(face - c.yaw) * math.min(1, dt * 8);
    _pose(c);
  }

  /// Back in its seat: from here on it's where every worker sits.
  void _seat(_Courtier c) {
    final root = c.model.root;
    c.state = _State.seated;
    c.model.walking = false;
    c.model.gait = 1;
    c.pace = _walk;
    root.parent?.remove(root);
    c.desk.seatAnchor.add(root);
    root.position = vm.Vector3.zero();
    root.rotation = vm.Quaternion.identity();
    root.scale = vm.Vector3.all(1);
  }
}
