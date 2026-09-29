// The basketball hoop on every floor, and its ball (world/hoop.ts). The office keeps who has the ball
// and how it was last thrown; every page flies and bounces it the same way from that throw
// (office_shared hoop.dart), so everyone on the floor sees the same shot.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/hoop.dart';
import 'package:office_shared/layout.dart' show Floor;
import 'package:vector_math/vector_math.dart' as vm;

import 'collider.dart';
import 'office/geo.dart';
import 'office/parts.dart';
import 'toon.dart';

const _orange = '#ff6b1a';
const _ink = '#2b2d42';

/// The hoop's backboard and the arms holding it up, to walk (and jump) into.
List<Collider> hoopColliders() {
  const b = Hoop.board;
  final back = Hoop.face - b.thick;
  final midY = (b.bottom + b.top) / 2;
  return [
    Collider(
      minX: back,
      maxX: Hoop.face,
      minZ: Hoop.z - b.width / 2,
      maxZ: Hoop.z + b.width / 2,
      bottom: b.bottom,
      top: b.top,
    ),
    Collider(
      minX: Floor.minX,
      maxX: back,
      minZ: Hoop.z - 0.45,
      maxZ: Hoop.z + 0.45,
      bottom: midY - 0.8,
      top: midY + 0.3,
    ),
  ];
}

class HoopView {
  HoopView(this.group, this._net);

  final Node group;
  final Node _net;
  double _stretch = 0, _speed = 0;

  /// The net swings as a ball drops through it.
  void swish() => _speed -= 5;

  void update(double dt) {
    // A damped spring.
    _speed += (-60 * _stretch - 7 * _speed) * dt;
    _stretch += _speed * dt;
    _net.scale = vm.Vector3(1 + _stretch * 0.25, 1 - _stretch * 0.9, 1 + _stretch * 0.25);
  }
}

/// A half ring lying in XY facing +z, from -pi/2 round to pi/2 (out past the free-throw line).
Geometry _halfRing(double inner, double outer, int seg) {
  final p = <double>[];
  for (var i = 0; i < seg; i++) {
    final a0 = -math.pi / 2 + i / seg * math.pi, a1 = -math.pi / 2 + (i + 1) / seg * math.pi;
    final c0 = math.cos(a0), s0 = math.sin(a0), c1 = math.cos(a1), s1 = math.sin(a1);
    p.addAll([outer * c0, outer * s0, 0, outer * c1, outer * s1, 0, inner * c1, inner * s1, 0]);
    p.addAll([outer * c0, outer * s0, 0, inner * c1, inner * s1, 0, inner * c0, inner * s0, 0]);
  }
  return geometryFrom(Float32List.fromList(p));
}

/// The hoop on the west wall: a backboard on arms off the wall, an orange rim and a white net, over a
/// painted key on the floor with its free-throw circle.
HoopView buildHoop() {
  final group = Node(name: 'hoop');
  final parts = Node(name: 'hoop-parts');
  const z = Hoop.z, face = Hoop.face, board = Hoop.board, rim = Hoop.rim;
  final ink = tc(_ink);
  final back = face - board.thick;
  final midY = (board.bottom + board.top) / 2;

  // The board: white, with an orange border and the shooter's square over the rim.
  parts.add(
    mesh(box(board.thick, board.top - board.bottom, board.width), tc('#f8f9fa'), face - board.thick / 2, midY, z),
  );
  final orange = tc(_orange);
  void line(double w, double h, double y, double dz) =>
      parts.add(mesh(box(0.012, h, w), orange, face + 0.006, y, z + dz, false));
  const e = 0.05;
  line(board.width, e, board.top - e / 2, 0);
  line(board.width, e, board.bottom + e / 2, 0);
  for (final s in [-1, 1]) {
    line(e, board.top - board.bottom, midY, s * (board.width / 2 - e / 2));
  }
  final sq = (w: 0.59, h: 0.45, t: 0.035, y: rim.y + 0.02);
  line(sq.w, sq.t, sq.y + sq.t / 2, 0);
  line(sq.w, sq.t, sq.y + sq.h - sq.t / 2, 0);
  for (final s in [-1, 1]) {
    line(sq.t, sq.h, sq.y + sq.h / 2, s * (sq.w / 2 - sq.t / 2));
  }

  // Arms from a plate on the wall out to the back of the board, and a brace under them.
  parts.add(mesh(box(0.04, 0.8, 0.9), ink, Floor.minX + 0.02, midY - 0.15, z));
  final reach = back - Floor.minX;
  for (final dz in [-0.32, 0.32]) {
    for (final y in [midY - 0.25, midY + 0.25]) {
      parts.add(mesh(box(reach, 0.05, 0.05), ink, Floor.minX + reach / 2, y, z + dz));
    }
    parts.add(
      place(
        mesh(cyl(0.022, 0.022, math.sqrt(reach * reach + 0.55 * 0.55), 6), ink),
        x: Floor.minX + reach / 2,
        y: midY - 0.52,
        z: z + dz,
        rot: euler(0, 0, -math.atan2(reach, 0.55)),
      ),
    );
  }

  // The rim, and the bracket bolting it to the board.
  parts.add(
    place(mesh(torusXY(rim.r, rim.tube, 8, 36), orange), x: rim.x, y: rim.y, z: rim.z, rot: euler(math.pi / 2)),
  );
  final gap = rim.x - rim.r - face;
  parts.add(mesh(box(gap + 0.02, 0.03, 0.16), orange, face + gap / 2, rim.y - 0.01, z));
  parts.add(mesh(box(0.02, 0.16, 0.2), orange, face + 0.01, rim.y - 0.06, z, false));
  group.add(mergeByMaterial(parts));

  // The net: a see-through cone hanging from the rim, with a few hoops of cord round it.
  final net = Node(name: 'net');
  final cord = seeThrough('#ffffff', 0.55);
  net.add(mesh(cyl(rim.r - 0.01, Hoop.net.r, Hoop.net.depth, 14, true), cord, 0, -Hoop.net.depth / 2, 0, false));
  final white = tc('#ffffff');
  for (var i = 1; i <= 3; i++) {
    final k = i / 3;
    final r = rim.r - 0.01 + (Hoop.net.r - rim.r + 0.01) * k;
    net.add(
      place(mesh(torusXY(r, 0.006, 4, 20), white, 0, 0, 0, false), y: -Hoop.net.depth * k, rot: euler(math.pi / 2)),
    );
  }
  net.position = vm.Vector3(rim.x, rim.y, rim.z);
  group.add(net);

  // The key painted on the floor, out to the free-throw line, and the circle round the line.
  const lineX = face + Hoop.line;
  const keyW = 2.6;
  const keyLen = lineX - Floor.minX;
  final paint = Node(name: 'key');
  paint.add(mesh(groundPlane(keyLen, keyW), tc('#ee9a5d'), Floor.minX + keyLen / 2, 0.013, z, false));
  const w = 0.06;
  final stripe = tc('#ffffff');
  paint.add(mesh(groundPlane(keyLen, w), stripe, Floor.minX + keyLen / 2, 0.015, z - keyW / 2, false));
  paint.add(mesh(groundPlane(keyLen, w), stripe, Floor.minX + keyLen / 2, 0.015, z + keyW / 2, false));
  paint.add(mesh(groundPlane(w, keyW), stripe, lineX, 0.015, z, false));
  paint.add(
    place(
      mesh(_halfRing(keyW / 2 - w, keyW / 2, 40), stripe, 0, 0, 0, false),
      x: lineX,
      y: 0.015,
      z: z,
      rot: euler(-math.pi / 2),
    ),
  );
  group.add(mergeByMaterial(paint));
  return HoopView(group, net);
}

// ---- The ball ---------------------------------------------------------------------------------------

/// How a basket went in: who threw it, from how far, and whether it touched anything on the way.
class Basket {
  const Basket({
    required this.by,
    required this.distance,
    required this.swish,
    required this.bank,
    required this.three,
  });
  final String by;
  final double distance;
  final bool swish, bank, three;
}

/// Where the ball sits between someone's hands, in their character's own space (forward is +z).
final vm.Vector3 inHands = vm.Vector3(0, 0.95, 0.42);

/// The floor's basketball as everyone on the floor sees it, without the drawing: in someone's hands,
/// flying from a throw (worked out the same way on every page), or lying where it stopped. [set]
/// takes the office's word for it; [throwNow] is your own throw, before the office hears.
class BallTracker {
  BallTracker(this.solids);

  /// What it bounces off: the office's colliders, and the backboard.
  final List<Solid> Function() solids;

  /// Who has it (a peer id), or null while it's loose.
  String? holder;
  BallSim? _sim;
  BallShot? _shot;

  /// When (ms, [update]'s clock) the throw left their hands.
  double _t0 = 0;
  List<Solid> _solids = const [];

  /// The throw's end has been told about (a basket or a miss).
  bool _settled = false;

  /// Where it is now, when loose.
  final vm.Vector3 at = vm.Vector3(Ball.home.x, Ball.r, Ball.home.z);

  /// Seen at all: not lost out of the building.
  bool visible = true;

  void Function(BallHit hit, vm.Vector3 at)? onHit;

  /// Someone threw it (not you: yours you know about).
  void Function(String by)? onThrow;
  void Function(Basket b)? onBasket;

  /// A throw of `by`'s came to nothing: it stopped, or somebody took it, without going in.
  void Function(String by)? onMiss;

  /// Loose and not flying about any more.
  bool get still => holder == null && (_sim == null || _sim!.still);

  /// The office's word on where the ball is, as of [now] (ms).
  void set(BallState state, double now) {
    if (state.holder != null) {
      if (holder == state.holder) return;
      _endThrow();
      holder = state.holder;
      _sim = null;
      return;
    }
    holder = null;
    final s = state.shot;
    if (s == null) {
      _endThrow();
      _sim = null;
      return;
    }
    // A throw that's already flying here (your own, back from the office).
    final mine = _shot;
    if (mine != null && _same(mine, s)) return;
    _endThrow();
    _start(s, now - s.elapsed);
    final sim = _sim!;
    // Catch up with it quietly: what it hit before you saw it is over and done with.
    simulate(sim, (now - _t0) / 1000, _solids);
    if (sim.t < 0.3) onThrow?.call(s.by);
    _settled = sim.scored || sim.still || sim.lost;
  }

  /// You throw it (or drop it): it's out of your hands now, whatever the office says in a moment.
  void throwNow(BallThrow s, String by, double now) {
    _endThrow();
    holder = null;
    _start(BallShot(x: s.x, y: s.y, z: s.z, vx: s.vx, vy: s.vy, vz: s.vz, by: by, elapsed: 0), now);
  }

  /// You ([id]) take it, before the office says so.
  void takeNow(String id) {
    _endThrow();
    holder = id;
    _sim = null;
  }

  void _start(BallShot s, double t0) {
    _shot = s;
    _t0 = t0;
    _solids = nearSolids(solids());
    _sim = launchBall(s.throwAt);
    _settled = false;
  }

  /// A throw is over (someone took it, or threw again): if it hadn't gone in, that's a miss.
  void _endThrow() {
    final s = _shot;
    if (s != null && !_settled && !(_sim?.scored ?? false)) onMiss?.call(s.by);
    _settled = true;
    _shot = null;
  }

  /// Moves a loose ball on to [now] (ms).
  void update(double now) {
    if (holder != null) return;
    final s = _sim;
    if (s != null) {
      final hits = <BallHit>[];
      final was = s.scored;
      simulate(s, (now - _t0) / 1000, _solids, hits);
      at.setValues(s.x, s.y, s.z);
      for (final h in hits) {
        onHit?.call(h, at);
      }
      final shot = _shot;
      if (s.scored && !was && shot != null) {
        _settled = true;
        final distance = math.sqrt(math.pow(shot.x - Hoop.rim.x, 2) + math.pow(shot.z - Hoop.rim.z, 2));
        onBasket?.call(
          Basket(
            by: shot.by,
            distance: distance,
            swish: !s.touchedRim && !s.touchedBoard,
            bank: s.touchedBoard,
            three: distance > threePoint,
          ),
        );
      }
      final gone = s.lost || (s.still && outOfReach(s.x, s.y, s.z));
      if ((s.still || s.lost) && !_settled) {
        _settled = true;
        if (shot != null) onMiss?.call(shot.by);
      }
      // Out of reach (or out of the building) for a moment, it turns up back under the hoop.
      if (gone && (now - _t0) / 1000 > s.t + returnAfter) {
        _sim = null;
        _shot = null;
      }
      visible = !s.lost;
    }
    if (_sim == null) {
      at.setValues(Ball.home.x, Ball.r, Ball.home.z);
      visible = true;
    }
  }
}

bool _same(BallShot a, BallShot b) =>
    a.by == b.by && a.x == b.x && a.y == b.y && a.z == b.z && a.vx == b.vx && a.vy == b.vy && a.vz == b.vz;

/// The office's colliders as the ball meets them, with the backboard bouncing harder.
List<Solid> solidsOf(Iterable<Collider> colliders) => [
  for (final c in colliders)
    Solid(minX: c.minX, maxX: c.maxX, minZ: c.minZ, maxZ: c.maxZ, top: c.top, bottom: c.bottom),
  backboard(),
];

/// The floor's basketball in the room: a [BallTracker] and the ball you see.
class Basketball {
  Basketball(List<Solid> Function() solids) : tracker = BallTracker(solids) {
    final orange = tc('#e8742a');
    final seam = tc('#1d1d1d');
    const r = Ball.r;
    _ball.add(mesh(sphere(r, 20, 14), orange));
    // The seams: round its middle, and two over the top.
    _ball.add(mesh(torusXY(r + 0.001, 0.004, 4, 32), seam, 0, 0, 0, false));
    _ball.add(place(mesh(torusXY(r + 0.001, 0.004, 4, 32), seam, 0, 0, 0, false), rot: euler(math.pi / 2)));
    _ball.add(place(mesh(torusXY(r + 0.001, 0.004, 4, 32), seam, 0, 0, 0, false), rot: euler(0, math.pi / 2)));
    node.add(_ball);
    node.position = tracker.at.clone();
    tagInteract(node, interactable);
  }

  final BallTracker tracker;
  final Node node = Node(name: 'basketball');
  final Node _ball = Node(name: 'ball');
  final Interactable interactable = Interactable(
    kind: InteractKind.ball,
    x: Ball.home.x,
    y: 0,
    z: Ball.home.z,
    radius: 1.4,
  );
  final vm.Vector3 _last = vm.Vector3(Ball.home.x, Ball.r, Ball.home.z);

  vm.Vector3 get at => node.position;

  /// Moves the ball on to [now] (ms): flying or rolling along, or in the hands of whoever has it
  /// ([handsOf] says where those are, or null when they're not in view).
  void update(double now, vm.Vector3? Function(String id) handsOf) {
    final it = interactable;
    final holder = tracker.holder;
    if (holder != null) {
      final p = handsOf(holder);
      node.visible = p != null;
      if (p != null) node.position = p;
      it.off = true;
      _last.setFrom(node.position);
      return;
    }
    tracker.update(now);
    final pos = tracker.at;
    node.visible = tracker.visible;
    // It rolls round the way it goes.
    final dx = pos.x - _last.x, dz = pos.z - _last.z;
    final d = math.sqrt(dx * dx + dz * dz);
    if (d > 1e-5 && d < 2) {
      final axis = vm.Vector3(dz, 0, -dx)..normalize();
      _ball.rotation = vm.Quaternion.axisAngle(axis, d / Ball.r) * _ball.rotation;
    }
    node.position = pos.clone();
    _last.setFrom(pos);
    it.off = !node.visible;
    it.x = pos.x;
    it.z = pos.z;
    // Caught about chest high: the floor it's over is a meter under it.
    it.y = math.max(0, pos.y - 1);
  }
}
