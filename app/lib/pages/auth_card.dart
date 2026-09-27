// The card the sign-in, invite and claim pages share (login.css): a peach page with soft blobs, a
// paper card with the little desk-and-worker logo, a title and a line under it.

import 'package:flutter/material.dart';

import '../ui/theme.dart';

class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.title, this.sub, required this.children});

  final String title;
  final Widget? sub;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFFFE8CC),
        gradient: RadialGradient(
          center: Alignment(-0.6, -0.7),
          radius: 1.2,
          colors: [Color(0xFFFFD6A5), Color(0xFFFFE8CC), Color(0xFFCAFFBF)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Panel(
              radius: 22,
              shadow: 8,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: SizedBox(width: 72, height: 72, child: CustomPaint(painter: _Logo()))),
                    const SizedBox(height: 8),
                    Text(title, textAlign: TextAlign.center, style: heavy(26, weight: FontWeight.w900)),
                    if (sub != null) ...[
                      const SizedBox(height: 6),
                      DefaultTextStyle(
                        style: heavy(15, color: Swatch.muted, weight: FontWeight.w700),
                        textAlign: TextAlign.center,
                        child: sub!,
                      ),
                    ],
                    const SizedBox(height: 18),
                    ...children,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The error line under a form.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => text.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text, textAlign: TextAlign.center, style: heavy(14, color: Swatch.bad)),
        );
}

/// A full-width primary button, as the forms end with.
class WideButton extends StatelessWidget {
  const WideButton(this.label, {super.key, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Center(child: OfficeButton(label: label, kind: BtnKind.primary, onPressed: onPressed)),
  );
}

/// The logo from login.html: a desk, a laptop with a green screen, and a round orange worker.
class _Logo extends CustomPainter {
  const _Logo();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);
    final p = Paint();
    RRect rr(double x, double y, double w, double h, double r) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));
    canvas.drawRRect(rr(6, 30, 52, 8, 3), p..color = const Color(0xFFE0A96D));
    canvas.drawRRect(rr(18, 14, 28, 18, 3), p..color = Swatch.ink);
    canvas.drawRRect(rr(21, 17, 22, 12, 1), p..color = const Color(0xFF7CF29A));
    canvas.drawCircle(const Offset(32, 50), 9, p..color = Swatch.accent);
    p.color = const Color(0xFF222222);
    canvas.drawCircle(const Offset(29, 48), 1.8, p);
    canvas.drawCircle(const Offset(35, 48), 1.8, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
