// A flat stand-in for the 3D character on the character select screen, until the world's Person
// model is handed in: a big chibi head with the look's skin and hair, on a shirt.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shared/avatar.dart';
import 'hud_parts.dart' show cssColor;
import 'theme.dart';

/// A flat stand-in for the 3D character: a big chibi head with its hair, on a shirt, on a rug.
class ChibiAvatar extends StatelessWidget {
  const ChibiAvatar({super.key, required this.look, required this.color});

  final Look look;
  final String color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: ChibiPainter(
      skin: cssColor(skinTones[look.skin]),
      hair: cssColor(hairColors[look.hair]),
      style: look.style,
      shirt: cssColor(color),
    ),
  );
}

class ChibiPainter extends CustomPainter {
  ChibiPainter({required this.skin, required this.hair, required this.style, required this.shirt});

  final Color skin;
  final Color hair;

  /// An index into [hairStyles]: Short, Long, Bun, Spiky, Curly, Ponytail, Bald.
  final int style;
  final Color shirt;

  static const _ink = Swatch.ink;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / 200, size.height / 280);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(s);
    canvas.translate(0, -10);
    final ink = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round;
    Paint fill(Color c) => Paint()..color = c;
    void shape(Path p, Color c) {
      canvas.drawPath(p, fill(c));
      canvas.drawPath(p, ink);
    }

    // The rug.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, 128), width: 170, height: 34),
      fill(const Color(0xFFFFD6A5)),
    );

    // Hair that hangs behind the head.
    final head = Rect.fromCenter(center: const Offset(0, -20), width: 150, height: 140);
    switch (style) {
      case 1: // Long
        shape(
          Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(-80, -40, 160, 130), const Radius.circular(40))),
          hair,
        );
      case 5: // Ponytail
        shape(Path()..addOval(Rect.fromCenter(center: const Offset(70, 20), width: 44, height: 86)), hair);
    }

    // The body in its shirt, arms and all.
    final body = Path()
      ..moveTo(-52, 118)
      ..quadraticBezierTo(-56, 50, -30, 42)
      ..lineTo(30, 42)
      ..quadraticBezierTo(56, 50, 52, 118)
      ..close();
    shape(body, shirt);
    for (final side in [-1.0, 1.0]) {
      shape(Path()..addOval(Rect.fromCenter(center: Offset(side * 58, 96), width: 22, height: 22)), skin);
    }

    // The head.
    shape(Path()..addOval(head), skin);
    for (final side in [-1.0, 1.0]) {
      shape(Path()..addOval(Rect.fromCenter(center: Offset(side * 75, -12), width: 20, height: 26)), skin);
    }

    // Hair on top.
    switch (style) {
      case 6: // Bald: a little shine.
        canvas.drawArc(
          Rect.fromCenter(center: const Offset(-18, -62), width: 40, height: 20),
          math.pi,
          1.2,
          false,
          ink..color = Colors.white,
        );
        ink.color = _ink;
      case 3: // Spiky: points all round the top, under a cap.
        Offset on(double a, double k) => Offset(math.cos(a) * 75 * k, -20 + math.sin(a) * 70 * k);
        for (var i = 0; i < 7; i++) {
          final a = math.pi + 0.3 + i * (math.pi - 0.6) / 6;
          shape(
            Path()
              ..moveTo(on(a - 0.22, 0.9).dx, on(a - 0.22, 0.9).dy)
              ..lineTo(on(a, 1.38).dx, on(a, 1.38).dy)
              ..lineTo(on(a + 0.22, 0.9).dx, on(a + 0.22, 0.9).dy)
              ..close(),
            hair,
          );
        }
        _cap(canvas, fill(hair), ink);
      case 4: // Curly
        for (var i = 0; i < 7; i++) {
          final a = math.pi + i * math.pi / 6;
          shape(
            Path()..addOval(Rect.fromCircle(center: Offset(math.cos(a) * 64, -30 + math.sin(a) * 56), radius: 22)),
            hair,
          );
        }
      default: // Short, Long, Bun, Ponytail: a cap of hair with a side fringe.
        _cap(canvas, fill(hair), ink);
        if (style == 2) {
          shape(Path()..addOval(Rect.fromCenter(center: const Offset(0, -102), width: 50, height: 40)), hair);
        }
    }

    // The face.
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(Rect.fromCenter(center: Offset(side * 26, -6), width: 14, height: 20), fill(_ink));
      canvas.drawCircle(Offset(side * 26 - 2, -10), 3, fill(Colors.white));
      canvas.drawOval(
        Rect.fromCenter(center: Offset(side * 42, 16), width: 18, height: 10),
        fill(const Color(0x55FF8A8A)),
      );
    }
    canvas.drawArc(
      Rect.fromCenter(center: const Offset(0, 18), width: 22, height: 14),
      0.2,
      math.pi - 0.4,
      false,
      ink..strokeWidth = 3.5,
    );
  }

  /// A cap of hair with a side fringe.
  static void _cap(Canvas canvas, Paint fill, Paint ink) {
    final cap = Path()
      ..moveTo(-77, -8)
      ..cubicTo(-86, -110, 86, -110, 77, -8)
      ..quadraticBezierTo(40, -58, -10, -50)
      ..quadraticBezierTo(-50, -40, -77, -8)
      ..close();
    canvas.drawPath(cap, fill);
    canvas.drawPath(cap, ink);
  }

  @override
  bool shouldRepaint(ChibiPainter old) =>
      old.skin != skin || old.hair != hair || old.style != style || old.shirt != shirt;
}
