// Text in the world: the flat signs of the old textPlane() (EXIT, the boards' names, the gong's
// plaque…). Labels that face the camera (name tags, task cards, bubbles) are Flutter widgets over
// the scene instead: see labels.dart.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../ui/theme.dart' show kFallback, kFont;
import 'toon.dart' show hex;

/// World units per canvas pixel, as the old client's TEXT_SCALE.
const double kTextScale = 0.0055;

class TextOpts {
  const TextOpts({this.color = '#2b2d42', this.bg, this.size = 48, this.border});

  final String color;

  /// A pill behind the text, when set.
  final String? bg;
  final double size;
  final String? border;
}

/// Paints [text] as the old client did: 800-weight, a pill of [TextOpts.bg] with a 5px border.
/// Returns the picture and its size in canvas pixels.
({ui.Picture picture, int w, int h}) paintText(String text, TextOpts o) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: kFont, fontFamilyFallback: kFallback, fontSize: o.size, fontWeight: FontWeight.w800, color: hex(o.color)),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = (tp.width + o.size).ceil();
  final h = (o.size * 1.6).ceil();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  if (o.bg != null) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(3, 3, w - 6.0, h - 6.0), Radius.circular(h / 2 - 3));
    c.drawRRect(r, Paint()..color = hex(o.bg!));
    c.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = hex(o.border ?? '#2b2d42'),
    );
  }
  tp.paint(c, Offset((w - tp.width) / 2, (h - tp.height) / 2 + o.size * 0.05));
  return (picture: rec.endRecording(), w: w, h: h);
}

/// A texture from a picture, drawn at [w] x [h] pixels.
Future<Texture2D> pictureTexture(ui.Picture picture, int w, int h) async {
  final image = await picture.toImage(math.max(1, w), math.max(1, h));
  try {
    return await Texture2D.fromImage(image);
  } finally {
    image.dispose();
  }
}

/// A flat sign: [text] on a plane facing +z, [kTextScale] world units a pixel, centred on the
/// node. Its texture fills in a frame or two later (painting is async on the web).
Node textPlane(String text, [TextOpts opts = const TextOpts()]) {
  final painted = paintText(text, opts);
  final w = painted.w * kTextScale, h = painted.h * kTextScale;
  final mat = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = vm.Vector4(1, 1, 1, 0);
  final node = Node(name: 'sign:$text', mesh: Mesh(verticalPlane(w, h), mat))..castsShadows = false;
  pictureTexture(painted.picture, painted.w, painted.h).then((tex) {
    mat.baseColorTexture = tex;
    mat.baseColorFactor = vm.Vector4(1, 1, 1, 1);
    painted.picture.dispose();
  });
  return node;
}

/// A w x h plane standing up, facing +z (three.js's PlaneGeometry), with UVs the right way up.
Geometry verticalPlane(double w, double h) {
  final x = w / 2, y = h / 2;
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: _f32([-x, -y, 0, x, -y, 0, x, y, 0, -x, y, 0]),
      normals: _f32([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
      texCoords: _f32([0, 1, 1, 1, 1, 0, 0, 0]),
      indices: [0, 1, 2, 0, 2, 3],
    ),
  );
}

Float32List _f32(List<double> v) => Float32List.fromList(v);
