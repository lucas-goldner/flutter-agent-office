// What you see of the sky and the weather: the stars, the sun and the moon riding along with you,
// halos round the bulbs at night, rain and snow falling outside (never under the building), and
// drops on the windows. The scene half of world/sky.ts; sky_model.dart works out the numbers.
// Everything is instanced, so each effect is one draw.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart';
import 'office/outside.dart' show NightParts;
import 'sky_model.dart';
import 'text.dart' show verticalPlane;
import 'toon.dart' show hex;

/// The building, walls included: the office upstairs and the garage under it.
abstract final class _B {
  static const double minX = Floor.minX - wallT, maxX = Floor.maxX + wallT;
  static const double minZ = Floor.minZ - wallT, maxZ = Floor.maxZ + wallT;
}

/// Is (x, z) under the building, where no rain or snow falls?
bool _sheltered(double x, double z) =>
    x > _B.minX - 0.05 && x < _B.maxX + 0.05 && z > _B.minZ - 0.05 && z < _B.maxZ + 0.05;

const int _rainN = 1500;
const int _snowN = 1800;
const int _starN = 700;

final vm.Matrix4 _hidden = vm.Matrix4.diagonal3Values(0, 0, 0);

class SkyView {
  SkyView(Node root, this._night, {math.Random? random}) : _rnd = random ?? math.Random() {
    // Stars, the sun and the moon, far off, always around you.
    _starMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    final stars = InstancedMesh(geometry: verticalPlane(0.45, 0.45), material: _starMat);
    for (var i = 0; i < _starN; i++) {
      final y = _rand(0.08, 1);
      final a = _rand(0, math.pi * 2);
      final r = math.sqrt(1 - y * y);
      final p = vm.Vector3(math.cos(a) * r * 170, y * 170, math.sin(a) * r * 170);
      stars.addInstance(_facing(p, vm.Vector3.zero(), 1));
    }
    _stars = _instanced('stars', stars);
    _sunMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    _moonMat = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = _lin(0xf2f1ea, 1);
    _sun = Node(name: 'sun', mesh: Mesh(SphereGeometry(radius: 5, segments: 24, rings: 16), _sunMat))..castsShadows = false;
    _moon = Node(name: 'moon', mesh: Mesh(SphereGeometry(radius: 3.2, segments: 24, rings: 16), _moonMat))..castsShadows = false;
    _dome
      ..add(_stars)
      ..add(_sun)
      ..add(_moon);
    root.add(_dome);

    // Halos round the bulbs at night.
    _haloMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    _halos = InstancedMesh(geometry: verticalPlane(1, 1), material: _haloMat, sortTransparentInstances: false);
    for (final h in _night.halos) {
      final c = hex(h.color);
      _halos.addInstance(_hidden, color: vm.Vector4(c.r, c.g, c.b, 1));
    }
    _haloNode = _instanced('halos', _halos);
    root.add(_haloNode);
    _blob(0.25).then((t) => _haloMat.baseColorTexture = t);

    // Rain: streaks falling around you (x, y, z, speed per drop), and snow the same way.
    _rainMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    _rain = InstancedMesh(geometry: verticalPlane(0.012, 0.5), material: _rainMat, sortTransparentInstances: false);
    for (var i = 0; i < _rainN; i++) {
      _drops.setAll(i * 4, [_rand(-24, 24), _rand(0, 26), _rand(-24, 24), _rand(14, 20)]);
      _rain.addInstance(_hidden);
    }
    _rainNode = _instanced('rain', _rain);
    _snowMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    _snow = InstancedMesh(geometry: verticalPlane(0.14, 0.14), material: _snowMat, sortTransparentInstances: false);
    for (var i = 0; i < _snowN; i++) {
      _flakes.setAll(i * 4, [_rand(-20, 20), _rand(0, 22), _rand(-20, 20), _rand(0.7, 1.3)]);
      _snow.addInstance(_hidden);
    }
    _snowNode = _instanced('snow', _snow);
    _blob(0.5).then((t) => _snowMat.baseColorTexture = t);
    root
      ..add(_rainNode)
      ..add(_snowNode);

    _glass = _WetGlass(_night);
  }

  final NightParts _night;
  final math.Random _rnd;
  final Node _dome = Node(name: 'sky-dome');
  late final Node _stars, _sun, _moon, _haloNode, _rainNode, _snowNode;
  late final UnlitMaterial _starMat, _sunMat, _moonMat, _haloMat, _rainMat, _snowMat;
  late final InstancedMesh _halos, _rain, _snow;
  final Float32List _drops = Float32List(_rainN * 4);
  final Float32List _flakes = Float32List(_snowN * 4);
  late final _WetGlass _glass;

  double _rand(double a, double b) => a + _rnd.nextDouble() * (b - a);

  static Node _instanced(String name, InstancedMesh m) => Node(name: name)
    ..addComponent(InstancedMeshComponent(m))
    ..castsShadows = false
    ..frustumCulled = false;

  /// A quad at [at] turned to face [eye], scaled [s].
  static vm.Matrix4 _facing(vm.Vector3 at, vm.Vector3 eye, double s, [double spin = 0]) {
    final back = (eye - at)..normalize();
    var right = vm.Vector3(0, 1, 0).cross(back);
    if (right.length2 < 1e-8) right = vm.Vector3(1, 0, 0);
    right.normalize();
    final up = back.cross(right);
    final m = vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(right.x, right.y, right.z, 0) * s)
      ..setColumn(1, vm.Vector4(up.x, up.y, up.z, 0) * s)
      ..setColumn(2, vm.Vector4(back.x, back.y, back.z, 0))
      ..setTranslation(at);
    return spin == 0 ? m : (m..rotateZ(spin));
  }

  /// Every frame: [cam] is the camera in office space.
  void update(double dt, double t, SkyModel m, vm.Vector3 cam) {
    // Stars, the sun and the moon ride along with you, so they look infinitely far off.
    _dome.position = cam;
    _starMat.baseColorFactor = vm.Vector4(1, 1, 1, m.starOpacity);
    _stars.visible = m.starOpacity > 0.01;
    vm.Vector3 up(double e, double a) => vm.Vector3(math.cos(e) * math.sin(a) * 160, math.sin(e) * 160, -math.cos(e) * math.cos(a) * 160);
    _sun.position = up(m.sunEl, m.sunAz);
    final sc = m.sunDiscColor;
    _sunMat.baseColorFactor = vm.Vector4(sc.r, sc.g, sc.b, m.sunDiscOpacity);
    _sun.visible = m.sunDiscOpacity > 0.01;
    _moon.position = up(-m.sunEl, m.sunAz + math.pi);
    _moonMat.baseColorFactor = _lin(0xf2f1ea, m.moonDiscOpacity);
    _moon.visible = m.moonDiscOpacity > 0.01;

    // Halos round the bulbs, when the lamps are on.
    _haloNode.visible = m.lampsOn > 0.01 && _night.halos.isNotEmpty;
    if (_haloNode.visible) {
      _haloMat.baseColorFactor = vm.Vector4(1, 1, 1, m.lampsOn * 0.85);
      final halos = _night.halos;
      for (var i = 0; i < halos.length; i++) {
        // Points in three.js were sized in world units at a 1 px ratio: roughly this big up close.
        _halos.setInstanceTransform(i, _facing(halos[i].at, cam, halos[i].size));
      }
    }

    // Rain and snow fall outside, lit about as much as everything else is.
    final lit = m.precipLit;
    final rc = SkyColors.rain.scale(lit);
    _rainMat.baseColorFactor = vm.Vector4(rc.r, rc.g, rc.b, 0.5);
    _snowMat.baseColorFactor = vm.Vector4(lit, lit, lit, 1);
    _fall(dt, t, m, cam);
    _glass.update(dt, m.rain, lit, _rnd);
  }

  void _fall(double dt, double t, SkyModel m, vm.Vector3 cam) {
    double wrap(double v, double c, double half) => v - c > half ? v - 2 * half : (v - c < -half ? v + 2 * half : v);

    final rainN = (_rainN * m.rain).round();
    _rainNode.visible = rainN > 0;
    if (rainN > 0) {
      final slant = 0.1 + 0.3 * m.storm;
      for (var i = 0; i < _rainN; i++) {
        final d = i * 4;
        if (i >= rainN) {
          _rain.setInstanceTransform(i, _hidden);
          continue;
        }
        final speed = _drops[d + 3];
        var x = wrap(_drops[d] + slant * speed * dt, cam.x, 24);
        var y = _drops[d + 1] - speed * dt;
        var z = wrap(_drops[d + 2], cam.z, 24);
        if (y < streetY) {
          y += 26;
          x = cam.x + _rand(-24, 24);
          z = cam.z + _rand(-24, 24);
        }
        _drops
          ..[d] = x
          ..[d + 1] = y
          ..[d + 2] = z;
        if (_sheltered(x, z)) {
          _rain.setInstanceTransform(i, _hidden);
          continue;
        }
        // A streak, turned round its length to face you, leaning with the wind.
        final yaw = math.atan2(cam.x - x, cam.z - z);
        _rain.setInstanceTransform(
          i,
          vm.Matrix4.translationValues(x, y + 0.25, z)
            ..rotateY(yaw)
            ..rotateZ(-slant * 0.9),
        );
      }
    }

    final snowN = (_snowN * m.snow).round();
    _snowNode.visible = snowN > 0;
    if (snowN > 0) {
      for (var i = 0; i < _snowN; i++) {
        final f = i * 4;
        if (i >= snowN) {
          _snow.setInstanceTransform(i, _hidden);
          continue;
        }
        final speed = _flakes[f + 3];
        var x = wrap(_flakes[f] + math.sin(t * 0.9 + i) * 0.3 * dt + 0.15 * dt, cam.x, 20);
        var y = _flakes[f + 1] - speed * dt;
        var z = wrap(_flakes[f + 2] + math.cos(t * 0.7 + i * 1.3) * 0.3 * dt, cam.z, 20);
        if (y < streetY) {
          y += 22;
          x = cam.x + _rand(-20, 20);
          z = cam.z + _rand(-20, 20);
        }
        _flakes
          ..[f] = x
          ..[f + 1] = y
          ..[f + 2] = z;
        _snow.setInstanceTransform(i, _sheltered(x, z) ? _hidden : _facing(vm.Vector3(x, y, z), cam, 1));
      }
    }
  }

  static vm.Vector4 _lin(int rgb, double a) {
    final c = Rgb.hex(rgb);
    return vm.Vector4(c.r, c.g, c.b, a);
  }

  /// Soft round blob, for halos and snowflakes: white, fading to nothing from [inner] out.
  static Future<Texture2D> _blob(double inner) async {
    const n = 64;
    final px = Uint8List(n * n * 4);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final r = math.sqrt(math.pow(x + 0.5 - n / 2, 2) + math.pow(y + 0.5 - n / 2, 2)) / (n / 2);
        final a = r >= 1 ? 0.0 : (r < inner ? 1 - (1 - 0.35) * r / inner : 0.35 * (1 - (r - inner) / (1 - inner)));
        final i = (y * n + x) * 4;
        px
          ..[i] = 255
          ..[i + 1] = 255
          ..[i + 2] = 255
          ..[i + 3] = (a * 255).round();
      }
    }
    return Texture2D.fromPixels(px, n, n);
  }
}

class _Drop {
  _Drop(this.x, this.y, this.r, this.life);
  double x, y, r;

  /// Running down the glass this fast (px/s), or 0 while it clings.
  double vy = 0, trail = 0, age = 0;
  final double life;
}

/// Raindrops on the windows: they land, cling, now and then run down, and dry off after the rain.
/// Painted a dozen times a second into a small tiling texture (90 cm of glass square).
class _WetGlass {
  _WetGlass(this._night);

  final NightParts _night;
  static const int _n = 128;
  final List<_Drop> _drops = [];
  final Uint8List _px = Uint8List(_n * _n * 4);
  double _since = 0, _spawn = 0;
  bool _shown = false;

  void update(double dt, double rain, double lit, math.Random rnd) {
    double rand(double a, double b) => a + rnd.nextDouble() * (b - a);
    _since += dt;
    _spawn += rain * 70 * dt;
    for (; _spawn >= 1; _spawn--) {
      if (_drops.length < 160) _drops.add(_Drop(rand(0, _n.toDouble()), rand(0, _n.toDouble()), rand(0.8, 2.2), rand(4, 12)));
    }
    for (final d in _drops) {
      d.age += dt;
      if (d.vy == 0 && d.r > 1.7 && rnd.nextDouble() < dt * 0.4) d.vy = rand(25, 70);
      if (d.vy != 0) {
        d.y += d.vy * dt;
        d.trail = math.min(d.trail + d.vy * dt, 35);
      }
    }
    _drops.removeWhere((d) => d.age >= d.life || d.y >= _n + 40);
    final show = _drops.isNotEmpty;
    if (show != _shown) {
      _shown = show;
      for (final p in _night.wetPanes) {
        p.visible = show;
      }
    }
    if (!show || _since < 0.08) return;
    _since = 0;
    _paint();
    _night.wetGlass
      ..baseColorTexture = Texture2D.fromPixels(_px, _n, _n)
      ..baseColorFactor = vm.Vector4(lit, lit, lit, 1);
  }

  void _paint() {
    _px.fillRange(0, _px.length, 0);
    void blend(int x, int y, int r, int g, int b, double a) {
      x %= _n;
      y %= _n;
      if (y < 0) y += _n;
      if (x < 0) x += _n;
      final i = (y * _n + x) * 4;
      final prev = _px[i + 3] / 255;
      final out = a + prev * (1 - a);
      if (out <= 0) return;
      _px
        ..[i] = ((r * a + _px[i] * prev * (1 - a)) / out).round()
        ..[i + 1] = ((g * a + _px[i + 1] * prev * (1 - a)) / out).round()
        ..[i + 2] = ((b * a + _px[i + 2] * prev * (1 - a)) / out).round()
        ..[i + 3] = (out * 255).round();
    }

    for (final d in _drops) {
      final fade = math.min(1.0, (d.life - d.age) / 1.5);
      // The trail it left running down, then the bead, its dark rim and a glint.
      if (d.trail > 0) {
        final w = math.max(1, (d.r * 0.7).round());
        for (var y = (d.y - d.trail).floor(); y < d.y; y++) {
          for (var x = 0; x < w; x++) {
            blend((d.x - w / 2).round() + x, y, 225, 238, 255, 0.22 * fade);
          }
        }
      }
      final r = d.r.ceil() + 1;
      for (var y = -r; y <= r; y++) {
        for (var x = -r; x <= r; x++) {
          final k = math.sqrt(x * x + (y / 1.15) * (y / 1.15)) / d.r;
          if (k > 1.05) continue;
          final px = (d.x + x).round(), py = (d.y + y).round();
          if (k > 0.8) {
            blend(px, py, 30, 50, 80, 0.5 * fade);
          } else {
            blend(px, py, 214, 230, 250, 0.5 * fade);
          }
          final gx = x + d.r * 0.35, gy = y + d.r * 0.4;
          if (math.sqrt(gx * gx + gy * gy) < d.r * 0.32) blend(px, py, 255, 255, 255, 0.85 * fade);
        }
      }
    }
  }
}
