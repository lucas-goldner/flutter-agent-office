// The wind-up meter over the hint while you hold E with the ball (or swing at the golf tee): how far
// it's run up, and with the ball aimed at the hoop, the green band where the shot drops in.

import 'package:flutter/material.dart';
import 'package:office_shared/hoop.dart' show Sweet;

import 'theme.dart';

class ShotMeterBar extends StatelessWidget {
  const ShotMeterBar({super.key, required this.at, this.sweet = false});

  /// 0–1 up the meter.
  final double at;

  /// Show the sweet spot.
  final bool sweet;

  static const double width = 260;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: width,
      height: 18,
      decoration: BoxDecoration(
        color: Swatch.paper,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Swatch.ink, width: kBorder),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          children: [
            if (sweet)
              Positioned(
                left: (Sweet.at - Sweet.width / 2) * (width - 6),
                width: Sweet.width * (width - 6),
                top: 0,
                bottom: 0,
                child: const ColoredBox(color: Color(0xFF7CF29A)),
              ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: at.clamp(0, 1) * (width - 6),
              child: const ColoredBox(color: Color(0xAAFF8A5B)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The golf panel at the top while you're on the tee: which hole, the power meter (with your last
/// shot marked), the loft and the aim.
class GolfPanelView extends StatelessWidget {
  const GolfPanelView(this.panel, {super.key});

  final ({double power, double last, String info}) panel;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        color: Swatch.paper,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink, width: kBorder),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('⛳ Hole 1 · 43 m · Par 1', style: heavy(14)),
          const SizedBox(height: 6),
          Stack(
            clipBehavior: Clip.none,
            children: [
              ShotMeterBar(at: panel.power),
              if (panel.last >= 0)
                Positioned(
                  left: 3 + panel.last.clamp(0, 1) * (ShotMeterBar.width - 6) - 1.5,
                  top: -3,
                  bottom: -3,
                  width: 3,
                  child: const ColoredBox(color: Swatch.ink),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(panel.info, style: heavy(12.5, color: Swatch.muted)),
        ],
      ),
    ),
  );
}
