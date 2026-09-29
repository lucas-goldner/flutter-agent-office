// Drinks from the rooftop bar in their glasses, for hands and characters to hold (drinkGlass in the
// old client's character.ts).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';

import 'package:office_shared/rooftop.dart';

import 'office/geo.dart';
import 'office/parts.dart' show seeThrough, tc;
import 'toon.dart';

/// Clear glass, faintly blue, so the drink inside shows through it.
final UnlitMaterial _glass = seeThrough('#e8f6ff', 0.38);

/// A drink from the rooftop bar in its glass, standing on y = 0, [scale] times life size.
Node drinkGlass(Drink d, [double scale = 1]) {
  final g = group('drink:${d.id.wire}');
  final s = scale;
  void cyl2(double rTop, double rBottom, double h, Material mat, double y, [double x = 0]) =>
      g.add(mesh(cyl(rTop * s, rBottom * s, h * s, 14), mat, x * s, y * s, 0, false));
  final liquid = tc(d.color);
  // A stem and a foot, for the glasses that have them.
  void stem(double h) {
    cyl2(0.032, 0.034, 0.006, _glass, 0.003);
    cyl2(0.005, 0.005, h, _glass, h / 2);
  }

  switch (d.glass) {
    case Glass.pint:
      cyl2(0.041, 0.034, 0.115, liquid, 0.06);
      cyl2(0.043, 0.041, 0.022, tc('#fffaf0'), 0.128);
      cyl2(0.044, 0.036, 0.15, _glass, 0.075);
    case Glass.wine:
      stem(0.07);
      cyl2(0.036, 0.028, 0.035, liquid, 0.088);
      cyl2(0.042, 0.03, 0.075, _glass, 0.107);
    case Glass.martini:
      stem(0.075);
      cyl2(0.052, 0.005, 0.055, liquid, 0.103);
      cyl2(0.065, 0.005, 0.07, _glass, 0.11);
      // An olive on a stick.
      g.add(mesh(sphere(0.013 * s, 10, 8), tc('#7a9a3a'), 0.012 * s, 0.12 * s, 0, false));
      g.add(
        place(
          mesh(cyl(0.002 * s, 0.002 * s, 0.09 * s, 6), tc('#c98b5a'), 0, 0, 0, false),
          x: 0.02 * s,
          y: 0.14 * s,
          rot: euler(0, 0, -0.35),
        ),
      );
    case Glass.highball:
      cyl2(0.031, 0.029, 0.12, liquid, 0.062);
      // Ice, and a straw.
      for (final (x, y) in const [(-0.01, 0.11), (0.012, 0.095)]) {
        g.add(
          place(
            mesh(box(0.02 * s, 0.02 * s, 0.02 * s), tc('#f4fbff'), 0, 0, 0, false),
            x: x * s,
            y: y * s,
            z: 0.004 * s,
            rot: euler(0.4, 0.6, 0.2),
          ),
        );
      }
      if (d.id != DrinkId.water) {
        final straw = tc(d.id == DrinkId.maitai ? '#ef476f' : '#06d6a0');
        g.add(
          place(
            mesh(cyl(0.004 * s, 0.004 * s, 0.19 * s, 6), straw, 0, 0, 0, false),
            x: 0.012 * s,
            y: 0.13 * s,
            rot: euler(0, 0, -0.22),
          ),
        );
      }
      if (d.id == DrinkId.maitai) {
        // A paper umbrella, and a wedge of pineapple on the rim.
        g.add(
          place(
            mesh(cone(0.035 * s, 0.018 * s, 10), tc('#ffd166'), 0, 0, 0, false),
            x: -0.018 * s,
            y: 0.19 * s,
            rot: euler(0, 0, 0.4),
          ),
        );
        g.add(mesh(box(0.028 * s, 0.02 * s, 0.01 * s), tc('#ffd166'), 0.03 * s, 0.148 * s, 0, false));
      } else if (d.id == DrinkId.mojito) {
        for (final (x, z) in const [(-0.012, 0.006), (0.006, -0.01), (0.01, 0.01)]) {
          g.add(mesh(sphere(0.009 * s, 6, 5), tc('#3f8f45'), x * s, 0.117 * s, z * s, false));
        }
        g.add(
          place(
            mesh(cyl(0.018 * s, 0.018 * s, 0.006 * s, 10), tc('#9bc53d'), 0, 0, 0, false),
            x: 0.022 * s,
            y: 0.15 * s,
            rot: euler(math.pi / 2, 0, 0),
          ),
        );
      }
      cyl2(0.034, 0.032, 0.15, _glass, 0.075);
    case Glass.shot:
      cyl2(0.023, 0.02, 0.042, liquid, 0.024);
      cyl2(0.026, 0.022, 0.06, _glass, 0.03);
      // A wedge of lime balanced on the rim.
      g.add(
        place(
          mesh(cyl(0.016 * s, 0.016 * s, 0.008 * s, 10), tc('#9bc53d'), 0, 0, 0, false),
          x: 0.022 * s,
          y: 0.065 * s,
          rot: euler(math.pi / 2, 0, 0),
        ),
      );
  }
  return g;
}
