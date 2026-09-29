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
