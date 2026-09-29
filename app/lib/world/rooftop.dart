// The rooftop bar, on top of the building (see office_shared's rooftop.dart): a port of
// world/rooftop.ts. A deck with a glass railing round it and the city all around, the elevator's
// housing where you arrive, a DJ on a stage under a rig of moving lights and lasers with an LED wall
// behind and a dance floor in front, a bar with a bartender under a pergola hung with string lights,
// a lounge round a fire pit and sun loungers along the south edge. Everything that flashes goes by
// the DJ's set (see djFrame), so it's in time with the music and the same for everyone up there.
//
// It sits in office coordinates (the roof is level with a floor's y = 0), under the same mirrored
// root as the office, which is hidden while you're up here. The city far below is a separate piece
// (world/city.dart), plugged in with [Rooftop.setCity].

import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Rect;

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' as lay show Elevator;
import 'package:office_shared/layout.dart'
    show DanceFloor, DjBooth, FirePit, Floor, RoofBar, Stage, elevatorFront, roofTables, seatingById, wallHeight, wallT;
import 'package:office_shared/protocol.dart' show WorkerStatus, WorkerTask;

import '../audio/dnb_score.dart';
import 'character.dart' show Worker;
import 'collider.dart';
import 'geo.dart' as w show Pivot, capsule;
import 'labels.dart';
import 'office/elevator.dart';
import 'office/geo.dart';
import 'office/outside.dart' show NightParts, bulb;
import 'office/parts.dart' show canvasTexture, fill, glassMat, seeThrough, tc;
import 'text.dart';
import 'toon.dart';

/// The building, walls included: the roof's edge.
abstract final class _B {
  static const double minX = Floor.minX - wallT;
  static const double maxX = Floor.maxX + wallT;
  static const double minZ = Floor.minZ - wallT;
  static const double maxZ = Floor.maxZ + wallT;
}

const String _ink = '#2b2d42';

/// The city round the roof, far below (world/city.dart). Anything with these three will do.
abstract interface class RoofCity {
  Node get group;

  /// The building has [floors] floors under the roof: the street is as far down as that is tall.
  void setFloors(int floors);

  /// [night] 0 by day to 1 at night: windows and streets light up.
  void update(double t, double dt, double night);
}

/// What the rooftop's lighting needs from the sky.
class RoofEnv {
  const RoofEnv({required this.dark, required this.motion});

  /// How dark it is, 0 by day to 1 at night: lights show up more.
  final double dark;

  /// Things may sweep and pulse (off when the system asks for less motion).
  final bool motion;
}

/// A pool of coloured light on the roof (the washes, the bar, the fire), for the toon shader's
/// lamp slots (see ToonLight.lampPos), in place of the street lamps far below.
class RoofLamp {
  RoofLamp(this.x, this.y, this.z, this.reach);

  final double x;
  final double y;
  final double z;
  final double reach;

  /// Linear colour x power.
  final vm.Vector3 light = vm.Vector3.zero();

  void set(Color c, double power) {
    final l = linear(c);
    light.setValues(l.x * power, l.y * power, l.z * power);
  }
}

/// 0–1, the same for the same tile on the same beat.
double sparkle(int c, int r, int beat) {
  final x = math.sin(c * 12.9898 + r * 78.233 + beat * 37.719) * 43758.5453;
  return x - x.floor();
}

/// A colour round the wheel (0–1) at full saturation and lightness [l], as an sRGB colour.
Color hue(double h, [double l = 0.55]) => HSLColor.fromAHSL(1, (((h % 1) + 1) % 1) * 360, 1, l.clamp(0, 1)).toColor();

// ---- The DJ ----------------------------------------------------------------------------------------

/// The DJ: headphones on, cap on backwards, sunglasses, moving to the music. Faces +z.
class _Dj {
  _Dj() {
    final skin = tc('#8d5524');
    final shirt = tc('#1d1d1d');
    final pants = tc('#3d405b');
    final ink = tc('#111111');
    root.add(_body.node);
    _body.add(mesh(w.capsule(0.26, 0.28, 6, 12), shirt, 0, 0.72, 0));
    // A print on the front of the tee.
    _body.add(mesh(circleXY(0.1), tc('#06d6a0'), 0, 0.78, 0.262, false));
    _head.position = vm.Vector3(0, 1.32, 0);
    _head.add(mesh(sphere(0.34, 20, 16), skin));
    // The cap, on backwards.
    final capMat = tc('#ef476f');
    _head.add(place(mesh(sphere(0.36, 18, 10), capMat), y: 0.1, scale3: vm.Vector3(1, 0.55, 1)));
    _head.add(mesh(box(0.3, 0.03, 0.22), capMat, 0, 0.06, -0.4));
    // Sunglasses.
    _head.add(mesh(box(0.44, 0.09, 0.05), ink, 0, 0.04, 0.31, false));
    _head.add(
      place(
        mesh(torusXY(0.06, 0.015, 6, 12, math.pi), ink, 0, 0, 0, false),
        y: -0.1,
        z: 0.31,
        rot: euler(0, 0, math.pi),
      ),
    );
    // Headphones: a band over the cap and a cup on each ear.
    _head.add(mesh(torusXY(0.39, 0.035, 8, 24, math.pi), ink, 0, 0.02, 0, false));
    for (final s in [-1.0, 1.0]) {
      _head.add(
        place(
          mesh(cyl(0.12, 0.12, 0.09, 16), tc('#3d405b'), 0, 0, 0, false),
          x: s * 0.36,
          y: 0.02,
          rot: euler(0, 0, math.pi / 2),
        ),
      );
    }
    _body.add(_head.node);
    w.Pivot limb(double len, double r, Material mat, double x, double y) {
      final pivot = w.Pivot()..position = vm.Vector3(x, y, 0);
      pivot.add(mesh(w.capsule(r, len, 4, 8), mat, 0, -len / 2 - r / 2, 0));
      _body.add(pivot.node);
      return pivot;
    }

    limb(0.22, 0.1, pants, -0.12, 0.42).apply();
    limb(0.22, 0.1, pants, 0.12, 0.42).apply();
    _armR = limb(0.24, 0.08, shirt, -0.33, 0.9);
    _armL = limb(0.24, 0.08, shirt, 0.33, 0.9);
    for (final arm in [_armR, _armL]) {
      arm.add(mesh(sphere(0.085, 12, 10), skin, 0, -0.38, 0));
    }
  }

  final Node root = Node(name: 'dj');
  final w.Pivot _body = w.Pivot();
  final w.Pivot _head = w.Pivot();

  /// Arms on the -x and +x sides (their right and left, facing +z).
  late final w.Pivot _armR, _armL;

  void update(double t, DjFrame f, bool motion) {
    final e = f.energy;
    final phase = f.beats % 1;
    final m = motion ? 1.0 : 0.3;
    // Bouncing on every beat, and nodding along.
    _body.position = vm.Vector3(0, -0.05 * e * m * math.sin(phase * math.pi), 0);
    _head
      ..x = 0.28 * m * (0.35 + 0.65 * e) * math.max(0, math.sin(phase * math.pi * 2))
      ..z = 0.06 * m * math.sin(f.beats * math.pi * 0.5)
      ..apply();
    // Their right hand's on the mixer, riding the faders.
    _armR
      ..x = -1.15 + 0.05 * math.sin(t * 7)
      ..y = 0
      ..z = 0.25 + 0.06 * math.sin(t * 3.1)
      ..apply();
    if (f.sinceDrop < 3.2 && motion) {
      // The drop: a fist in the air, pumping on the beat.
      _armL
        ..x = 0
        ..z = 2.9 - 0.3 * math.sin(phase * math.pi);
    } else if (f.part == Part.build || f.part == Part.intro || (f.part == Part.breakdown && f.beats % 16 < 8)) {
      // One cup of the headphones held to their ear, listening for the next track.
      _armL
        ..x = -0.2
        ..z = 2.55;
    } else {
      // Working the jog wheel.
      _armL
        ..x = -1.2 + 0.08 * math.sin(t * 11)
        ..z = -0.2 + 0.12 * math.sin(t * 5.3);
    }
    _armL.apply();
  }
}

// ---- The rooftop --------------------------------------------------------------------------------

class _Head {
  _Head(this.pan, this.tilt, this.beam, this.lens, this.i);
  final Node pan;
  final Node tilt;
  final UnlitMaterial beam;
  final UnlitMaterial lens;
  final int i;
}

class _Laser {
  _Laser(this.rays, this.mat, this.from, this.k);
  final List<Node> rays;
  final UnlitMaterial mat;
  final vm.Vector3 from;
  final int k;
}

const int _laserRays = 7;
const int _ledCols = 32;
const int _ledRows = 16;
const double _ledW = 8;
const double _ledH = 4;

class Rooftop {
  Rooftop._(this.group, this.colliders, this.interactables, this.elevator);

  final Node group;
  final List<Collider> colliders;
  final List<Interactable> interactables;
  final Elevator elevator;

  /// The pools of light up here, for the toon shader (see RoofLamp).
  final List<RoofLamp> lamps = [];

  /// Where drinks are poured, for the sound of one.
  final vm.Vector3 pourAt = vm.Vector3(RoofBar.x + 0.2, RoofBar.height + 0.2, (RoofBar.minZ + RoofBar.maxZ) / 2);

  RoofCity? _city;
  int _floors = 1;

  /// Plugs in the city all around, far below (it can come later: the roof works without it).
  void setCity(RoofCity? city) {
    final old = _city;
    if (old != null) group.remove(old.group);
    _city = city;
    if (city == null) return;
    // Only to look at: the crosshair and the name tags' line of sight go through it.
    _unpickable(city.group);
    group.add(city.group);
    city.setFloors(_floors);
  }

  RoofCity? get city => _city;

  /// The building has [floors] floors under the roof: the street is as far down as that is tall.
  void setFloors(int floors) {
    _floors = floors;
    _city?.setFloors(floors);
  }

  late final _Dj _dj;
  late final Worker _bartender;
  double _tendZ = 0;
  double _wander = 0;
  final List<Node> _cones = [];
  final List<Node> _fans = [];
  final List<_Head> _heads = [];
  final List<_Laser> _lasers = [];
  late final InstancedMesh _tiles;
  late final int _cols, _rows;
  late final InstancedMesh _led;
  final List<Node> _ledWords = [];
  double _ledAt = -1;
  late final UnlitMaterial _strip, _barGlow, _glowPanel, _jog, _neon;
  final List<w.Pivot> _flames = [];
  late final RoofLamp _barLamp, _fireLamp;
  final List<RoofLamp> _washes = [];
  final math.Random _rnd = math.Random();

  /// Someone ordered a drink at the bar, standing (or sitting) at [z] along it: the bartender comes over.
  void serve(double z) {
    _tendZ = z.clamp(RoofBar.minZ + 0.6, RoofBar.maxZ - 0.6);
    _wander = 6;
    _bartender.cheer(1.2);
  }

  /// Moves everything to the music. Returns how hard the strobes flash right now (0–1), for the
  /// scene's light: on the snares as a drop lands, never quicker than a couple of times a second.
  double update(double t, double dt, DjFrame f, RoofEnv env) {
    final dark = env.dark, motion = env.motion;
    final m = motion ? 1.0 : 0.0;
    final e = f.energy;
    final drop = f.part == Part.drop;
    // How much the lights stand out: faint in the sun, blazing at night.
    final show = 0.3 + 0.7 * dark;
    _city?.update(t, dt, dark);
    elevator.update(dt);
    _dj.update(t, f, motion);

    // The bartender drifts along the bar between customers, and comes over when someone orders.
    _wander -= dt;
    if (_wander <= 0) {
      _wander = 5 + _rnd.nextDouble() * 6;
      _tendZ = RoofBar.minZ + 1 + _rnd.nextDouble() * (RoofBar.maxZ - RoofBar.minZ - 2);
    }
    final bp = _bartender.root.position;
    _bartender.root.position = vm.Vector3(bp.x, bp.y, bp.z + (_tendZ - bp.z).clamp(-dt * 1.6, dt * 1.6));
    _bartender.update(dt, t);

    // Speaker cones thump.
    for (final c in _cones) {
      c.scale = vm.Vector3.all(1 + 0.12 * f.kick * m);
    }
    for (final fan in _fans) {
      fan.rotation = yaw(t * 9);
    }

    // Moving heads: sweeping down onto the dance floor and up into the sky in the drops, slowly
    // searching the sky in a breakdown, and all rising together through a build.
    for (final h in _heads) {
      final i = h.i;
      final side = i - 2;
      // Across (radians either side of straight out over the dance floor), and up: -1 down onto the floor, 1 high into the sky.
      var pan = side * 0.25;
      var aim = 0.4;
      if (!motion) {
        // Held still.
      } else if (drop) {
        final bar = (f.beats / 4).floor();
        pan = side * 0.25 + math.sin(f.beats * math.pi * 0.5 + i) * 0.55;
        aim = 0.85 * math.sin(f.beats * math.pi * 0.25 + (bar.isOdd ? i : -i));
      } else if (f.part == Part.build) {
        pan = side * (0.35 - 0.3 * f.rise) + math.sin(t * (1 + 6 * f.rise) + i) * 0.3 * (1 - f.rise);
        aim = 0.2 + 0.8 * f.rise;
      } else {
        pan = side * 0.3 + math.sin(t * 0.35 + i * 0.9) * 0.4;
        aim = 0.5 + 0.3 * math.sin(t * 0.27 + i);
      }
      h.pan.rotation = yaw(pan);
      // The beam hangs straight down at 0; turned back past level, out over the dance floor (+z) and up.
      h.tilt.rotation = euler(-(1.8 + 0.8 * aim));
      final color = hue(f.hue + (drop && f.beats.floor().isOdd ? 0.5 : 0) + i * 0.04, 0.6);
      final level = (drop ? 0.55 + 0.45 * f.beat : (f.part == Part.build ? 0.3 + 0.6 * f.rise : 0.25)) * show;
      h.beam.baseColorFactor = linear(color, level * 0.3);
      final lens = linear(color);
      final k = math.min(1.0, 0.6 + 0.8 * level);
      h.lens.baseColorFactor = vm.Vector4(lens.x * k, lens.y * k, lens.z * k, 1);
    }

    // Lasers: a fan of rays sweeping back and forth, in the drops and the builds.
    for (final l in _lasers) {
      final on = drop ? 1.0 : (f.part == Part.build ? f.rise : 0.0);
      // Only once it's getting dark: in the sun they'd just be scratches on the sky.
      final opacity = on * 0.9 * dark;
      final visible = opacity > 0.01;
      for (final r in l.rays) {
        r.visible = visible;
      }
      if (!visible) continue;
      final c = l.mat.baseColorFactor;
      l.mat.baseColorFactor = vm.Vector4(c.x, c.y, c.z, opacity);
      final sweep = math.sin(t * (drop ? 1.3 : 0.6) * m + l.k * math.pi) * 0.45;
      final lift = 0.12 + 0.28 * (0.5 + 0.5 * math.sin(t * 0.9 * m + l.k));
      for (var r = 0; r < _laserRays; r++) {
        final yw = sweep + (r / (_laserRays - 1) - 0.5) * 1.1 + (l.k == 1 ? -0.2 : 0.2);
        final dir = vm.Vector3(math.sin(yw) * math.cos(lift), math.sin(lift), math.cos(yw) * math.cos(lift));
        l.rays[r]
          ..position = l.from + dir * 35
          ..rotation = lookAlong(dir);
      }
    }

    // The dance floor: a checkerboard, ripples, stripes or sparkles, changing every four bars.
    final beat = f.beats.floor();
    final pattern = (f.beats / 16).floor() % 4;
    // With reduced motion it keeps to the slow wash, whatever the set is doing.
    final pulse = !motion
        ? 0.3
        : (drop ? 0.45 + 0.55 * f.beat : (f.part == Part.build ? 0.35 + 0.5 * f.beat * f.rise : 0.3));
    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        double on;
        var h = f.hue;
        if (!motion || (!drop && f.part != Part.build)) {
          // Slow colour washing across it.
          on = 0.5 + 0.5 * math.sin(c * 0.6 + r * 0.4 - t * 1.2);
          h += c * 0.02 + r * 0.03;
        } else if (pattern == 0) {
          on = ((c + r + beat) % 2).toDouble();
        } else if (pattern == 1) {
          final dist = math.sqrt(math.pow(c - _cols / 2 + 0.5, 2) + math.pow(r - _rows / 2 + 0.5, 2));
          on = 0.5 + 0.5 * math.sin(dist * 1.3 - f.beats * math.pi);
          h += dist * 0.04;
        } else if (pattern == 2) {
          on = (c + beat) % 3 == 0 ? 1 : 0.1;
        } else {
          on = sparkle(c, r, beat) > 0.45 ? 1 : 0.05;
        }
        final l = 0.08 + 0.5 * on.abs() * pulse * (0.6 + 0.4 * e);
        _tiles.setInstanceColor(r * _cols + c, linear(hue(h + (on > 0.5 ? 0 : 0.5), l)));
      }
    }

    // The washes, the stage's strip, the glow under the bar, the fire and the bulbs.
    for (var i = 0; i < _washes.length; i++) {
      final wash = _washes[i];
      final c = hue(f.hue + i * 0.33 + (drop ? (f.beats / 2).floor() * 0.17 : t * 0.02), 0.5);
      wash.set(c, (1.2 + 5 * e * (drop ? f.beat : 0.4)) * show * 0.5);
    }
    _strip.baseColorFactor = linear(hue(f.hue + 0.5, 0.45 + 0.2 * f.beat));
    _barGlow.baseColorFactor = linear(hue(f.hue + 0.15 + t * 0.01, 0.5));
    final g = linear(const Color(0xFFFFB55A));
    final gk = 0.75 + 0.35 * dark;
    _glowPanel.baseColorFactor = vm.Vector4(math.min(1, g.x * gk), math.min(1, g.y * gk), math.min(1, g.z * gk), 1);
    _barLamp.set(const Color(0xFFFFC98A), (0.6 + 2.6 * dark) * 0.6);
    final flicker = 0.85 + 0.15 * math.sin(t * 17) * math.sin(t * 7.3 + 1);
    for (var i = 0; i < _flames.length; i++) {
      _flames[i].node.scale = vm.Vector3(1, (0.75 + 0.35 * math.sin(t * (5 + i) + i * 1.7).abs()) * flicker, 1);
    }
    _fireLamp.set(const Color(0xFFFF8A3D), (1.2 + 1.6 * dark) * flicker * 0.8);
    final n = linear(const Color(0xFFFF4FD8), 0.9 + 0.1 * math.sin(t * 3));
    _neon.baseColorFactor = n;
    _jog.baseColorFactor = linear(hue(f.hue + 0.6, 0.55));
    // The LED wall changes twenty times a second.
    if (t - _ledAt > 0.05 || t < _ledAt) {
      _ledAt = t;
      _drawLed(f, t, !motion);
    }
    // Strobes: on each snare as the drop lands and through the build's last bar, a couple a second at most.
    if (!motion) return 0;
    if (drop && f.sinceDrop < 6) return f.snare;
    if (f.part == Part.build && f.rise > 7 / 8) return f.beat;
    return 0;
  }

  /// The LED wall behind the DJ, a pixel at a time. [calm]: the slow washes whatever the set is
  /// doing, for anyone who'd rather nothing flashed.
  void _drawLed(DjFrame f, double t, bool calm) {
    // In the old canvas's pixels (512 x 256), sampled in the middle of each LED.
    const cw = 512.0, ch = 256.0;
    const bg = Color(0xFF07060D);
    final base = f.hue * 360;
    final mode = !calm && f.part == Part.drop ? 0 : (!calm && f.part == Part.build ? 1 : 2);
    final washes = mode == 2
        ? [
            for (var i = 0; i < 3; i++)
              (
                x: cw / 2 + math.sin(t * 0.4 + i * 2.1) * cw * 0.35,
                y: ch / 2 + math.cos(t * 0.3 + i * 1.7) * ch * 0.3,
                c: HSLColor.fromAHSL(1, (base + i * 60) % 360, 0.9, 0.55).toColor(),
              ),
          ]
        : const <({double x, double y, Color c})>[];
    for (var j = 0; j < _ledRows; j++) {
      for (var i = 0; i < _ledCols; i++) {
        final px = (i + 0.5) * cw / _ledCols, py = (j + 0.5) * ch / _ledRows;
        var c = bg;
        if (mode == 0) {
          // An equalizer, jumping with the kick.
          const n = 24;
          final b = (px / (cw / n)).floor();
          final v = 0.25 + 0.75 * math.sin(b * 1.7 + t * 4.3 + f.beats * 0.9).abs() * (0.55 + 0.45 * f.kick);
          if (py >= ch - v * ch) c = HSLColor.fromAHSL(1, (base + b * 7) % 360, 0.95, 0.58).toColor();
        } else if (mode == 1) {
          // Stripes racing up, faster and faster, and a bar filling up to the drop.
          final speed = 60 + 420 * f.rise;
          for (var y = -40.0; y < ch; y += 40) {
            final top = (y + ((t * speed) % 40) + ch) % (ch + 40) - 40;
            if (py >= top && py < top + 14) {
              final s = HSLColor.fromAHSL(
                1,
                (base + y) % 360 < 0 ? (base + y) % 360 + 360 : (base + y) % 360,
                0.9,
                0.55,
              ).toColor();
              c = Color.lerp(c, s, 0.25 + 0.5 * f.rise)!;
            }
          }
          if (py >= ch - 34 && py < ch - 22 && px >= 40 && px < 40 + (cw - 80) * f.rise) c = const Color(0xFFFFFFFF);
        } else {
          // Slow washes of colour.
          for (final wsh in washes) {
            final d = math.sqrt(math.pow(px - wsh.x, 2) + math.pow(py - wsh.y, 2));
            final a = 0.8 * math.max(0, 1 - d / 170);
            if (a > 0) c = Color.lerp(c, wsh.c, a)!;
          }
        }
        _led.setInstanceColor(j * _ledCols + i, linear(c));
      }
    }
    final word = f.part == Part.drop ? 0 : (f.part == Part.build ? 1 : 2);
    for (var i = 0; i < _ledWords.length; i++) {
      _ledWords[i].visible = i == word;
    }
  }
}

/// Leaves [node] and everything under it out of looking and clicking, so the crosshair goes through
/// it: a beam or a laser would otherwise be in the way of whatever's behind.
void _unpickable(Node node) {
  node.raycastable = false;
  for (final c in node.children) {
    _unpickable(c);
  }
}

/// Makes [obj] somewhere to sit (see seating): walk up to it, or look at it, and press E.
void _seatable(Node obj, String seatId, double radius, List<Interactable> interactables) {
  final seat = seatingById[seatId]!;
  final it = Interactable(kind: InteractKind.seat, seatId: seatId, x: seat.x, y: seat.y, z: seat.z, radius: radius);
  interactables.add(it);
  tagInteract(obj, it);
}

/// A collider round a box [w] wide and [d] deep at (x, z), turned by [rotY] (square turns only).
Collider _boxCollider(double x, double z, double w, double d, double rotY, double top) {
  final turned = math.sin(rotY).abs() > 0.5;
  final hw = (turned ? d : w) / 2;
  final hd = (turned ? w : d) / 2;
  return Collider(minX: x - hw, maxX: x + hw, minZ: z - hd, maxZ: z + hd, top: top);
}

/// Teak decking, the boards running east–west (in linear colours: the toon shader samples it as-is).
Future<Texture2D> _deckTexture() {
  const w = _B.maxX - _B.minX;
  const d = _B.maxZ - _B.minZ;
  const px = 12.0;
  return canvasTexture((w * px).round(), (d * px).round(), (Canvas g) {
    g.drawRect(const Rect.fromLTWH(0, 0, w * px, d * px), fill(linColor('#b98457')));
    const board = 0.14 * px;
    var row = 0;
    for (var y = 0.0; y < d * px; y += board, row++) {
      // Each row of boards a slightly different tone, with joints staggered along it.
      final tone = 0.9 + ((row * 37) % 11) / 55;
      final c = linear(
        Color.fromARGB(
          255,
          (185 * tone).round().clamp(0, 255),
          (132 * tone).round().clamp(0, 255),
          (87 * tone).round().clamp(0, 255),
        ),
      );
      g.drawRect(Rect.fromLTWH(0, y, w * px, board - 1), fill(Color.from(alpha: 1, red: c.x, green: c.y, blue: c.z)));
      final joint = fill(const Color(0x40100804));
      for (var x = ((row * 53) % 7) * px * 0.4; x < w * px; x += 2.4 * px) {
        g.drawRect(Rect.fromLTWH(x, y, 1, board), joint);
      }
    }
  });
}

/// Points along a sagging string from [a] to [b] (a quadratic curve through a middle [sag] low).
List<vm.Vector3> _festoonCurve(vm.Vector3 a, vm.Vector3 b, double sag, int n) {
  final mid = (a + b) * 0.5
    ..y -= sag * 2;
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n, k = 1 - t;
        return a * (k * k) + mid * (2 * k * t) + b * (t * t);
      }(),
  ];
}

/// Builds the rooftop. [night] collects the bulbs that glow after dark; [labels] is where the
/// bartender's card goes.
Rooftop buildRooftop(NightParts night, LabelHub labels) {
  final group = Node(name: 'rooftop');
  final colliders = <Collider>[];
  final interactables = <Interactable>[];
  final statics = Node(name: 'roof-statics');
  const bw = _B.maxX - _B.minX;
  const bd = _B.maxZ - _B.minZ;
  const cx = (_B.minX + _B.maxX) / 2;
  const cz = (_B.minZ + _B.maxZ) / 2;

  // The deck, and the slab it's laid on (the top of the building).
  final deckMat = Toon.create(hex('#ffffff'));
  _deckTexture().then((t) => setToonTexture(deckMat, t));
  group.add(mesh(groundPlane(bw, bd), deckMat, cx, 0.002, cz, false));
  statics.add(mesh(box(bw, 0.3, bd), tc('#c9c4bb'), cx, -0.15, cz, false));
  colliders.add(Collider(minX: _B.minX, maxX: _B.maxX, minZ: _B.minZ, maxZ: _B.maxZ, bottom: -0.3, top: 0));

  // Round the edge: a concrete curb with glass panels on it and a steel rail on top. Nobody goes over it.
  final curb = tc('#d8d3ca');
  final steel = tc('#aeb6bf');
  const edges = [
    (_B.minX, _B.maxX, _B.minZ, Floor.minZ),
    (_B.minX, _B.maxX, Floor.maxZ, _B.maxZ),
    (_B.minX, Floor.minX, _B.minZ, _B.maxZ),
    (Floor.maxX, _B.maxX, _B.minZ, _B.maxZ),
  ];
  for (final (x0, x1, z0, z1) in edges) {
    final ex = (x0 + x1) / 2, ez = (z0 + z1) / 2;
    final alongX = x1 - x0 > z1 - z0;
    statics.add(mesh(box(x1 - x0, 0.45, z1 - z0), curb, ex, 0.225, ez));
    final len = alongX ? x1 - x0 : z1 - z0;
    group.add(
      place(
        mesh(planeXY(len, 0.72, both: true), glassMat, 0, 0, 0, false),
        x: ex,
        y: 0.81,
        z: ez,
        rot: alongX ? null : yaw(math.pi / 2),
      ),
    );
    statics.add(
      place(
        mesh(cyl(0.035, 0.035, len, 8), steel, 0, 0, 0, false),
        x: ex,
        y: 1.19,
        z: ez,
        rot: alongX ? euler(0, 0, math.pi / 2) : euler(math.pi / 2),
      ),
    );
    for (var a = 0.0; a <= len + 0.01; a += 2.4) {
      statics.add(mesh(box(0.06, 0.75, 0.06), steel, alongX ? x0 + a : ex, 0.8, alongX ? ez : z0 + a, false));
    }
    colliders.add(Collider(minX: x0, maxX: x1, minZ: z0, maxZ: z1, top: 99));
  }

  // The elevator, in its housing: a back wall and a roof over the shaft (as tall as a floor), with a light on top.
  final elevator = buildElevator();
  elevator.setSign('🍸 Rooftop bar');
  group.add(elevator.group);
  colliders.addAll(elevator.colliders);
  interactables.add(elevator.interactable);
  const ex = lay.Elevator.x, ew = lay.Elevator.width;
  statics.add(
    mesh(box(ew, wallHeight + 0.3, wallT), tc('#b8c1cc'), ex, (wallHeight + 0.3) / 2, Floor.minZ - wallT / 2),
  );
  statics.add(
    mesh(
      box(ew + 0.3, 0.3, elevatorFront - _B.minZ + 0.2),
      tc('#8d99ae'),
      ex,
      wallHeight + 0.15,
      (_B.minZ + elevatorFront) / 2 + 0.05,
    ),
  );
  statics.add(
    mesh(sphere(0.12, 10, 8), bulb(night, '#ff5d5d', 0.6), ex, wallHeight + 0.4, (_B.minZ + elevatorFront) / 2, false),
  );
  colliders.add(Collider(minX: ex - ew / 2, maxX: ex + ew / 2, minZ: _B.minZ, maxZ: Floor.minZ, top: 99));

  // ---- The stage ----------------------------------------------------------------------------------
  final stageMat = tc('#2b2d42');
  const sw = Stage.maxX - Stage.minX;
  const sd = Stage.maxZ - Stage.minZ;
  const scx = (Stage.minX + Stage.maxX) / 2;
  const scz = (Stage.minZ + Stage.maxZ) / 2;
  statics.add(mesh(box(sw, Stage.height, sd), stageMat, scx, Stage.height / 2, scz));
  colliders.add(Collider(minX: Stage.minX, maxX: Stage.maxX, minZ: Stage.minZ, maxZ: Stage.maxZ, top: Stage.height));
  // A step up at its east end.
  statics.add(mesh(box(0.7, Stage.height / 2, 1.8), stageMat, Stage.maxX + 0.35, Stage.height / 4, -10.7));
  colliders.add(Collider(minX: Stage.maxX, maxX: Stage.maxX + 0.7, minZ: -11.6, maxZ: -9.8, top: Stage.height / 2));
  // An LED strip along its front edge.
  final strip = UnlitMaterial()..baseColorFactor = linear(hex('#ff4fd8'));
  group.add(mesh(box(sw, 0.06, 0.02), strip, scx, Stage.height - 0.08, Stage.maxZ + 0.011, false));

  // The DJ's table: decks and a mixer on it, and the DJ's name across the front. The DJ stands on a
  // riser behind it, so the dance floor sees more than the top of their cap.
  final table = Node(name: 'dj-table');
  const tableY = Stage.height;
  const th = 0.8;
  const tz = DjBooth.z + 0.75;
  const riser = 0.25;
  table.add(mesh(box(3.4, th, 0.7), tc('#1d1d1d'), DjBooth.x, tableY + th / 2, tz));
  statics.add(mesh(box(1.8, riser, 0.9), tc('#3d405b'), DjBooth.x, tableY + riser / 2, DjBooth.z - 0.05));
  final plate = textPlane(
    'DJ MERGE CONFLICT',
    const TextOpts(color: '#ffe3fb', bg: '#111018', border: '#ff4fd8', size: 72),
  );
  table.add(place(plate, x: DjBooth.x, y: tableY + th / 2, z: tz + 0.352));
  final jog = UnlitMaterial()..baseColorFactor = linear(hex('#4cc9f0'));
  for (final s in [-1.0, 1.0]) {
    table.add(mesh(box(0.62, 0.07, 0.5), tc('#3d405b'), DjBooth.x + s * 0.95, tableY + th + 0.035, tz, false));
    table.add(mesh(cyl(0.19, 0.19, 0.02, 24), jog, DjBooth.x + s * 0.95, tableY + th + 0.08, tz - 0.03, false));
  }
  table.add(mesh(box(0.5, 0.09, 0.45), tc('#565a75'), DjBooth.x, tableY + th + 0.045, tz, false));
  for (var i = 0; i < 4; i++) {
    table.add(
      mesh(cyl(0.025, 0.025, 0.04, 8), tc('#ffd166'), DjBooth.x - 0.18 + i * 0.12, tableY + th + 0.1, tz - 0.1, false),
    );
  }
  group.add(table);
  colliders.add(Collider(minX: DjBooth.x - 1.7, maxX: DjBooth.x + 1.7, minZ: tz - 0.35, maxZ: tz + 0.35, top: 99));
  final djIt = Interactable(kind: InteractKind.dj, x: DjBooth.x, z: Stage.maxZ + 0.4, radius: 2.4);
  interactables.add(djIt);
  tagInteract(table, djIt);

  final dj = _Dj();
  dj.root.position = vm.Vector3(DjBooth.x, Stage.height + riser, DjBooth.z);
  tagInteract(dj.root, djIt);
  group.add(dj.root);

  // Speaker stacks at either front corner of the stage; their cones thump with the kick.
  final cones = <Node>[];
  final cab = tc('#1d1d1d');
  final coneMat = tc('#3d405b');
  for (final sx in [Stage.minX + 1.1, Stage.maxX - 1.1]) {
    const z = Stage.maxZ - 0.55;
    statics.add(mesh(box(1.2, 1.0, 0.9), cab, sx, Stage.height + 0.5, z));
    statics.add(mesh(box(0.95, 1.35, 0.8), cab, sx, Stage.height + 1.675, z));
    for (final (y, r) in const [(Stage.height + 0.5, 0.36), (Stage.height + 1.35, 0.26), (Stage.height + 2.0, 0.16)]) {
      final cone = place(
        mesh(cyl(r, r * 0.6, 0.06, 20), coneMat, 0, 0, 0, false),
        x: sx,
        y: y,
        z: z + (y > Stage.height + 1 ? 0.41 : 0.46),
        rot: euler(math.pi / 2),
      );
      group.add(cone);
      cones.add(cone);
    }
    colliders.add(Collider(minX: sx - 0.6, maxX: sx + 0.6, minZ: z - 0.45, maxZ: z + 0.45, top: 99));
  }

  // The LED wall behind the DJ: a grid of lights, and the words over them.
  const ledY = Stage.height + 0.35 + _ledH / 2;
  final led = InstancedMesh(
    geometry: planeXY(_ledW / _ledCols * 0.92, _ledH / _ledRows * 0.92),
    material: UnlitMaterial(),
  );
  for (var j = 0; j < _ledRows; j++) {
    for (var i = 0; i < _ledCols; i++) {
      final x = scx - _ledW / 2 + (i + 0.5) * _ledW / _ledCols;
      final y = ledY + _ledH / 2 - (j + 0.5) * _ledH / _ledRows;
      led.addInstance(vm.Matrix4.translationValues(x, y, Stage.minZ + 0.2), color: linear(const Color(0xFF07060D)));
    }
  }
  group.add(
    Node(name: 'led-wall')
      ..addComponent(InstancedMeshComponent(led))
      ..castsShadows = false,
  );
  statics.add(mesh(box(_ledW + 0.3, _ledH + 0.3, 0.25), tc('#1d1d1d'), scx, ledY, Stage.minZ + 0.06));
  colliders.add(
    Collider(minX: scx - _ledW / 2, maxX: scx + _ledW / 2, minZ: Stage.minZ, maxZ: Stage.minZ + 0.35, top: 99),
  );
  final words = <Node>[];
  for (final text in const ['AGENT OFFICE', 'GET READY', 'DJ MERGE CONFLICT']) {
    final n = place(
      textPlane(text, const TextOpts(color: '#ffffff', size: 96)),
      x: scx,
      y: ledY + _ledH * 0.08,
      z: Stage.minZ + 0.23,
      scale: text.length > 12 ? 1.2 : 1.6,
    )..visible = false;
    group.add(n);
    words.add(n);
  }

  // The rig: a truss tower either side of the stage and a beam across, with moving heads hanging off it.
  final truss = tc('#c9d1d9');
  const rigZ = Stage.maxZ - 0.15;
  const rigTop = 5.6;
  for (final x in [Stage.minX + 0.2, Stage.maxX - 0.2]) {
    for (final (dx, dz) in const [(-0.15, -0.15), (0.15, -0.15), (-0.15, 0.15), (0.15, 0.15)]) {
      statics.add(
        mesh(cyl(0.035, 0.035, rigTop - Stage.height, 6), truss, x + dx, (rigTop + Stage.height) / 2, rigZ + dz, false),
      );
    }
    for (var y = Stage.height + 0.4; y < rigTop; y += 0.6) {
      statics.add(mesh(box(0.34, 0.03, 0.34), truss, x, y, rigZ, false));
    }
  }
  for (final dy in const [0.0, 0.3]) {
    for (final dz in const [-0.15, 0.15]) {
      statics.add(
        place(
          mesh(cyl(0.035, 0.035, sw - 0.4, 6), truss, 0, 0, 0, false),
          x: scx,
          y: rigTop - dy,
          z: rigZ + dz,
          rot: euler(0, 0, math.pi / 2),
        ),
      );
    }
  }
  final heads = <_Head>[];
  const beamLen = 18.0;
  final beamGeo = cyl(0.09, 1.7, beamLen, 20, true);
  for (var i = 0; i < 5; i++) {
    final pan = Node(name: 'moving-head')
      ..position = vm.Vector3(Stage.minX + 1.4 + i * ((sw - 2.8) / 4), rigTop - 0.45, rigZ);
    pan.add(mesh(box(0.34, 0.06, 0.12), tc('#1d1d1d'), 0, 0.18, 0, false));
    final tilt = Node(name: 'tilt');
    tilt.add(mesh(cyl(0.13, 0.16, 0.36, 12), tc('#1d1d1d'), 0, -0.05, 0, false));
    final lens = UnlitMaterial()..baseColorFactor = linear(hex('#ffffff'));
    tilt.add(place(mesh(circleXY(0.11, 16), lens, 0, 0, 0, false), y: -0.232, rot: euler(math.pi / 2)));
    final beamMat = seeThrough('#ffffff', 0)..doubleSided = true;
    final beam = mesh(beamGeo, beamMat, 0, -0.24 - beamLen / 2, 0, false)
      ..frustumCulled = false
      ..raycastable = false;
    tilt.add(beam);
    pan.add(tilt);
    group.add(pan);
    heads.add(_Head(pan, tilt, beamMat, lens, i));
  }

  // Lasers from the front corners of the stage, fanning out over the dance floor into the sky.
  final lasers = <_Laser>[];
  var k = 0;
  for (final x in [Stage.minX + 2.2, Stage.maxX - 2.2]) {
    final mat = seeThrough(k == 1 ? '#ff2bd6' : '#39ff14', 0);
    final rays = <Node>[];
    for (var r = 0; r < _laserRays; r++) {
      final ray = mesh(box(0.015, 0.015, 70), mat, 0, 0, 0, false)
        ..frustumCulled = false
        ..raycastable = false
        ..visible = false;
      group.add(ray);
      rays.add(ray);
    }
    statics.add(mesh(box(0.3, 0.18, 0.3), tc('#1d1d1d'), x, Stage.height + 0.09, Stage.maxZ - 0.25, false));
    lasers.add(_Laser(rays, mat, vm.Vector3(x, Stage.height + 0.2, Stage.maxZ - 0.25), k));
    k++;
  }

  // ---- The dance floor ----------------------------------------------------------------------------
  final cols = (DanceFloor.maxX - DanceFloor.minX).round();
  final rows = (DanceFloor.maxZ - DanceFloor.minZ).round();
  final tiles = InstancedMesh(geometry: groundPlane(0.94, 0.94), material: UnlitMaterial());
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      tiles.addInstance(
        vm.Matrix4.translationValues(DanceFloor.minX + c + 0.5, 0.012, DanceFloor.minZ + r + 0.5),
        color: linear(const Color(0xFF222222)),
      );
    }
  }
  group.add(
    Node(name: 'dance-floor')
      ..addComponent(InstancedMeshComponent(tiles))
      ..castsShadows = false,
  );
  group.add(
    mesh(
      groundPlane(cols.toDouble(), rows.toDouble()),
      tc('#15141c'),
      (DanceFloor.minX + DanceFloor.maxX) / 2,
      0.008,
      (DanceFloor.minZ + DanceFloor.maxZ) / 2,
      false,
    ),
  );

  // ---- The bar ------------------------------------------------------------------------------------
  final bar = Node(name: 'bar');
  const bx = RoofBar.x;
  const blen = RoofBar.maxZ - RoofBar.minZ;
  const bz = (RoofBar.minZ + RoofBar.maxZ) / 2;
  const front = bx - RoofBar.depth / 2;
  bar.add(mesh(box(RoofBar.depth, RoofBar.height - 0.06, blen), tc('#6b3f2a'), bx, (RoofBar.height - 0.06) / 2, bz));
  // Slats up the front of it.
  for (var z = RoofBar.minZ + 0.25; z < RoofBar.maxZ; z += 0.5) {
    bar.add(mesh(box(0.03, RoofBar.height - 0.3, 0.08), tc('#8a5a3b'), front - 0.012, RoofBar.height / 2, z, false));
  }
  bar.add(mesh(box(RoofBar.depth + 0.2, 0.06, blen + 0.2), tc('#f4f1ea'), bx - 0.05, RoofBar.height - 0.03, bz));
  bar.add(
    place(
      mesh(cyl(0.03, 0.03, blen, 8), tc('#e9b949'), 0, 0, 0, false),
      x: front - 0.2,
      y: 0.22,
      z: bz,
      rot: euler(math.pi / 2),
    ),
  );
  // A glow along its foot that shifts colour with the music.
  final barGlow = UnlitMaterial()..baseColorFactor = linear(hex('#4cc9f0'));
  group.add(mesh(box(0.02, 0.05, blen), barGlow, front - 0.02, 0.06, bz, false));
  // Beer taps, and their handles.
  for (final (z, c) in const [(-0.6, '#ef476f'), (0.0, '#06d6a0'), (0.6, '#ffd166')]) {
    bar.add(mesh(cyl(0.035, 0.035, 0.4, 8), tc('#e9b949'), bx + 0.12, RoofBar.height + 0.2, z, false));
    bar.add(mesh(box(0.03, 0.16, 0.03), tc(c), bx + 0.05, RoofBar.height + 0.46, z, false));
  }
  colliders.add(
    Collider(minX: front, maxX: bx + RoofBar.depth / 2, minZ: RoofBar.minZ, maxZ: RoofBar.maxZ, top: RoofBar.height),
  );
  final barIts = [
    for (final z in const [-3.6, -0.6, 2.4]) Interactable(kind: InteractKind.bar, x: front - 0.7, z: z, radius: 1.7),
  ];
  interactables.addAll(barIts);
  tagInteract(bar, barIts[1]);

  // The back bar: shelves of bottles against a warm glow, along the east edge.
  const back = Floor.maxX - 0.35;
  final shelf = tc('#4a2c1d');
  bar.add(mesh(box(0.6, 1.0, blen - 0.6), shelf, back, 0.5, bz));
  final glowPanel = UnlitMaterial()..baseColorFactor = linear(hex('#ffb55a'));
  group.add(
    place(
      mesh(planeXY(blen - 1, 1.5), glowPanel, 0, 0, 0, false),
      x: Floor.maxX - 0.08,
      y: 1.85,
      z: bz,
      rot: yaw(-math.pi / 2),
    ),
  );
  final bottles = Node(name: 'bottles');
  const bottleColors = ['#2a9d8f', '#e9c46a', '#8ecae6', '#6a994e', '#bc4749', '#f4a261', '#dda15e'];
  var n = 0;
  for (final y in const [1.15, 1.65, 2.15]) {
    bar.add(mesh(box(0.4, 0.04, blen - 1), shelf, Floor.maxX - 0.24, y - 0.02, bz, false));
    for (var z = RoofBar.minZ + 0.8; z < RoofBar.maxZ - 0.6; z += 0.24) {
      final h = 0.26 + ((n * 7) % 5) * 0.03;
      final c = tc(bottleColors[n++ % bottleColors.length]);
      bottles.add(mesh(cyl(0.045, 0.05, h, 8), c, Floor.maxX - 0.25, y + h / 2, z, false));
      bottles.add(mesh(cyl(0.015, 0.03, 0.08, 6), c, Floor.maxX - 0.25, y + h + 0.04, z, false));
    }
  }
  group.add(mergeByMaterial(bottles));
  group.add(bar);
  colliders.add(
    Collider(minX: back - 0.3, maxX: Floor.maxX, minZ: RoofBar.minZ + 0.3, maxZ: RoofBar.maxZ - 0.3, top: 99),
  );

  // A pergola over it, hung with string lights, and a neon sign facing the dance floor.
  final wood = tc('#8a5a3b');
  final p0 = (x: front - 0.9, z: RoofBar.minZ - 0.8);
  const p1 = (x: Floor.maxX - 0.1, z: RoofBar.maxZ + 0.8);
  const roofY = 3.3;
  for (final x in [p0.x, p1.x]) {
    for (final z in [p0.z, p1.z]) {
      statics.add(mesh(box(0.16, roofY, 0.16), wood, x, roofY / 2, z));
      colliders.add(Collider(minX: x - 0.1, maxX: x + 0.1, minZ: z - 0.1, maxZ: z + 0.1, top: 99));
    }
    statics.add(mesh(box(0.16, 0.22, p1.z - p0.z + 0.3), wood, x, roofY, (p0.z + p1.z) / 2));
  }
  for (var z = p0.z; z <= p1.z + 0.01; z += 0.55) {
    statics.add(mesh(box(p1.x - p0.x + 0.4, 0.08, 0.1), wood, (p0.x + p1.x) / 2, roofY + 0.15, z));
  }
  final neon = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = linear(hex('#ff4fd8'));
  final sign = textPlane('🍸 SKY BAR', const TextOpts(color: '#ffe3fb', bg: '#2b0a26', border: '#ff4fd8', size: 104));
  group.add(place(sign, x: p0.x - 0.1, y: roofY - 0.4, z: bz, rot: yaw(-math.pi / 2), scale: 1.1));
  // A neon tube round the sign, which glows and hums.
  group.add(place(mesh(box(0.04, 0.05, 3.7), neon, 0, 0, 0, false), x: p0.x - 0.12, y: roofY - 0.4 + 0.5, z: bz));
  group.add(place(mesh(box(0.04, 0.05, 3.7), neon, 0, 0, 0, false), x: p0.x - 0.12, y: roofY - 0.4 - 0.5, z: bz));

  // The bartender, behind the bar, facing the counter.
  final bartender = Worker('Bartender', '#e76f51', labels)
    ..setStatus(WorkerStatus.idle, false)
    ..setTask(const WorkerTask(name: '🍸 Bartender', summary: "What'll it be? E at the bar"));
  const tendX = bx + RoofBar.depth / 2 + 0.7;
  bartender.root
    ..position = vm.Vector3(tendX, 0, bz)
    ..rotation = yaw(-math.pi / 2);
  group.add(bartender.root);

  // Bar stools along the counter.
  for (var i = 1; i <= 6; i++) {
    final s = seatingById['roof-stool-$i']!;
    final stool = Node(name: 'stool');
    stool.add(mesh(cyl(0.2, 0.25, 0.03, 16), steel, 0, 0.015, 0, false));
    stool.add(mesh(cyl(0.035, 0.035, 0.66, 8), steel, 0, 0.36, 0, false));
    stool.add(place(mesh(torusXY(0.16, 0.015, 6, 16), steel, 0, 0, 0, false), y: 0.32, rot: euler(math.pi / 2)));
    stool.add(mesh(cyl(0.22, 0.2, 0.1, 16), tc('#c1121f'), 0, 0.72, 0));
    stool.position = vm.Vector3(s.x, 0, s.z);
    _seatable(stool, s.id, 0.75, interactables);
    group.add(stool);
  }

  // String lights: over the pergola, and criss-crossing the dance floor from the rig to poles along the south side of it.
  final bulbMats = [
    for (final c in const ['#ffd166', '#ff8fa3', '#8ecae6', '#caffbf']) bulb(night, c, 0.45),
  ];
  final wire = tc(_ink);
  void festoon(vm.Vector3 a, vm.Vector3 b, double sag) {
    final pts = _festoonCurve(a, b, sag, 20);
    statics.add(mesh(tubeThrough(pts, 0.012, 4), wire, 0, 0, 0, false));
    var length = 0.0;
    for (var i = 1; i < pts.length; i++) {
      length += pts[i].distanceTo(pts[i - 1]);
    }
    final count = math.max(2, (length / 0.6).round());
    final fine = _festoonCurve(a, b, sag, count);
    for (var i = 1; i < count; i++) {
      final p = fine[i];
      statics.add(mesh(sphere(0.06, 8, 6), bulbMats[i % bulbMats.length], p.x, p.y - 0.06, p.z, false));
    }
  }

  for (var z = p0.z + 0.6; z < p1.z; z += 2.9) {
    festoon(vm.Vector3(p0.x, roofY - 0.1, z), vm.Vector3(p1.x, roofY - 0.1, z + 1.4), 0.25);
  }
  // (Two poles, one either side, so nothing stands between the dance floor and the DJ.)
  final poles = [
    for (final x in const [DanceFloor.minX - 0.6, DanceFloor.maxX + 0.6]) vm.Vector3(x, 3.4, DanceFloor.maxZ + 0.6),
  ];
  for (final p in poles) {
    statics.add(mesh(cyl(0.05, 0.07, 3.4, 8), tc(_ink), p.x, 1.7, p.z, false));
    statics.add(mesh(cyl(0.25, 0.3, 0.1, 12), tc(_ink), p.x, 0.05, p.z, false));
    colliders.add(Collider(minX: p.x - 0.12, maxX: p.x + 0.12, minZ: p.z - 0.12, maxZ: p.z + 0.12, top: 99));
  }
  final rigCorners = [
    vm.Vector3(Stage.minX + 0.2, rigTop - 0.6, rigZ),
    vm.Vector3(Stage.maxX - 0.2, rigTop - 0.6, rigZ),
  ];
  festoon(rigCorners[0], poles[1], 0.35);
  festoon(rigCorners[1], poles[0], 0.35);
  festoon(rigCorners[0], poles[0], 0.3);
  festoon(rigCorners[1], poles[1], 0.3);
  festoon(poles[0], poles[1], 0.4);
  festoon(poles[1], vm.Vector3(p0.x, roofY - 0.1, p0.z), 0.35);

  // ---- The lounge: sofas round a fire pit, open to the view ----------------------------------------
  final cushion = tc('#2a9d8f');
  final frame = tc('#f4f1ea');
  void sofa(String id, double len) {
    final s = seatingById[id]!;
    final g = Node(name: 'sofa');
    g.add(mesh(roundedBox(len, 0.3, 0.9, 0.08), frame, 0, 0.15, 0));
    g.add(mesh(roundedBox(len - 0.1, 0.16, 0.8, 0.08), cushion, 0, 0.38, 0.03));
    g.add(mesh(roundedBox(len, 0.5, 0.2, 0.08), cushion, 0, 0.6, -0.36));
    for (final sx in [-1, 1]) {
      g.add(mesh(roundedBox(0.16, 0.5, 0.9, 0.06), frame, sx * (len / 2 - 0.08), 0.35, 0));
    }
    g
      ..position = vm.Vector3(s.x, 0, s.z)
      ..rotation = yaw(s.rotY);
    _seatable(g, id, 1.6, interactables);
    group.add(g);
    colliders.add(_boxCollider(s.x, s.z, len, 0.9, s.rotY, 0.5));
  }

  sofa('roof-sofa-1', 3.4);
  sofa('roof-sofa-2', 2.2);
  sofa('roof-sofa-3', 2.2);
  statics.add(mesh(cyl(3.3, 3.3, 0.01, 40), tc('#f2cc8f'), FirePit.x, 0.006, FirePit.z + 0.3, false));
  statics.add(mesh(cyl(FirePit.r, FirePit.r + 0.05, 0.42, 20), tc('#8d99ae'), FirePit.x, 0.21, FirePit.z));
  statics.add(
    mesh(cyl(FirePit.r - 0.12, FirePit.r - 0.12, 0.02, 20), tc('#3d405b'), FirePit.x, 0.43, FirePit.z, false),
  );
  colliders.add(
    Collider(
      minX: FirePit.x - FirePit.r,
      maxX: FirePit.x + FirePit.r,
      minZ: FirePit.z - FirePit.r,
      maxZ: FirePit.z + FirePit.r,
      top: 0.42,
    ),
  );
  final flames = <w.Pivot>[];
  final flameMats = [
    for (final c in const ['#ff9f1c', '#ffbf69', '#ff5d2b']) seeThrough(c, 0.9),
  ];
  for (var i = 0; i < 7; i++) {
    final a = (i / 7) * math.pi * 2;
    final r = i == 0 ? 0.0 : 0.32;
    final flame = w.Pivot()..position = vm.Vector3(FirePit.x + math.cos(a) * r, 0.42, FirePit.z + math.sin(a) * r);
    flame.add(mesh(cone(0.16, 0.6, 8), flameMats[i % 3], 0, 0.3, 0, false)..raycastable = false);
    flames.add(flame);
    group.add(flame.node);
  }

  // Sun loungers along the south edge, a parasol between each pair, facing out over the street.
  for (var i = 1; i <= 3; i++) {
    final s = seatingById['roof-lounger-$i']!;
    final g = Node(name: 'lounger');
    g.add(mesh(box(0.72, 0.28, 1.9), frame, 0, 0.14, 0.15));
    g.add(mesh(box(0.66, 0.08, 1.3), tc('#f4a261'), 0, 0.32, 0.45));
    g.add(place(mesh(box(0.66, 0.08, 0.8), tc('#f4a261')), y: 0.55, z: -0.5, rot: euler(0.75)));
    g.position = vm.Vector3(s.x, 0, s.z);
    _seatable(g, s.id, 1.1, interactables);
    group.add(g);
    colliders.add(Collider(minX: s.x - 0.36, maxX: s.x + 0.36, minZ: s.z - 0.8, maxZ: s.z + 1.1, top: 0.36));
  }
  for (final x in const [-0.8, 2.0]) {
    const z = Floor.maxZ - 1.1;
    statics.add(mesh(cyl(0.04, 0.04, 2.6, 8), frame, x, 1.3, z, false));
    statics.add(mesh(cone(1.5, 0.5, 12, true), tc('#ef476f'), x, 2.6, z));
    statics.add(mesh(cyl(0.22, 0.22, 0.45, 12), frame, x, 0.225, z, false));
    statics.add(mesh(cyl(0.3, 0.3, 0.04, 12), frame, x, 0.47, z, false));
    colliders.add(Collider(minX: x - 0.3, maxX: x + 0.3, minZ: z - 0.3, maxZ: z + 0.3, top: 0.49));
  }

  // Tall tables to stand at between the elevator and the bar, with a candle each.
  final candle = bulb(night, '#ffbf69', 0.5);
  for (final t in roofTables) {
    statics.add(mesh(cyl(0.28, 0.32, 0.04, 16), tc(_ink), t.x, 0.02, t.z, false));
    statics.add(mesh(cyl(0.04, 0.04, 1.05, 8), tc(_ink), t.x, 0.55, t.z, false));
    statics.add(mesh(cyl(0.42, 0.42, 0.05, 20), tc('#f4f1ea'), t.x, 1.08, t.z));
    statics.add(mesh(cyl(0.035, 0.035, 0.1, 8), candle, t.x, 1.16, t.z, false));
    colliders.add(Collider(minX: t.x - 0.3, maxX: t.x + 0.3, minZ: t.z - 0.3, maxZ: t.z + 0.3, top: 1.1));
  }

  // Planters along the edges, and the air conditioning behind a screen in the north-east corner.
  final planter = tc('#6d6875');
  final leaf = tc('#5fb760');
  final leafDark = tc('#3f8f45');
  void planterRow(double x0, double x1, double z0, double z1) {
    statics.add(mesh(box(x1 - x0, 0.6, z1 - z0), planter, (x0 + x1) / 2, 0.3, (z0 + z1) / 2));
    final alongX = x1 - x0 > z1 - z0;
    final len = alongX ? x1 - x0 : z1 - z0;
    for (var a = 0.4; a < len - 0.2; a += 0.7) {
      final px = alongX ? x0 + a : (x0 + x1) / 2;
      final pz = alongX ? (z0 + z1) / 2 : z0 + a;
      statics.add(
        mesh(sphere(0.38 + ((a * 13) % 3).floor() * 0.06, 10, 8), a % 1.4 < 0.7 ? leaf : leafDark, px, 0.8, pz, false),
      );
    }
    colliders.add(Collider(minX: x0, maxX: x1, minZ: z0, maxZ: z1, top: 0.6));
  }

  planterRow(Floor.minX, Floor.minX + 0.7, Floor.minZ + 0.4, 3.2);
  planterRow(Floor.minX + 0.4, -6.2, Floor.maxZ - 0.7, Floor.maxZ);
  planterRow(5.2, Floor.maxX - 0.4, Floor.maxZ - 0.7, Floor.maxZ);
  const screenX = 10.9;
  const screenZ = -8.2;
  final slat = tc('#8d99ae');
  for (var z = Floor.minZ; z < screenZ; z += 0.3) {
    statics.add(mesh(box(0.06, 2.2, 0.14), slat, screenX, 1.1, z, false));
  }
  for (var x = screenX; x < Floor.maxX; x += 0.3) {
    statics.add(mesh(box(0.14, 2.2, 0.06), slat, x, 1.1, screenZ, false));
  }
  colliders.add(Collider(minX: screenX - 0.1, maxX: screenX + 0.1, minZ: Floor.minZ, maxZ: screenZ, top: 99));
  colliders.add(Collider(minX: screenX, maxX: Floor.maxX, minZ: screenZ - 0.1, maxZ: screenZ + 0.1, top: 99));
  final fans = <Node>[];
  for (final (x, z) in const [(13.2, -11.0), (16.2, -11.0)]) {
    statics.add(mesh(box(2.2, 1.3, 2.4), tc('#dfe3e8'), x, 0.65, z));
    statics.add(mesh(cyl(0.75, 0.75, 0.06, 20), tc('#565a75'), x, 1.31, z, false));
    final fan = Node(name: 'fan')..position = vm.Vector3(x, 1.36, z);
    for (var b = 0; b < 3; b++) {
      fan.add(place(mesh(box(1.2, 0.02, 0.22), tc('#2b2d42'), 0, 0, 0, false), rot: yaw((b / 3) * math.pi)));
    }
    group.add(fan);
    fans.add(fan);
  }

  group.add(mergeByMaterial(statics));

  final roof = Rooftop._(group, colliders, interactables, elevator)
    .._dj = dj
    .._bartender = bartender
    .._tendZ = bz
    .._tiles = tiles
    .._cols = cols
    .._rows = rows
    .._led = led
    .._strip = strip
    .._barGlow = barGlow
    .._glowPanel = glowPanel
    .._jog = jog
    .._neon = neon;
  roof._cones.addAll(cones);
  roof._fans.addAll(fans);
  roof._heads.addAll(heads);
  roof._lasers.addAll(lasers);
  roof._ledWords.addAll(words);
  roof._flames.addAll(flames);
  // Coloured washes over the dance floor, the bar's warm light and the fire's.
  for (final s in const [-1.0, 1.0]) {
    final wash = RoofLamp(
      (DanceFloor.minX + DanceFloor.maxX) / 2 + s * 2.6,
      3.6,
      (DanceFloor.minZ + DanceFloor.maxZ) / 2,
      15,
    );
    roof._washes.add(wash);
    roof.lamps.add(wash);
  }
  roof._barLamp = RoofLamp(bx + 1.2, 2.8, bz, 11);
  roof._fireLamp = RoofLamp(FirePit.x, 1.1, FirePit.z, 8);
  roof.lamps.addAll([roof._barLamp, roof._fireLamp]);
  roof._drawLed(djFrame(0), 0, true);
  return roof;
}
