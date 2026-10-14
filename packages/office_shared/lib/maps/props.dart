// The pieces a castle-style map can put up (its config's `props`), and how much floor each takes:
// what walkers go round (nav.dart) and, in the builder, what you bump into. How each one looks is the
// style's builder's. A station's are in station_props.dart. Ported from src/shared/maps/props.ts.

import 'dart:math' as math;

import '../nav.dart';
import 'types.dart';

/// The kinds of prop a castle-style map can have, and what each is.
const Map<String, String> propKinds = {
  // A stone pillar, floor to ceiling. `scale` widens it.
  'pillar': 'A stone pillar, floor to ceiling',
  // A torch in an iron sconce on a wall or a pillar, `y` up, burning toward `rotY`.
  'torch': 'A torch in a sconce on a wall or pillar',
  // An iron fire bowl on legs.
  'brazier': 'A fire in an iron bowl on legs',
  // An iron ring of candles hanging from the roof, at `y`.
  'chandelier': 'A ring of candles hanging from the roof',
  // A long banner hanging on a wall, its top at `y`, `width` by `height`, facing `rotY`.
  'banner': 'A banner hanging on a wall',
  // A tall pointed stained-glass window in a wall, its sill at `y`.
  'window': 'A tall stained-glass window',
  // A round stained-glass window, its middle at `y`, `width` across.
  'rose': 'A round stained-glass window',
  // A carpet runner on the floor, `width` by `length` along `rotY`.
  'carpet': 'A carpet runner',
  // A knight in stone on a plinth.
  'statue': 'A stone knight on a plinth',
  // A suit of armour on a stand.
  'armor': 'A suit of armour',
  // A shield with crossed swords, hung on a wall at `y`.
  'shield': 'A shield and crossed swords on a wall',
  // A great fireplace against a wall, `width` wide.
  'hearth': 'A fireplace',
  // The gong a merged pull request rings (one per map).
  'gong': 'The merge gong',
  // Casks of ale on a rack: a drink perks you up, like the office's coffee.
  'cask': 'Casks of ale (the coffee)',
  // A table with nothing to sit at, `width` by `length`.
  'table': 'A table without seats',
  // A tall iron candle stand.
  'candles': 'A candle stand',
};

/// The floor a [w] by [d] box takes, centered on (x, z) and turned [rotY] (its [d] along rotY).
NavRect boxFootprint(double x, double z, double w, double d, [double rotY = 0]) {
  final c = math.cos(rotY).abs();
  final s = math.sin(rotY).abs();
  final hx = (w * c + d * s) / 2;
  final hz = (w * s + d * c) / 2;
  return (x - hx, x + hx, z - hz, z + hz);
}

/// The size of a pillar, a hearth and the rest, before `scale`.
abstract final class PropSize {
  static const double pillar = 1.3;
  static const double brazier = 0.55;
  static const double statue = 1.3;
  static const double armor = 0.42;
  static const hearth = (width: 3.6, depth: 1.1);
  static const gong = (width: 2.1, depth: 0.7);
  static const cask = (width: 1.7, depth: 1.0);
  static const double candles = 0.3;
}

/// How much floor a prop takes: a box, a circle, or none (null: it's on a wall or up in the air).
typedef Footprint = ({NavRect? rect, NavCircle? circle});

/// How much floor a castle prop takes.
Footprint? propFootprint(PropConfig p) {
  final s = p.scale ?? 1;
  final r = p.rotY ?? 0;
  return switch (p.kind) {
    'pillar' => (rect: boxFootprint(p.x, p.z, PropSize.pillar * s, PropSize.pillar * s, r), circle: null),
    'brazier' => (rect: null, circle: (p.x, p.z, PropSize.brazier * s)),
    'statue' => (rect: boxFootprint(p.x, p.z, PropSize.statue * s, PropSize.statue * s, r), circle: null),
    'armor' => (rect: null, circle: (p.x, p.z, PropSize.armor * s)),
    'candles' => (rect: null, circle: (p.x, p.z, PropSize.candles * s)),
    'hearth' => (
      rect: boxFootprint(p.x, p.z, (p.width ?? PropSize.hearth.width) * s, PropSize.hearth.depth * s, r),
      circle: null,
    ),
    'gong' => (rect: boxFootprint(p.x, p.z, PropSize.gong.width, PropSize.gong.depth, r), circle: null),
    'cask' => (rect: boxFootprint(p.x, p.z, PropSize.cask.width * s, PropSize.cask.depth * s, r), circle: null),
    'table' => (rect: boxFootprint(p.x, p.z, p.width ?? 1.4, p.length ?? 3, r), circle: null),
    _ => null,
  };
}

/// How high up a castle prop that hangs on a wall or from the roof reaches (0 for what stands on the floor).
double propTop(PropConfig p) {
  final y = p.y ?? 0;
  return switch (p.kind) {
    'window' => y + (p.height ?? 5),
    'rose' => y + (p.width ?? 4.5) / 2,
    'banner' || 'chandelier' => y,
    'torch' || 'shield' => y + 0.5,
    _ => 0,
  };
}
