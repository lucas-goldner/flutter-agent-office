// Looking through the boss-loft telescope: a dark ocular housing round the view, a tint on the glass,
// a faint focus reticle in the middle and a button to step away (the old #telescope-view).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

class TelescopeOverlay extends StatelessWidget {
  const TelescopeOverlay({super.key, required this.showing, required this.onExit});

  final ValueListenable<bool> showing;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: showing,
    builder: (context, on, _) => !on
        ? const SizedBox.shrink()
        : LayoutBuilder(
            builder: (context, box) {
              final vmin = box.biggest.shortestSide / 100;
              final half = box.biggest.longestSide / 2;
              double stop(double v) => (v * vmin / half).clamp(0.0, 1.0);
              return Stack(
                children: [
                  // The housing: dark beyond the eyepiece's round edge.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            radius: 1,
                            colors: const [Color(0x00000000), Color(0x00000000), Color(0xB8080A12), Color(0xFF080A12)],
                            stops: [0, stop(39), stop(43), stop(48)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // The glass: a cool tint toward its rim.
                  Center(
                    child: IgnorePointer(
                      child: Container(
                        width: 90 * vmin,
                        height: 90 * vmin,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [Color(0x00000000), Color(0x00000000), Color(0x4D08121C), Color(0xC203070E)],
                            stops: [0, 0.52, 0.72, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: IgnorePointer(child: _Reticle(size: 8 * vmin)),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 5 * vmin,
                    child: Center(
                      child: OfficeButton(label: 'Exit telescope · Esc', onPressed: onExit),
                    ),
                  ),
                ],
              );
            },
          ),
  );
}

class _Reticle extends StatelessWidget {
  const _Reticle({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.5,
    height: size * 1.5,
    child: CustomPaint(painter: _ReticlePainter(size)),
  );
}

class _ReticlePainter extends CustomPainter {
  _ReticlePainter(this.ring);
  final double ring;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      ring / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0x4DE6F5F5),
    );
    final line = Paint()..color = const Color(0x47E6F5F5);
    canvas
      ..drawLine(c.translate(0, -ring * 0.75), c.translate(0, ring * 0.75), line)
      ..drawLine(c.translate(-ring * 0.75, 0), c.translate(ring * 0.75, 0), line);
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.ring != ring;
}
