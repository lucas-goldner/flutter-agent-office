// The whiteboard: a rolling whiteboard on casters out on the open floor, with a marker tray. Its
// face shows whatever everyone has drawn on it (see ui/whiteboard.ts), live.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../shared/layout.dart' as lay;
import '../../ui/theme.dart' show kFallback, kFont;
import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';

const _alu = '#aab4be';
const _ink = '#2b2d42';

/// The face's canvas, in pixels per metre.
const int _px = 512;

/// Clear space around a drawing on the face, in pixels.
const int _pad = 40;

class WhiteboardStand {
  WhiteboardStand._(this.group, this.colliders, this.interactable, this.face, this._mat);

  final Node group;
  final List<Collider> colliders;

  /// Walk up and press E.
  final Interactable interactable;

  /// The writing surface (a +z-facing plane, [lay.Whiteboard.width] x [lay.Whiteboard.height]).
  final Node face;
  final UnlitMaterial _mat;
  int _paints = 0;

  static final int _w = (lay.Whiteboard.width * _px).round();
  static final int _h = (lay.Whiteboard.height * _px).round();

  /// How big a drawing fills the face, in pixels.
  ({int width, int height}) get fit => (width: _w - _pad * 2, height: _h - _pad * 2);

  /// Puts a drawing on the face (scaled to fit), or the "come and draw" note when there's none.
  Future<void> show(ui.Image? drawing) async {
    final ticket = ++_paints;
    final w = _w.toDouble(), h = _h.toDouble();
    final t = await canvasTexture(_w, _h, (g) {
      g.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFFFFFFF));
      // A faint shine across the top corner, so it reads as a glossy board from across the room.
      g.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(w * 0.5, h * 0.6), [
            const Color.fromRGBO(210, 225, 240, 0.55),
            const Color.fromRGBO(210, 225, 240, 0),
          ]),
      );
      if (drawing != null) {
        final s = math.min((w - _pad * 2) / drawing.width, (h - _pad * 2) / drawing.height);
        final dw = drawing.width * s, dh = drawing.height * s;
        g.drawImageRect(
          drawing,
          Rect.fromLTWH(0, 0, drawing.width.toDouble(), drawing.height.toDouble()),
          Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        void line(String s, double size, FontWeight weight, double y) {
          final tp = TextPainter(
            text: TextSpan(text: s, style: TextStyle(fontFamily: kFont, fontFamilyFallback: kFallback, fontSize: size, fontWeight: weight, color: hex('#b8c0c8'))),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(g, Offset((w - tp.width) / 2, y - tp.height / 2));
        }

        line('Draw together ✏️', 120, FontWeight.w900, h / 2 - 70);
        line('Walk up and press E — everyone on this floor sees it live', 64, FontWeight.w700, h / 2 + 70);
      }
    });
    if (ticket == _paints) _mat.baseColorTexture = t;
  }

  /// Puts a ready-made texture on the face as it is.
  void showTexture(Texture2D t) {
    ++_paints;
    _mat.baseColorTexture = t;
  }
}

WhiteboardStand buildWhiteboard() {
  const x = lay.Whiteboard.x, z = lay.Whiteboard.z, width = lay.Whiteboard.width, height = lay.Whiteboard.height;
  const bottom = lay.Whiteboard.bottom;
  final group = Node(name: 'whiteboard')..position = vm.Vector3(x, 0, z);
  final alu = tc(_alu);
  final ink = tc(_ink);
  const mid = bottom + height / 2;
  const post = width / 2 + 0.1;
  // The stand never moves: merged at the end.
  final stat = Node(name: 'stand');

  // The writing surface in its aluminium frame; the back is a plain grey panel.
  stat.add(place(mesh(roundedBox(width + 0.14, 0.07, height + 0.14, 0.04), alu), y: mid, rot: euler(math.pi / 2)));
  final faceMat = UnlitMaterial();
  final face = mesh(planeXY(width, height), faceMat, 0, mid, 0.04, false);
  group.add(face);

  // Two posts on feet with a caster at each end, and a bar across the bottom.
  for (final sx in [-post, post]) {
    stat.add(mesh(cyl(0.035, 0.035, bottom + height + 0.2, 10), alu, sx, (bottom + height + 0.2) / 2 + 0.1, 0));
    stat.add(mesh(roundedBox(0.09, 0.07, 0.95, 0.03), alu, sx, 0.13, 0));
    for (final sz in [-0.42, 0.42]) {
      stat.add(place(mesh(cyl(0.055, 0.055, 0.04, 12), ink, 0, 0, 0, false), x: sx, y: 0.055, z: sz, rot: euler(0, 0, math.pi / 2)));
    }
    stat.add(mesh(sphere(0.05, 10, 8), alu, sx, bottom + height + 0.3, 0, false));
  }
  stat.add(mesh(transformed(cyl(0.025, 0.025, post * 2, 8), rotZ(math.pi / 2)), alu, 0, 0.3, 0, false));

  // The marker tray, with markers and an eraser in it.
  const trayY = bottom - 0.1;
  stat.add(mesh(roundedBox(width * 0.55, 0.04, 0.14, 0.02), alu, 0, trayY, 0.09));
  stat.add(mesh(box(width * 0.55, 0.05, 0.015), alu, 0, trayY + 0.03, 0.155, false));
  const markers = ['#2b2d42', '#ef476f', '#118ab2', '#06d6a0'];
  for (var i = 0; i < markers.length; i++) {
    final marker = Node(name: 'marker');
    marker.add(mesh(cyl(0.018, 0.018, 0.13, 8), tc('#f8f9fa'), 0, 0, 0, false));
    marker.add(mesh(cyl(0.02, 0.02, 0.045, 8), tc(markers[i]), 0, 0.085, 0, false));
    stat.add(place(marker, x: -0.55 + i * 0.2, y: trayY + 0.04, z: 0.1, rot: euler(0, 0, math.pi / 2 + (i.isOdd ? 0.08 : -0.06))));
  }
  stat.add(mesh(roundedBox(0.2, 0.06, 0.08, 0.02), tc('#ffd166'), 0.62, trayY + 0.05, 0.09, false));
  stat.add(mesh(box(0.19, 0.015, 0.075), tc('#6c757d'), 0.62, trayY + 0.015, 0.09, false));

  group.add(place(textPlane('📝 Whiteboard', const TextOpts(bg: '#fffaf3', size: 48)), y: bottom + height + 0.2, z: 0.05, scale: 0.55));

  group.add(mergeByMaterial(stat));
  final interactable = Interactable(kind: InteractKind.whiteboard, x: x, z: z + 1.7, radius: 2.3);
  tagInteract(group, interactable);
  final stand = WhiteboardStand._(group, whiteboardColliders(), interactable, face, faceMat);
  stand.show(null);
  return stand;
}
