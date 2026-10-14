// The beacon over a worker that needs you (features/needsyou/world.ts): a red pin with a "!" above its card,
// a pillar of light going up from its desk, and rings spreading out over the floor around it. It's there to
// be seen from the far side of the office, so it thins out as you walk up to read what the worker's asking.
//
// The pillar and the rings are see-through meshes in the office (under the mirrored root, so the numbers
// are three's); the pin is a label (world/labels.dart) like the cards and bubbles it floats over.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'labels.dart';
import 'office/geo.dart' show ringXY;
import 'text.dart' show pictureTexture;
import 'toon.dart' show linear;

const _red = Color(0xFFEF476F);
const _ink = Color(0xFF2B2D42);

/// The light is a stronger red than the pin: it's see-through, and the walls behind it are warm.
const _light = Color(0xFFFF2D5F);

/// How high the pillar of light goes (m): past the top of any card, short of the office's ceiling.
const double beamHeight = 5.6;

/// The pin: how wide and tall it is (m), how far over the worker's card its point floats, and how it grows
/// with distance so it's never a speck: its full size up to [full] m away, then as big as it looked there,
/// up to [most] times over.
const ({double w, double h, double gap, double full, double most}) pinSize = (
  w: 0.5,
  h: 0.645,
  gap: 0.12,
  full: 6,
  most: 3,
);

/// The rings on the floor: how many, how far each spreads (m), and how many seconds it takes.
const ({int n, double from, double to, double every}) beaconRings = (n: 2, from: 0.6, to: 2.3, every: 2);

/// How close (m) the beacon's light is gone altogether, and how far off it's at its brightest.
const double beaconNear = 3;
const double beaconFar = 6.5;

/// 0 from across the room up to 1 with you right beside it ([d] m away).
double beaconNearness(double d) => 1 - ((d - beaconNear) / (beaconFar - beaconNear)).clamp(0.0, 1.0);

/// How the beacon looks this frame, worked out without the engine (tested): the pin's size and lift, the
/// pillar's opacity, and each ring's scale and opacity (null: hidden).
({double pinScale, double pinBob, double beam, List<({double scale, double opacity})?> rings}) beaconLook({
  required double away,
  required double t,
  required double near,
  required bool calm,
}) {
  final beat = calm ? 0.0 : math.sin(t * 6.4);
  final size = (1 + beat * 0.09) * math.min(pinSize.most, math.max(1.0, away / pinSize.full));
  // Up close the light would only get between you and the laptop.
  final far = 1 - near;
  return (
    pinScale: size,
    pinBob: calm ? 0.0 : math.sin(t * 3.2) * 0.06,
    beam: far > 0.02 ? (0.64 + beat * 0.14) * far : 0.0,
    rings: [
      for (var i = 0; i < beaconRings.n; i++)
        if (calm && i > 0)
          null
        else
          () {
            final p = calm ? 0.4 : (t / beaconRings.every + i / beaconRings.n) % 1;
            return (
              scale: beaconRings.from + (beaconRings.to - beaconRings.from) * p,
              opacity: (calm ? 0.7 : math.pow(1 - p, 1.4) * 0.9) * (1 - near * 0.6),
            );
          }(),
    ],
  );
}

Geometry? _beamShape;
Future<Texture2D>? _beamTexture;

/// An open tube from y 0 to 1, wider at the foot (three's CylinderGeometry(0.4, 0.55, 1, 24, 1, true)
/// moved up by half), its v running from the foot (1) to the top (0); both faces, since the engine culls
/// the back ones.
Geometry _tube() {
  const seg = 24, top = 0.4, foot = 0.55;
  final p = <double>[], uv = <double>[];
  for (var i = 0; i < seg; i++) {
    final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
    final u0 = i / seg, u1 = (i + 1) / seg;
    final b0 = [foot * math.sin(a0), 0.0, foot * math.cos(a0)], b1 = [foot * math.sin(a1), 0.0, foot * math.cos(a1)];
    final t0 = [top * math.sin(a0), 1.0, top * math.cos(a0)], t1 = [top * math.sin(a1), 1.0, top * math.cos(a1)];
    void tri(
      List<double> a,
      double ua,
      double va,
      List<double> b,
      double ub,
      double vb,
      List<double> c,
      double uc,
      double vc,
    ) {
      p
        ..addAll(a)
        ..addAll(b)
        ..addAll(c);
      uv.addAll([ua, va, ub, vb, uc, vc]);
      p
        ..addAll(a)
        ..addAll(c)
        ..addAll(b);
      uv.addAll([ua, va, uc, vc, ub, vb]);
    }

    tri(b0, u0, 1, b1, u1, 1, t1, u1, 0);
    tri(b0, u0, 1, t1, u1, 0, t0, u0, 0);
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(positions: Float32List.fromList(p), texCoords: Float32List.fromList(uv)),
  );
}

/// The pillar's light, from the floor up: thin where the worker and its laptop are, so they still show
/// through it, strongest over its head where there's only air, and gone by the top.
Future<Texture2D> _beamPicture() {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, 4, 128),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 128),
        Offset.zero,
        const [Color(0x80FFFFFF), Color(0x6BFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        const [0, 0.3, 0.5, 1],
      ),
  );
  return pictureTexture(rec.endRecording(), 4, 128);
}

/// A see-through red that's drawn over the room without hiding what's behind it.
UnlitMaterial _glow() => UnlitMaterial()
  ..baseColorFactor = linear(_light, 0)
  ..alphaMode = AlphaMode.blend
  ..doubleSided = true;

class NeedsYouBeacon {
  NeedsYouBeacon(LabelHub labels, Node worker) : _labels = labels {
    _beamMat = _glow();
    (_beamTexture ??= _beamPicture()).then((t) => _beamMat.baseColorTexture = t);
    _beam = Node(name: 'needs-you-beam', mesh: Mesh(_beamShape ??= _tube(), _beamMat))
      ..castsShadows = false
      ..frustumCulled = false;
    root.add(_beam);
    for (var i = 0; i < beaconRings.n; i++) {
      final mat = _glow();
      _ringMats.add(mat);
      final ring = Node(name: 'needs-you-ring', mesh: Mesh(ringXY(0.88, 1, 56, true), mat))
        ..castsShadows = false
        ..frustumCulled = false;
      _rings.add(ring);
      root.add(ring);
    }
    pin = labels.add(
      WorldLabel(
        anchor: worker,
        offset: vm.Vector3(0, 2.1, 0),
        maxDistance: 60,
        scaleWithDistance: false,
        priority: 10,
        child: const _Pin(1),
      ),
    );
  }

  final LabelHub _labels;

  /// Goes in the office, not on the worker: it stays upright and the same size whatever the worker's doing.
  final Node root = Node(name: 'needs-you');
  late final Node _beam;
  late final UnlitMaterial _beamMat;
  final List<Node> _rings = [];
  final List<UnlitMaterial> _ringMats = [];
  late final WorldLabel pin;

  /// Where the worker is this frame and how it looks from where you are. [at] is the worker (office space,
  /// its feet more or less), [floor] the height of the floor under it, [top] the top of its card over the
  /// worker's origin, and [away] how far the camera is (m). [near] is 0 from across the room up to 1
  /// with you right beside it, and [calm] is for someone who has asked for less motion.
  void update(vm.Vector3 at, double floor, double top, double away, double t, double near, bool calm) {
    root.localTransform = vm.Matrix4.translationValues(at.x, floor, at.z);
    final look = beaconLook(away: away, t: t, near: near, calm: calm);
    _beam.visible = look.beam > 0;
    _beam.localTransform = vm.Matrix4.diagonal3Values(1, beamHeight, 1);
    _beamMat.baseColorFactor = linear(_light, look.beam);
    for (var i = 0; i < _rings.length; i++) {
      final r = look.rings[i];
      _rings[i].visible = r != null;
      if (r == null) continue;
      // Flat on the floor: three's ring lies in XY, turned -90° about x.
      _rings[i].localTransform = vm.Matrix4.translationValues(0, 0.03 + i * 0.004, 0)
        ..rotateX(-math.pi / 2)
        ..scaleByDouble(r.scale, r.scale, r.scale, 1);
      _ringMats[i].baseColorFactor = linear(_light, r.opacity);
    }
    pin
      ..offset.y = top + pinSize.gap + look.pinBob
      ..child = _Pin(look.pinScale);
  }

  void dispose() {
    root.parent?.remove(root);
    _labels.remove(pin);
  }
}

/// The pin's picture: a red drop with its point down, inked round, and a white "!" in it. [scale] is how
/// much bigger than at arm's length it's drawn.
class _Pin extends StatelessWidget {
  const _Pin(this.scale);
  final double scale;

  @override
  Widget build(BuildContext context) {
    // 0.5 m wide, at about 80 px a metre at the distance labels are drawn full size.
    final w = 40 * scale.clamp(1.0, pinSize.most);
    return IgnorePointer(
      child: SizedBox(
        width: w,
        height: w * pinSize.h / pinSize.w,
        child: const CustomPaint(painter: _PinPainter()),
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  const _PinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 248×320 canvas, as the old one was.
    canvas.scale(size.width / 248, size.height / 320);
    const cx = 124.0, cy = 112.0, r = 100.0;
    final path = Path()
      ..addArc(Rect.fromCircle(center: const Offset(cx, cy), radius: r), math.pi * 0.82, math.pi * 1.36)
      ..lineTo(cx, 308)
      ..close();
    canvas.drawPath(path, Paint()..color = _red);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeJoin = StrokeJoin.round
        ..color = _ink,
    );
    final tp = TextPainter(
      text: const TextSpan(
        text: '!',
        style: TextStyle(fontFamily: 'Nunito', fontSize: 150, fontWeight: FontWeight.w900, color: Color(0xFFFFFFFF)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy + 8 - tp.height / 2));
  }

  @override
  bool shouldRepaint(_PinPainter old) => false;
}
