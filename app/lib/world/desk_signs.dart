// Big signs hung from the ceiling over the desks (world/desksigns.ts; see shared floorplan.dart), naming
// what each one is for ("Operations", "Code cleanup"), so you can tell from across the room where to
// look. Each hangs over the far edge of its desk, facing the chair: stand behind whoever sits there and
// it's over their laptop. Desks come in back-to-back pairs, so a pair's two signs hang back to back too,
// and from either side you read the one for the desk on that side; while the other desk has none, the
// sign says the same on its back.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/floorplan.dart';
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import 'package:vector_math/vector_math.dart' as vm;

import '../ui/theme.dart' show kFallback, kFont;
import 'office/geo.dart';
import 'office/parts.dart' show canvasTexture, tc;
import 'toon.dart';

/// How big a sign is, how high its middle hangs, and how far apart its two cords are.
abstract final class SignSize {
  static const double width = 1.9;
  static const double height = 0.62;
  static const double depth = 0.04;
  static const double y = 3.35;
  static const double cords = 1.3;
}

const int _px = 1024;

/// Each desk's partner, back to back with it across the pair.
final Map<String, String> deskPartner = () {
  final all = [...desks, ...wingDesks];
  return {
    for (final d in all)
      for (final e in all)
        if (!identical(e, d) &&
            (e.x - d.x).abs() < 0.01 &&
            ((e.z - d.z).abs() - DeskSize.depth).abs() < 0.01 &&
            (math.cos(e.rotY) + math.cos(d.rotY)).abs() < 0.01)
          d.id: e.id,
  };
}();

TextStyle _font(double size, Color color) => TextStyle(
  fontFamily: kFont,
  fontFamilyFallback: kFallback,
  fontSize: size,
  fontWeight: FontWeight.w800,
  color: color,
);

double _measure(String text, double size) => (TextPainter(
  text: TextSpan(text: text, style: _font(size, const Color(0xFF000000))),
  textDirection: TextDirection.ltr,
)..layout()).width;

/// The text, as large as fits on one line, else on two.
({List<String> lines, double size}) fitSign(String text, double maxW, double maxH) {
  final words = text.split(' ');
  for (var size = 200.0; size >= 64; size -= 6) {
    if (size * 1.05 <= maxH && _measure(text, size) <= maxW) return (lines: [text], size: size);
    if (words.length < 2 || size * 2.1 > maxH) continue;
    // Split at the space that leaves the longer line shortest.
    List<String>? best;
    var bestW = double.infinity;
    for (var i = 1; i < words.length; i++) {
      final lines = [words.sublist(0, i).join(' '), words.sublist(i).join(' ')];
      final w = lines.map((l) => _measure(l, size)).reduce(math.max);
      if (w < bestW) {
        bestW = w;
        best = lines;
      }
    }
    if (best != null && bestW <= maxW) return (lines: best, size: size);
  }
  return (lines: [text], size: 64);
}

/// The sign's face: its paint, a line round the edge, and the text in the middle.
void paintSignFace(Canvas g, double w, double h, DeskLabel label) {
  final ink = hex(signInk(label.color));
  g.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = hex(label.color));
  g.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(22, 22, w - 44, h - 44), const Radius.circular(34)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..color = ink.withValues(alpha: 0.45),
  );
  final fit = fitSign(label.text, w - 120, h - 70);
  final lh = fit.size * 1.02;
  for (final (i, line) in fit.lines.indexed) {
    final tp = TextPainter(
      text: TextSpan(text: line, style: _font(fit.size, ink)),
      textDirection: TextDirection.ltr,
    )..layout();
    final cy = h / 2 + (i - (fit.lines.length - 1) / 2) * lh + fit.size * 0.04;
    tp.paint(g, Offset((w - tp.width) / 2, cy - tp.height / 2));
  }
}

class _Hung {
  _Hung(this.root, this.key);
  final Node root;
  final String key;
}

class DeskSigns {
  final Node group = Node(name: 'desk-signs');
  final Map<String, _Hung> _hung = {};
  final Material _cord = tc('#2b2d42');

  /// The sign over a desk, if it has one.
  Node? get(String deskId) => _hung[deskId]?.root;

  static String _keyOf(DeskLabel l, bool back) => '${l.text}|${l.color}|$back';

  /// Whether the sign over [id] says it on its back too: its partner across the pair has no sign of its own there.
  static bool twoSided(String id, Map<String, DeskLabel> labels, bool Function(DeskDef desk) built) {
    final other = deskPartner[id];
    final desk = other == null ? null : [...desks, ...wingDesks].where((d) => d.id == other).firstOrNull;
    return desk != null && built(desk) && !labels.containsKey(desk.id);
  }

  _Hung _make(DeskDef desk, DeskLabel label, bool back) {
    final root = Node(name: 'sign:${desk.id}')
      ..position = vm.Vector3(desk.x, 0, desk.z)
      ..rotation = yaw(desk.rotY);
    // Just off the far edge of the desk, so a back-to-back pair's signs don't touch.
    const z = -DeskSize.depth / 2 + SignSize.depth / 2 + 0.012;
    final parts = Node(name: 'sign-parts');
    parts.add(
      place(
        mesh(roundedBox(SignSize.width, SignSize.depth, SignSize.height, 0.08), toon(hex(label.color)), 0, 0, 0, false),
        y: SignSize.y,
        z: z,
        rot: euler(math.pi / 2),
      ),
    );
    const top = SignSize.y + SignSize.height / 2;
    for (final sx in const [-1.0, 1.0]) {
      const half = SignSize.cords / 2;
      parts.add(mesh(cyl(0.011, 0.011, wallHeight - top, 5), _cord, sx * half, (wallHeight + top) / 2, z, false));
      parts.add(mesh(cyl(0.05, 0.05, 0.03, 10), _cord, sx * half, wallHeight - 0.015, z, false));
      parts.add(mesh(sphere(0.028, 8, 6), _cord, sx * half, top + 0.01, z, false));
    }
    root.add(mergeByMaterial(parts));
    final face = UnlitMaterial()..baseColorFactor = linear(hex(label.color));
    const w = _px, h = _px * SignSize.height / SignSize.width;
    canvasTexture(w, h.round(), (g) => paintSignFace(g, w.toDouble(), h.roundToDouble(), label)).then((t) {
      face
        ..baseColorTexture = t
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
    });
    final plane = planeXY(SignSize.width - 0.06, SignSize.height - 0.06);
    root.add(
      Node(name: 'sign-face', mesh: Mesh(plane, face))
        ..position = vm.Vector3(0, SignSize.y, z + SignSize.depth / 2 + 0.003),
    );
    if (back) {
      root.add(
        Node(name: 'sign-back', mesh: Mesh(plane, face))
          ..position = vm.Vector3(0, SignSize.y, z - SignSize.depth / 2 - 0.003)
          ..rotation = yaw(math.pi),
      );
    }
    group.add(root);
    return _Hung(root, _keyOf(label, back));
  }

  /// Hangs a sign for each of [labels], over the desks [built] says are there (the back office's may not be yet).
  void set(Map<String, DeskLabel> labels, bool Function(DeskDef desk) built) {
    for (final id in [..._hung.keys]) {
      final l = labels[id];
      if (l != null && _keyOf(l, twoSided(id, labels, built)) == _hung[id]!.key) continue;
      _hung.remove(id)!.root.detach();
    }
    for (final MapEntry(key: id, value: label) in labels.entries) {
      final desk = [...desks, ...wingDesks].where((d) => d.id == id).firstOrNull;
      if (desk == null) continue;
      final h = _hung[id] ??= _make(desk, label, twoSided(id, labels, built));
      h.root.visible = built(desk);
    }
  }
}
