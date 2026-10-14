// The panel at the dart board or the axe lane (the old #throw): which throw of the round is next, the
// meter with its green (where a dart flies true and an axe sticks) and your last throw marked, and the
// round so far.

import 'package:flutter/material.dart';
import 'package:office_shared/bargames.dart';

import '../office/throwing.dart' show ThrowPanel;
import 'theme.dart';

class ThrowPanelView extends StatelessWidget {
  const ThrowPanelView(this.panel, {super.key});

  final ThrowPanel panel;

  static const double width = 260;

  @override
  Widget build(BuildContext context) {
    final g = barGreen[panel.game]!;
    const inner = width - 6;
    return IgnorePointer(
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
            Text(panel.title, style: heavy(14)),
            const SizedBox(height: 6),
            Container(
              width: width,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Swatch.ink, width: kBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  children: [
                    Positioned(
                      left: (g.at - g.width / 2) * inner,
                      width: g.width * inner,
                      top: 0,
                      bottom: 0,
                      child: const ColoredBox(color: Color(0xFF7CF29A)),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: panel.power.clamp(0, 1) * inner,
                      child: const ColoredBox(color: Color(0xAAFF8A5B)),
                    ),
                    if (panel.last >= 0)
                      Positioned(
                        left: panel.last.clamp(0, 1) * inner - 1.5,
                        top: 0,
                        bottom: 0,
                        width: 3,
                        child: const ColoredBox(color: Swatch.ink),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(panel.info, style: heavy(12.5, color: Swatch.muted)),
          ],
        ),
      ),
    );
  }
}
