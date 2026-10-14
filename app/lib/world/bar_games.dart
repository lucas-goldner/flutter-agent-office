// The rooftop bar's games corner (features/bargames/world.ts, see shared bargames.dart): an
// axe-throwing booth against the north edge with its target on the back wall, and a dart board in a
// cabinet on the outside of the booth, each with a chalkboard for the round being thrown. The darts and
// axes flying at them, and stuck in them, are everyone's: whoever throws, every page up there flies it
// the same way to the same spot.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' show Alignment, Opacity, Widget;
import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/bargames.dart';
import 'package:office_shared/layout.dart' show Floor;
import 'package:vector_math/vector_math.dart' as vm;

import '../ui/theme.dart' show kFallback, kFont;
import 'collider.dart';
import 'label_widgets.dart';
import 'labels.dart';
import 'office/geo.dart';
import 'office/outside.dart' show NightParts, bulb;
import 'office/parts.dart' show canvasTexture, tc;
import 'text.dart';
import 'toon.dart';

/// Seconds a dart takes to the board, and an axe to the target (a turn and a bit on the way).
const double _dartFlight = 0.3;
const double _axeFlight = 0.62;

/// The axe, in its own frame: the handle up +y from where the hands hold it (0), the head at the top
/// with its edge forward (+z). [axeEdge] is the middle of the edge, [axeMass] where it turns about in flight.
final vm.Vector3 axeEdge = vm.Vector3(0, 0.365, 0.113);
final vm.Vector3 axeMass = vm.Vector3(0, 0.28, 0.02);

/// How far an axe that sticks is turned past upright (its handle's top toward the target), radians.
const double _axeHit = 0.42;

const _wood = '#6b4428';
const _woodLight = '#8a5a34';
const _ink = '#2b2d42';
const _chalk = Color(0xFFF1F1EA);

/// A toon material with a picture on it, banded like everything else (the picture's colours in linear light).
PreprocessedMaterial _toonMap(Future<Texture2D> map) {
  final m = Toon.create(hex('#ffffff'));
  map.then((t) => setToonTexture(m, t));
  return m;
}

Paint _lin(String h) => Paint()..color = linColor(h);

void _text(
  Canvas g,
  String s,
  Offset at,
  double px,
  Color color, {
  String family = kFont,
  TextAlign align = TextAlign.center,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: family,
        fontFamilyFallback: kFallback,
        fontSize: px,
        fontWeight: FontWeight.w900,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final dx = switch (align) {
    TextAlign.left => 0.0,
    TextAlign.right => -tp.width,
    _ => -tp.width / 2,
  };
  tp.paint(g, at + Offset(dx, -tp.height / 2));
}

/// The dart board's face: the numbers' wedges, the treble and double rings, the bulls and the ring of numbers round it.
Future<Texture2D> _dartboardTexture() {
  const s = 1024.0;
  const px = s / 2 / DartRings.board;
  return canvasTexture(1024, 1024, (g) {
    const c = Offset(s / 2, s / 2);
    g.drawCircle(c, s / 2, _lin('#141414'));
    void wedge(double r0, double r1, double a, String color) {
      final p = Path()
        ..arcTo(Rect.fromCircle(center: c, radius: r1 * px), a - math.pi / 20, math.pi / 10, true)
        ..arcTo(Rect.fromCircle(center: c, radius: r0 * px), a + math.pi / 20, -math.pi / 10, false)
        ..close();
      g.drawPath(p, _lin(color));
    }

    for (var i = 0; i < 20; i++) {
      // Clockwise from the top: on the canvas, y runs down, so that's clockwise from -π/2.
      final a = -math.pi / 2 + i * math.pi / 10;
      final dark = i.isEven;
      wedge(DartRings.outer, DartRings.doubleOut, a, dark ? '#1b1b1b' : '#efe3c8');
      wedge(DartRings.trebleIn, DartRings.trebleOut, a, dark ? '#d62828' : '#2a9d4b');
      wedge(DartRings.doubleIn, DartRings.doubleOut, a, dark ? '#d62828' : '#2a9d4b');
    }
    g.drawCircle(c, DartRings.outer * px, _lin('#2a9d4b'));
    g.drawCircle(c, DartRings.bull * px, _lin('#d62828'));
    // The wire: round the rings, and out along the wedges' edges.
    final wire = _lin('#c9ccd3')
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final r in const [
      DartRings.outer,
      DartRings.trebleIn,
      DartRings.trebleOut,
      DartRings.doubleIn,
      DartRings.doubleOut,
    ]) {
      g.drawCircle(c, r * px, wire);
    }
    for (var i = 0; i < 20; i++) {
      final a = -math.pi / 2 + i * math.pi / 10 - math.pi / 20;
      g.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * DartRings.outer * px,
        c + Offset(math.cos(a), math.sin(a)) * DartRings.doubleOut * px,
        wire,
      );
    }
    const numbersAt = (DartRings.doubleOut + DartRings.board) / 2 * px;
    for (final (i, n) in dartNumbers.indexed) {
      final a = -math.pi / 2 + i * math.pi / 10;
      _text(g, '$n', c + Offset(math.cos(a), math.sin(a)) * numbersAt, 54, linColor('#f5f5f5'));
    }
  });
}

/// The axe target: rings painted on pale planks, a number in each, and the two blue killshot dots.
Future<Texture2D> _axeTargetTexture() {
  const px = 512.0;
  final w = (AxeTarget.width * px).round(), h = (AxeTarget.height * px).round();
  return canvasTexture(w, h, (g) {
    // Upright planks, each its own shade, with a little grain.
    const planks = 5;
    final pw = w / planks;
    for (var i = 0; i < planks; i++) {
      final x = i * pw;
      final tone = 0.9 + ((i * 7) % 5) * 0.035;
      final plank = Color.fromARGB(255, (222 * tone).round(), (186 * tone).round(), (140 * tone).round());
      g.drawRect(Rect.fromLTWH(x, 0, pw, h.toDouble()), Paint()..color = _linear(plank));
      final grain = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _linear(const Color(0x2E6E4623));
      for (var k = 0; k < 9; k++) {
        final gx = x + 12 + ((k * 37 + i * 13) % (pw - 24));
        g.drawPath(
          Path()
            ..moveTo(gx, 0)
            ..cubicTo(gx + 6, h * 0.3, gx - 6, h * 0.6, gx + 3, h.toDouble()),
          grain,
        );
      }
      g.drawRect(Rect.fromLTWH(x, 0, 3, h.toDouble()), Paint()..color = _linear(const Color(0x733C230F)));
    }
    final c = Offset(w / 2, h / 2);
    final rings = AxeTarget.rings.reversed.toList();
    final edge = _lin('#111111')
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    for (final (i, ring) in rings.indexed) {
      g.drawCircle(c, ring.r * px, _lin(ring.points == 6 ? '#e63946' : (i.isEven ? '#f7f3ea' : '#22223b')));
      g.drawCircle(c, ring.r * px, edge);
    }
    for (final (i, ring) in rings.indexed) {
      if (ring.points == 6) continue;
      final inner = i + 1 < rings.length ? rings[i + 1].r : 0.0;
      _text(
        g,
        '${ring.points}',
        c - Offset(0, (ring.r + inner) / 2 * px),
        44,
        linColor(i.isEven ? '#22223b' : '#f7f3ea'),
      );
    }
    _text(g, '6', c + const Offset(0, 2), 44, linColor('#ffffff'));
    const k = AxeTarget.kill;
    for (final s in const [-1.0, 1.0]) {
      final at = c + Offset(s * k.u * px, -k.v * px);
      g.drawCircle(at, k.r * px, _lin('#118ab2'));
      g.drawCircle(
        at,
        k.r * px,
        _lin('#ffffff')
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  });
}

/// A disc of radius [r] in XY facing +z, with UVs for a square picture of it (three's CircleGeometry).
Geometry _disc(double r, int seg) {
  final p = <double>[0, 0, 0], n = <double>[0, 0, 1], uv = <double>[0.5, 0.5];
  final idx = <int>[];
  for (var i = 0; i <= seg; i++) {
    final a = i / seg * math.pi * 2;
    final x = math.cos(a), y = math.sin(a);
    p.addAll([x * r, y * r, 0]);
    n.addAll([0, 0, 1]);
    // The canvas's y runs down.
    uv.addAll([0.5 + x / 2, 0.5 - y / 2]);
    if (i > 0) idx.addAll([0, i, i + 1]);
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList(p),
      normals: Float32List.fromList(n),
      texCoords: Float32List.fromList(uv),
      indices: idx,
    ),
  );
}

/// An sRGB colour with its channels as linear light (for canvases the toon shader samples as they are).
Color _linear(Color c) {
  final l = linear(c);
  return Color.from(alpha: c.a, red: l.x, green: l.y, blue: l.z);
}

PreprocessedMaterial? _steel, _barrel, _shaft;
final Map<String, PreprocessedMaterial> _flights = {};

/// A dart, its tip at the origin pointing +z: steel tip, tungsten barrel, shaft, and flights in
/// [color]. Half as big again as a real one, like everything here, so it shows from the oche.
Node dartModel(String color) {
  final steel = _steel ??= toonUnique(hex('#dfe3ea'));
  final barrel = _barrel ??= toonUnique(hex('#4a4e69'));
  final shaft = _shaft ??= toonUnique(hex('#eaeaea'));
  final flight = _flights[color] ??= toonUnique(hex(color))..doubleSided = true;
  final g = Node(name: 'dart');
  final along = rotX(math.pi / 2);
  g.add(
    mesh(
      transformed(cone(0.004, 0.035, 6), vm.Matrix4.translationValues(0, 0, -0.0175) * along),
      steel,
      0,
      0,
      0,
      false,
    ),
  );
  g.add(mesh(transformed(cyl(0.0075, 0.006, 0.055, 8), along), barrel, 0, 0, -0.062, false));
  g.add(mesh(transformed(cyl(0.003, 0.003, 0.045, 6), along), shaft, 0, 0, -0.11, false));
  for (final r in const [0.0, math.pi / 2]) {
    g.add(mesh(box(0.004, 0.042, 0.045), flight, 0, 0, -0.14, false)..rotation = euler(0, 0, r));
  }
  g.scale = vm.Vector3.all(1.5);
  return g;
}

/// An axe (see [axeEdge]): a wooden handle with black tape round the grip, and a steel head with its edge forward.
Node axeModel() {
  final g = Node(name: 'axe');
  g.add(mesh(cyl(0.017, 0.02, 0.46, 8), tc('#c68b59'), 0, 0.17, 0, false));
  g.add(mesh(cyl(0.022, 0.022, 0.12, 8), tc('#1d1d1d'), 0, -0.01, 0, false));
  // The head: a block round the top of the handle, the blade flaring out forward from it to the edge.
  final steel = tc('#8d99ae');
  g.add(mesh(box(0.04, 0.08, 0.07), steel, 0, 0.365, 0, false));
  final blade = Shape2()
    ..moveTo(0.02, 0.335)
    ..lineTo(0.105, 0.3)
    ..quadraticCurveTo(0.125, 0.365, 0.105, 0.43)
    ..lineTo(0.02, 0.395);
  final geo = transformed(
    extrudeShape(blade, 0.012),
    vm.Matrix4.translationValues(0.006, 0, 0) * vm.Matrix4.rotationY(-math.pi / 2),
  );
  g.add(mesh(geo, steel, 0, 0, 0, false));
  // A bright line along the edge, freshly sharpened.
  g.add(mesh(box(0.014, 0.12, 0.012), tc('#e9ecef'), 0, 0.365, 0.112, false));
  return g;
}

enum _Stage { fly, stuck, fall, lie }

/// Something flying at a target, or stuck in it, or lying where it fell.
class _Thrown {
  _Thrown(this.game, this.obj, this.from, this.yaw, this.stick, this.a0, this.land);
  final BarGame game;
  Node obj;
  double t = 0;
  final vm.Vector3 from;
  final vm.Vector3 to = vm.Vector3.zero();

  /// How high it arcs over the straight line, in the middle.
  double arc = 0;
  _Stage stage = _Stage.fly;

  /// An axe: its turn over the handle at the start and at the target, and the way it's thrown.
  final double a0;
  double a1 = 0;
  final vm.Quaternion yaw;
  final bool stick;

  /// Falling off the target: how fast, and how fast it turns.
  final vm.Vector3 vel = vm.Vector3.zero();
  double spin = 0;
  final void Function() land;
}

/// A round on a chalkboard: whose, in their colour, and what each throw of it scored.
typedef ChalkRound = ({String name, String color, List<BarScore> scores});

class _Pop {
  _Pop(this.anchor, this.label, this.pill, this.y);
  final Node anchor;
  final WorldLabel label;
  final Widget pill;
  final double y;
  double t = 0;
}

/// The games corner up on the roof: built once with the roof.
class BarGamesView {
  BarGamesView._(this.group, this._labels);

  final Node group;
  final LabelHub _labels;
  final List<Collider> colliders = [];
  final List<Interactable> interactables = [];

  /// An axe that bounced off landed on the mat here.
  void Function(vm.Vector3 at)? onDrop;

  final Map<BarGame, ({UnlitMaterial mat, String title, int w, int h})> _boards = {};
  final Map<BarGame, int> _chalked = {};
  final Map<BarGame, Node> _reticles = {};
  final List<_Thrown> _thrown = [];
  final List<_Pop> _pops = [];
  final math.Random _rnd = math.Random();
  late final GamesLamp lamp;

  /// Where (u, v) on a game's target is, [into] meters into its face (out of it, if negative).
  vm.Vector3 point(BarGame game, double u, double v, [double into = 0]) {
    final f = targetFrame(game);
    return vm.Vector3(f.x + f.right.x * u - f.out.x * into, f.y + v, f.z + f.right.z * u - f.out.z * into);
  }

  /// An axe's pose [a] turned over its handle, with its middle at [mass].
  void _poseAxe(_Thrown th, double a, vm.Vector3 mass) {
    final q = th.yaw * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), a);
    th.obj.rotation = q;
    th.obj.position = mass - q.rotated(axeMass);
  }

  /// A throw: it flies from [from] (an axe held turned [a0] over its handle, see [axeEdge]) to where
  /// [toss] says on its target, and sticks there (an axe that doesn't bounces off and falls). [color] is
  /// the thrower's, for the flights. [land] is called as it gets there.
  void launch(Toss toss, vm.Vector3 from, double a0, String color, void Function() land) {
    final game = toss.game;
    final yaw = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), throwSpot(game).facing);
    final th = _Thrown(game, Node(), from.clone(), yaw, toss.stick, a0, land);
    if (game == BarGame.darts) {
      th.obj = dartModel(color);
      th.to.setFrom(point(game, toss.u, toss.v, 0.02));
      th.arc = 0.2;
    } else {
      th.obj = axeModel();
      // Where its middle is once its edge is in the target (or it's just hitting it), turned right for
      // sticking, or with the handle coming in first for bouncing off.
      th.a1 = math.pi * 2 + (toss.stick ? _axeHit + (_rnd.nextDouble() - 0.5) * 0.25 : _axeHit + 1.9);
      final q = yaw * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), th.a1);
      th.to.setFrom(point(game, toss.u, toss.v, toss.stick ? 0.03 : -0.02) - q.rotated(axeEdge - axeMass));
      // It leaves the hands turned a0 about where they hold it: its middle starts out from there.
      th.from.add((yaw * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), a0)).rotated(axeMass.clone()));
      th.arc = 0.3;
    }
    // Nothing to use: looking at the board goes straight through it.
    _unpickable(th.obj);
    group.add(th.obj);
    _thrown.add(th);
    _step(th, 0);
  }

  void _step(_Thrown th, double dt) {
    final T = th.game == BarGame.darts ? _dartFlight : _axeFlight;
    if (th.stage == _Stage.fly) {
      th.t += dt;
      final s = math.min(1.0, th.t / T);
      final pos = th.from + (th.to - th.from) * s;
      pos.y += th.arc * 4 * s * (1 - s);
      if (th.game == BarGame.darts) {
        final dir = th.to - th.from;
        dir.y += th.arc * 4 * (1 - 2 * s);
        th.obj.position = pos;
        th.obj.rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 0, 1), dir.normalized());
      } else {
        _poseAxe(th, th.a0 + (th.a1 - th.a0) * s, pos);
      }
      if (s < 1) return;
      th.land();
      if (th.game == BarGame.darts || th.stick) {
        th.stage = _Stage.stuck;
        return;
      }
      // Off the target it bounces, turning back over, and drops to the mat.
      final f = targetFrame(th.game);
      th
        ..stage = _Stage.fall
        ..t = 0
        ..spin = -7;
      th.from.setFrom(pos);
      th.vel.setValues(
        f.out.x * 1.6 + (_rnd.nextDouble() - 0.5) * 0.6,
        1.4,
        f.out.z * 1.6 + (_rnd.nextDouble() - 0.5) * 0.6,
      );
      return;
    }
    if (th.stage == _Stage.fall) {
      th.t += dt;
      th.vel.y -= 9.8 * dt;
      th.from.addScaled(th.vel, dt);
      th.a1 += th.spin * dt;
      if (th.from.y > 0.1) {
        _poseAxe(th, th.a1, th.from);
        return;
      }
      // Lying on its side on the mat.
      th.stage = _Stage.lie;
      onDrop?.call(th.from.clone());
      th.obj.rotation =
          th.yaw *
          vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), math.pi / 2) *
          vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), th.a1);
      th.obj.position = vm.Vector3(th.from.x, 0.03, th.from.z);
    }
  }

  /// What a throw scored, floating up off its target and fading, on the thrower's [color].
  void pop(BarGame game, String text, String color) {
    // Over the target, out in front of it a little.
    final f = targetFrame(game);
    final y = f.y + (game == BarGame.darts ? 0.45 : 1.1);
    final anchor = Node(name: 'pop')..position = vm.Vector3(f.x + f.out.x * 0.3, y, f.z + f.out.z * 0.3);
    group.add(anchor);
    final pill = TagPill(text, bg: color, color: '#ffffff', size: game == BarGame.darts ? 38 : 58, border: _ink);
    final label = _labels.add(WorldLabel(anchor: anchor, child: pill, alignment: Alignment.center));
    _pops.add(_Pop(anchor, label, pill, y));
  }

  /// Pulls the darts out of the board (or the axes out of the target and up off the floor).
  void clear(BarGame game) {
    _thrown.removeWhere((th) {
      // One still on its way in lands first.
      if (th.game != game || th.stage == _Stage.fly) return false;
      th.obj.detach();
      return true;
    });
  }

  /// The round being thrown on a game's chalkboard, or a blank one.
  void chalk(BarGame game, ChalkRound? round) {
    final b = _boards[game]!;
    final n = _chalked[game] = (_chalked[game] ?? 0) + 1;
    final scores = round == null ? null : List.of(round.scores);
    canvasTexture(b.w, b.h, (g) => _drawChalk(g, game, b.title, b.w.toDouble(), b.h.toDouble(), round, scores)).then((
      t,
    ) {
      // A newer chalking got there first.
      if (_chalked[game] != n) return;
      b.mat.baseColorTexture = t;
      b.mat.baseColorFactor = vm.Vector4(1, 1, 1, 1);
    });
  }

  void _drawChalk(Canvas g, BarGame game, String title, double w, double h, ChalkRound? round, List<BarScore>? scores) {
    const family = 'Chalkboard SE';
    g.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF26332D));
    final chalk = Paint()..color = _chalk;
    _text(g, title, Offset(w / 2, 50), 52, _chalk, family: family);
    g.drawRect(Rect.fromLTWH(40, 88, w - 80, 3), chalk);
    if (round == null || scores == null) {
      final faint = _chalk.withValues(alpha: 0.75);
      _text(g, 'Step up and', Offset(w / 2, h / 2 - 10), 40, faint, family: family);
      _text(g, 'press E!', Offset(w / 2, h / 2 + 42), 40, faint, family: family);
      return;
    }
    final name = round.name.length > 16 ? '${round.name.substring(0, 15)}…' : round.name;
    _text(g, name, Offset(w / 2, 132), 40, hex(round.color), family: family);
    final rows = barRound[game]!;
    const top = 190.0;
    final step = math.min(58.0, (h - top - 90) / rows);
    for (var i = 0; i < rows; i++) {
      final s = i < scores.length ? scores[i] : null;
      final y = top + i * step;
      final c = s != null ? _chalk : _chalk.withValues(alpha: 0.35);
      _text(g, '${i + 1}.', Offset(60, y), 36, c, family: family, align: TextAlign.left);
      _text(g, s != null ? s.label : '—', Offset(130, y), 36, c, family: family, align: TextAlign.left);
      if (s != null) _text(g, '${s.points}', Offset(w - 60, y), 36, c, family: family, align: TextAlign.right);
    }
    final total = scores.fold<int>(0, (a, s) => a + s.points);
    g.drawRect(Rect.fromLTWH(40, h - 78, w - 80, 3), chalk);
    _text(g, 'Total', Offset(60, h - 40), 44, _chalk, family: family, align: TextAlign.left);
    _text(g, '$total', Offset(w - 60, h - 40), 44, _chalk, family: family, align: TextAlign.right);
  }

  /// Where you're aiming on a game's target, while you are (null: nowhere).
  void aim(BarGame? game, [double u = 0, double v = 0]) {
    for (final g in BarGame.values) {
      final r = _reticles[g]!;
      r.visible = g == game;
      if (g != game) continue;
      r.position = point(g, u, v, -0.012);
      final f = targetFrame(g);
      r.rotation = yaw(math.atan2(f.out.x, f.out.z));
    }
  }

  /// Every frame: throws fly and fall, pops float up, and the corner's lamp follows the dark.
  void update(double dt, double dark) {
    for (final th in [..._thrown]) {
      _step(th, dt);
    }
    for (final p in [..._pops]) {
      p.t += dt;
      p.anchor.position = vm.Vector3(p.anchor.position.x, p.y + p.t * 0.3, p.anchor.position.z);
      p.label.child = Opacity(opacity: math.min(1.0, (1.8 - p.t) / 0.5).clamp(0.0, 1.0), child: p.pill);
      if (p.t < 1.8) continue;
      _labels.remove(p.label);
      p.anchor.detach();
      _pops.remove(p);
    }
    lamp.power = 0.3 + 2.4 * dark;
  }

  /// Everything thrown and every pop, gone (off the roof).
  void dispose() {
    for (final p in _pops) {
      _labels.remove(p.label);
    }
    _pops.clear();
  }
}

/// The corner's warm light, once it's getting dark: a pool for the toon shader's lamp slots.
class GamesLamp {
  GamesLamp(this.x, this.y, this.z);
  final double x, y, z;
  double power = 0.3;
}

void _unpickable(Node node) {
  node.raycastable = false;
  for (final c in node.children) {
    _unpickable(c);
  }
}

BarGamesView buildBarGames(NightParts night, LabelHub labels) {
  final group = Node(name: 'bargames');
  final view = BarGamesView._(group, labels);
  final statics = Node(name: 'bargames-statics');
  final colliders = view.colliders;
  final interactables = view.interactables;
  final wood = tc(_wood);
  final trim = tc(_woodLight);
  const back = Floor.minZ;
  const front = back + AxeLane.depth;

  // ---- The axe lane --------------------------------------------------------------------------------
  // The back wall, right across the booth, and a side wall either side, open to the south.
  const outerW = AxeLane.maxX - AxeLane.minX + 2 * AxeLane.wall;
  const midX = (AxeLane.minX + AxeLane.maxX) / 2;
  final backT = AxeLane.target.z - 0.1 - back;
  final walls = Node(name: 'lane-walls');
  walls.add(mesh(box(outerW, AxeLane.height, backT), wood, midX, AxeLane.height / 2, back + backT / 2));
  colliders.add(
    Collider(
      minX: AxeLane.minX - AxeLane.wall,
      maxX: AxeLane.maxX + AxeLane.wall,
      minZ: back,
      maxZ: back + backT,
      top: 99,
    ),
  );
  for (final x in const [AxeLane.minX - AxeLane.wall / 2, AxeLane.maxX + AxeLane.wall / 2]) {
    walls.add(
      mesh(box(AxeLane.wall, AxeLane.height, AxeLane.depth), wood, x, AxeLane.height / 2, back + AxeLane.depth / 2),
    );
    statics.add(
      mesh(
        box(AxeLane.wall + 0.06, 0.08, AxeLane.depth + 0.06),
        trim,
        x,
        AxeLane.height + 0.04,
        back + AxeLane.depth / 2,
        false,
      ),
    );
    colliders.add(Collider(minX: x - AxeLane.wall / 2, maxX: x + AxeLane.wall / 2, minZ: back, maxZ: front, top: 99));
  }
  statics.add(mesh(box(outerW + 0.06, 0.08, backT + 0.06), trim, midX, AxeLane.height + 0.04, back + backT / 2, false));
  // The target, on planks bolted to the back wall.
  const t = AxeLane.target;
  final target = Node(name: 'axe-target');
  target.add(mesh(box(AxeTarget.width, AxeTarget.height, 0.1), trim, t.x, t.y, t.z - 0.05));
  target.add(
    mesh(planeXY(AxeTarget.width, AxeTarget.height), _toonMap(_axeTargetTexture()), t.x, t.y, t.z + 0.001, false),
  );
  group.add(target);
  // A rubber mat down the lane, and the red line to throw from.
  statics.add(
    mesh(
      groundPlane(AxeLane.maxX - AxeLane.minX, AxeLane.line),
      tc('#3a3d4f'),
      midX,
      0.006,
      t.z + AxeLane.line / 2,
      false,
    ),
  );
  statics.add(
    mesh(
      groundPlane(AxeLane.maxX - AxeLane.minX + 2 * AxeLane.wall + 0.3, 0.08),
      tc('#e63946'),
      midX,
      0.01,
      t.z + AxeLane.line,
      false,
    ),
  );
  // Two spare axes on pegs on the inside of the east wall, by the front.
  for (final (i, z) in const [-9.95, -10.35].indexed) {
    final spare = axeModel()
      ..position = vm.Vector3(AxeLane.maxX - 0.03, 1.1 + i * 0.05, z)
      ..rotation = euler(0, -math.pi / 2, 0.12);
    group.add(spare);
    statics.add(
      mesh(
        transformed(cyl(0.012, 0.012, 0.06, 6), rotZ(math.pi / 2)),
        tc(_ink),
        AxeLane.maxX - 0.03,
        1.43 + i * 0.05,
        z,
        false,
      ),
    );
  }
  // A lamp over the target, on an arm off the top of the back wall.
  final lampMat = bulb(night, '#fff1c9', 0.5);
  statics.add(mesh(box(0.05, 0.05, 0.7), tc(_ink), t.x, AxeLane.height - 0.1, back + backT + 0.3, false));
  final shade = toonUnique(hex(_ink))..doubleSided = true;
  group.add(mesh(cone(0.22, 0.2, 16, true), shade, t.x, AxeLane.height - 0.18, t.z + 0.6, false));
  statics.add(mesh(sphere(0.07, 10, 8), lampMat, t.x, AxeLane.height - 0.25, t.z + 0.6, false));
  // Its sign, standing on top of the back wall.
  group.add(
    textPlane('🪓 AXE THROWING', const TextOpts(bg: '#1d1d1d', color: '#ffd166', size: 64, border: '#ffd166'))
      ..position = vm.Vector3(midX, AxeLane.height + 0.42, back + backT + 0.02),
  );

  final axeAt = throwSpot(BarGame.axe);
  final axeIt = Interactable(kind: InteractKind.axe, x: axeAt.x, z: axeAt.z, radius: 1.5);
  interactables.add(axeIt);
  tagInteract(target, axeIt);

  // ---- The dart board ------------------------------------------------------------------------------
  // In a cabinet on the outside of the booth's east wall, its doors open flat either side.
  const wallX = AxeLane.maxX + AxeLane.wall;
  final cabinet = Node(name: 'dart-cabinet')
    ..position = vm.Vector3(wallX, Dartboard.y, Dartboard.z)
    // Built facing +z, then turned to face +x like the board.
    ..rotation = yaw(math.pi / 2);
  cabinet.add(mesh(box(0.66, 0.66, 0.035), wood, 0, 0, 0.0175));
  for (final s in const [-1.0, 1.0]) {
    cabinet.add(mesh(box(0.66, 0.035, 0.1), trim, 0, s * 0.33, 0.05));
    cabinet.add(mesh(box(0.035, 0.66, 0.1), trim, s * 0.33, 0, 0.05));
    // A door, swung right round against the wall.
    cabinet.add(mesh(box(0.33, 0.66, 0.025), wood, s * (0.33 + 0.18), 0, 0.0125));
  }
  // The board's face is Dartboard.x: as you face it, the picture's right is your right.
  const face = Dartboard.x - wallX;
  cabinet.add(
    mesh(
      transformed(cyl(DartRings.board + 0.005, DartRings.board + 0.005, 0.045, 48), rotX(math.pi / 2)),
      tc('#141414'),
      0,
      0,
      face - 0.0235,
    ),
  );
  cabinet.add(mesh(_disc(DartRings.board, 64), _toonMap(_dartboardTexture()), 0, 0, face, false));
  // A ring of light round it.
  final ringMat = bulb(night, '#fff6e0', 0.35);
  cabinet.add(mesh(torusXY(0.29, 0.012, 6, 40), ringMat, 0, 0, 0.1, false));
  group.add(cabinet);
  colliders.add(Collider(minX: wallX, maxX: wallX + 0.12, minZ: Dartboard.z - 0.7, maxZ: Dartboard.z + 0.7, top: 99));
  // The oche: a raised strip on a mat running back from the board.
  const oche = Dartboard.x + Dartboard.oche;
  const matLen = Dartboard.oche + 0.5;
  statics.add(mesh(groundPlane(matLen, 0.7), tc('#3a3d4f'), wallX + matLen / 2, 0.006, Dartboard.z, false));
  statics.add(mesh(box(0.05, 0.035, 0.66), tc('#c0a062'), oche, 0.0175, Dartboard.z, false));
  group.add(
    textPlane('🎯 DARTS', const TextOpts(bg: '#1d1d1d', color: '#8ecae6', size: 64, border: '#8ecae6'))
      ..position = vm.Vector3(wallX + 0.02, AxeLane.height + 0.3, Dartboard.z)
      ..rotation = yaw(math.pi / 2),
  );

  final dartAt = throwSpot(BarGame.darts);
  final dartIt = Interactable(kind: InteractKind.darts, x: dartAt.x, z: dartAt.z, radius: 1.3);
  interactables.add(dartIt);
  tagInteract(cabinet, dartIt);

  // ---- The chalkboards -----------------------------------------------------------------------------
  ({Node g, UnlitMaterial mat, int w, int h}) chalkboard(double w, double h) {
    final mat = UnlitMaterial()..baseColorFactor = linear(const Color(0xFF26332D));
    final g = Node(name: 'chalkboard');
    g.add(mesh(box(w + 0.08, h + 0.08, 0.03), trim, 0, 0, 0.015));
    g.add(Node(name: 'chalk', mesh: Mesh(planeXY(w, h), mat))..position = vm.Vector3(0, 0, 0.032));
    return (g: g, mat: mat, w: 512, h: (512 * h / w).round());
  }

  // To the right of the dart board as you face it (north), and on the inside of the booth's west wall.
  final dartChalk = chalkboard(0.72, 0.82);
  dartChalk.g
    ..position = vm.Vector3(wallX, 1.6, Dartboard.z - 1.12)
    ..rotation = yaw(math.pi / 2);
  group.add(dartChalk.g);
  final axeChalk = chalkboard(0.9, 0.8);
  axeChalk.g
    ..position = vm.Vector3(AxeLane.minX, 1.55, front - 0.75)
    ..rotation = yaw(math.pi / 2);
  group.add(axeChalk.g);
  view._boards[BarGame.darts] = (mat: dartChalk.mat, title: '🎯 Darts', w: dartChalk.w, h: dartChalk.h);
  view._boards[BarGame.axe] = (mat: axeChalk.mat, title: '🪓 Axes', w: axeChalk.w, h: axeChalk.h);
  view
    ..chalk(BarGame.darts, null)
    ..chalk(BarGame.axe, null);

  // A warm light over the corner, once it's getting dark.
  view.lamp = GamesLamp(wallX + 0.8, 2.9, Dartboard.z + 0.8);

  group.add(mergeByMaterial(statics));
  group.add(mergeByMaterial(walls));

  // ---- Aiming ----------------------------------------------------------------------------------------
  Node reticle(double r) {
    final g = Node(name: 'reticle');
    final white = basic(const Color(0xFFFFFFFF), opacity: 0.95);
    final dot = basic(hex('#ff006e'), opacity: 0.95);
    g.add(Node(mesh: Mesh(ringXY(r * 0.72, r, 32), white)));
    g.add(Node(mesh: Mesh(ringXY(r * 0.5, r * 0.72, 32), dot)));
    g.add(Node(mesh: Mesh(circleXY(r * 0.16, 12), dot)));
    _unpickable(g);
    g.visible = false;
    group.add(g);
    return g;
  }

  view._reticles[BarGame.darts] = reticle(0.014);
  view._reticles[BarGame.axe] = reticle(0.045);
  return view;
}

/// What a throw says over the target as it lands.
String tossPop(BarGame game, BarScore s) {
  if (game == BarGame.darts) return s.points == 0 ? 'Miss' : (s.label == 'Bull' ? 'BULL!' : s.label);
  if (s.label == 'Killshot') return 'KILLSHOT!';
  if (s.label == 'Bull') return 'BULLSEYE!';
  if (s.points == 0) return s.label == 'Drop' ? 'Clank!' : '0';
  return '+${s.points}';
}
