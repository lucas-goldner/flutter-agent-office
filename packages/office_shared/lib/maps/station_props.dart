// The pieces a station-style map can put up (its config's `props`), and how much floor each takes,
// as props.dart has the castle's. Ported from src/shared/maps/station-props.ts.

import 'airlock.dart';
import 'props.dart';
import 'types.dart';

/// The kinds of prop a station-style map can have, and what each is.
const Map<String, String> stationPropKinds = {
  // A hull rib across the hall at `z`: a column up each side wall, and a beam across the ceiling between them.
  'rib': 'A hull rib: a column up each side wall and a beam across the ceiling',
  // A window cut through the wall it's on, its sill at `y`, `width` by `height`: space shows through it.
  'viewport': 'A window out into space',
  // A light pod hanging from the ceiling, down to `y`.
  'lamp': 'A light pod hanging from the ceiling',
  // A strip of light let into the deck, `width` by `length` along `rotY`.
  'strip': 'A strip of light in the deck',
  // A display on a wall, its middle at `y`, `width` by `height`, facing `rotY`.
  'screen': 'A display on a wall',
  // A round holo-table, a globe turning over it.
  'hologram': 'A holo-table with a globe turning over it',
  // A hydroponics planter against a wall, `width` wide.
  'planter': 'A hydroponics planter',
  // A stack of cargo crates.
  'crate': 'Cargo crates',
  // The gong a merged pull request rings (one per map).
  'gong': 'The merge gong',
  // A drinks dispenser: a cup perks you up, like the office's coffee.
  'dispenser': 'A drinks dispenser (the coffee)',
  // A console table with nothing to sit at, `width` by `length`.
  'table': 'A console table without seats',
};

/// The size of a holo-table, a planter and the rest, before `scale`.
abstract final class StationSize {
  static const double hologram = 1.25;
  static const planter = (width: 2.4, depth: 0.7);
  static const double crate = 1.5;
  static const dispenser = (width: 1.3, depth: 0.7);
  static const double lamp = 0.5;
}

/// How much floor a station's prop takes: a box, a circle, or none (it's on a wall, in the deck or up in the air).
Footprint? stationFootprint(PropConfig p) {
  final s = p.scale ?? 1;
  final r = p.rotY ?? 0;
  return switch (p.kind) {
    'hologram' => (rect: null, circle: (p.x, p.z, StationSize.hologram * s)),
    'planter' => (
      rect: boxFootprint(p.x, p.z, (p.width ?? StationSize.planter.width) * s, StationSize.planter.depth * s, r),
      circle: null,
    ),
    'crate' => (rect: boxFootprint(p.x, p.z, StationSize.crate * s, StationSize.crate * s, r), circle: null),
    'gong' => (rect: boxFootprint(p.x, p.z, PropSize.gong.width, PropSize.gong.depth, r), circle: null),
    'dispenser' => (
      rect: boxFootprint(p.x, p.z, StationSize.dispenser.width * s, StationSize.dispenser.depth * s, r),
      circle: null,
    ),
    'table' => (rect: boxFootprint(p.x, p.z, p.width ?? 1.4, p.length ?? 3, r), circle: null),
    _ => null,
  };
}

/// How high up a station's prop that's on a wall or hangs from the ceiling reaches (0 for what stands on the deck).
double stationTop(PropConfig p) => switch (p.kind) {
  'viewport' => (p.y ?? ViewportSize.y) + (p.height ?? ViewportSize.height),
  'screen' => (p.y ?? 2.6) + (p.height ?? 1.4) / 2,
  'lamp' => p.y ?? 0,
  _ => 0,
};
