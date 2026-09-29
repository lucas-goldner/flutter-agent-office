// Small pieces the office is built from, shared by its parts: glass, plants, pendant lamps,
// chairs, canvas textures, and the palette.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/floors.dart';

import '../text.dart';
import '../toon.dart';
import 'geo.dart';

abstract final class Palette {
  static final String floor = floorPalettes[0].floor;
  static final String floorAlt = floorPalettes[0].floorAlt;
  static final String wall = floorPalettes[0].wall;
  static final String wallTrim = floorPalettes[0].trim;
  static const desk = '#f7f3ea';
  static const deskLeg = '#3d405b';
  static const wood = '#c98b5a';
  static const cork = '#d8a86a';
  static const chairs = ['#ff8a5b', '#5bc0eb', '#9bc53d', '#b388eb', '#ffb400', '#f7aef8'];
  static const rugs = ['#bde0fe', '#ffd6a5', '#caffbf', '#ffc6ff'];
  static const plant = '#5fb760';
  static const plantDark = '#3f8f45';
  static const pot = '#e76f51';
  static const ink = '#2b2d42';

  /// The building's outside paint.
  static const exterior = '#e07a5f';
}

/// The cached toon material in colour '#rrggbb'.
Material tc(String h, {String? emissive}) => toon(hex(h), emissive: emissive == null ? null : hex(emissive));

/// An unlit, see-through material (three's MeshBasicMaterial with transparent: true, depthWrite: false).
UnlitMaterial seeThrough(String h, double opacity) => UnlitMaterial()
  ..alphaMode = AlphaMode.blend
  ..baseColorFactor = linear(hex(h), opacity);

/// An unlit, solid material (a screen, a mirror).
UnlitMaterial flat(String h) => UnlitMaterial()..baseColorFactor = linear(hex(h));

/// Window glass: faintly blue and see-through.
final UnlitMaterial glassMat = seeThrough('#d6f1ff', 0.14);
final UnlitMaterial shineMat = seeThrough('#ffffff', 0.22);

/// A sheet of glass w by h, centred, facing both ways, with a couple of cartoon glints so it reads as glass.
Node glassPane(double w, double h) {
  final g = group('glass');
  g.add(mesh(planeXY(w, h, both: true), glassMat, 0, 0, 0, false));
  for (final (gx, gw) in [(-w * 0.2, 0.18), (-w * 0.2 + 0.32, 0.08)]) {
    g.add(
      place(
        mesh(planeXY(gw, h * 0.55, both: true), shineMat, 0, 0, 0, false),
        x: gx,
        y: h * 0.07,
        z: 0.01,
        rot: euler(0, 0, -0.5),
      ),
    );
  }
  return g;
}

Node plant([double scale = 1]) {
  final g = group('plant');
  g.add(mesh(cyl(0.28, 0.22, 0.5, 12), tc(Palette.pot), 0, 0.25, 0));
  g.add(mesh(sphere(0.42, 12, 10), tc(Palette.plant), 0, 0.85, 0));
  g.add(mesh(sphere(0.3, 12, 10), tc(Palette.plantDark), 0.22, 1.1, 0.1));
  g.add(mesh(sphere(0.26, 12, 10), tc(Palette.plant), -0.2, 1.15, -0.08));
  g.scale = vm.Vector3.all(scale);
  return g;
}

/// A cartoon pendant lamp, its shade at 0, on a cord [cord] meters long.
Node pendant([double cord = 0.48]) {
  final lamp = group('pendant');
  final c = cord / 0.8;
  lamp.add(mesh(cyl(0.01, 0.01, c, 4), tc(Palette.ink), 0, c / 2, 0, false));
  lamp.add(mesh(cone(0.5, 0.45, 16, true), tc('#ffd166'), 0, 0, 0, false));
  lamp.add(mesh(sphere(0.16, 10, 8), tc('#fff7d6', emissive: '#ffe08a'), 0, -0.15, 0, false));
  lamp.scale = vm.Vector3.all(0.8);
  return lamp;
}

/// An office chair on five legs, facing -z (its back toward +z).
Node chair(String color) {
  final g = group('chair');
  final mat = tc(color);
  g.add(mesh(roundedBox(0.62, 0.1, 0.58, 0.12), mat, 0, 0.5, 0));
  g.add(place(mesh(roundedBox(0.62, 0.1, 0.6, 0.12), mat), y: 0.86, z: 0.27, rot: euler(math.pi / 2 - 0.12)));
  g.add(mesh(cyl(0.04, 0.04, 0.42, 8), tc(Palette.deskLeg), 0, 0.26, 0));
  for (var i = 0; i < 5; i++) {
    final a = i / 5 * math.pi * 2;
    g.add(
      place(
        mesh(box(0.05, 0.04, 0.32), tc(Palette.deskLeg)),
        x: math.sin(a) * 0.15,
        y: 0.05,
        z: math.cos(a) * 0.15,
        rot: yaw(a),
      ),
    );
  }
  return mergeByMaterial(g);
}

/// The floating green "+" over an empty seat.
Node vacancyMarker(double y) {
  final v = group('vacancy');
  final plusMat = tc('#7cf29a', emissive: '#1f7a3a');
  v.add(mesh(box(0.28, 0.08, 0.08), plusMat, 0, 0, 0, false));
  v.add(mesh(box(0.08, 0.28, 0.08), plusMat, 0, 0, 0, false));
  v.position = vm.Vector3(0, y, 0);
  return v;
}

/// Paints [w] x [h] pixels with [draw] and makes a texture of it (a CanvasTexture).
Future<Texture2D> canvasTexture(int w, int h, void Function(Canvas c) draw) {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  draw(c);
  final pic = rec.endRecording();
  return pictureTexture(pic, w, h).whenComplete(pic.dispose);
}

/// A flat fill of [color] (for canvas painting).
Paint fill(Color color) => Paint()..color = color;
