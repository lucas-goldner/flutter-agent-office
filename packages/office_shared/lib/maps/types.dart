// Maps: what the building looks like inside. The office is built in code and is the default; any
// other map is plain data, a map config (JSON), which planMap (maps.dart) checks and turns into a
// [MapPlan], and a builder for its `style` puts up. A config can come from this folder (the built-in
// ones, castle.dart and station.dart) or from a JSON file in the office's `.agent-office/maps/` (see
// docs/maps.md). Every map places the same seats (the desks, the overflow seats, the board agents'
// kiosks and the meeting chairs, by id), so workers, the queue and meetings work the same on any of
// them, and a worker keeps its seat when the building changes maps.
//
// Ported from src/shared/maps/types.ts. A map's config (TS MapConfig) stays the JSON object it was
// written as ([MapConfig] is a `Map<String, dynamic>`): planMap reads it, trusting none of it, and it
// goes over the wire as it is.

import '../json_util.dart';
import '../layout.dart';
import '../nav.dart';

/// What a map is made of, as JSON: see docs/maps.md for what each part does and how to write one.
typedef MapConfig = Map<String, dynamic>;

/// The styles there's a builder for: a map's `style` is one of them.
enum MapStyle implements WireEnum {
  castle('castle'),
  station('station');

  const MapStyle(this.wire);
  @override
  final String wire;

  static MapStyle? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// The boards on the walls.
enum BoardKey implements WireEnum {
  issues('issues'),
  queue('queue'),
  pulls('pulls'),
  services('services');

  const BoardKey(this.wire);
  @override
  final String wire;
}

const List<BoardKey> boardKeys = BoardKey.values;

/// A piece of the map that isn't a seat: a pillar, a banner, a brazier… [kind] is one the map's style
/// knows (see [propKinds]); what the rest means depends on it.
class PropConfig {
  const PropConfig({
    required this.kind,
    required this.x,
    required this.z,
    this.y,
    this.rotY,
    this.scale,
    this.width,
    this.height,
    this.length,
    this.color,
    this.light,
  });

  /// A prop as a map's JSON has it (checked by planMap first).
  factory PropConfig.fromJson(Map<String, dynamic> j) => PropConfig(
    kind: asString(j['kind']),
    x: asDouble(j['x']),
    z: asDouble(j['z']),
    y: asDoubleOrNull(j['y']),
    rotY: asDoubleOrNull(j['rotY']),
    scale: asDoubleOrNull(j['scale']),
    width: asDoubleOrNull(j['width']),
    height: asDoubleOrNull(j['height']),
    length: asDoubleOrNull(j['length']),
    color: asStringOrNull(j['color']),
    light: asBoolOrNull(j['light']),
  );

  final String kind;
  final double x;
  final double z;

  /// Up off the floor (a banner, a window, a chandelier).
  final double? y;
  final double? rotY;
  final double? scale;
  final double? width;
  final double? height;
  final double? length;
  final String? color;

  /// A torch or a brazier that lights the room (a few at most).
  final bool? light;
}

/// Somewhere a send-home script can walk to, by name.
enum SendHomeSpot implements WireEnum {
  /// Out through the door and away.
  door('door'),

  /// The top of the dungeon stairs.
  stairs('stairs'),

  /// The foot of the dungeon stairs, down in the dungeon.
  dungeon('dungeon'),

  /// The worker's own cell (its door).
  cell('cell'),

  /// The airlock's inner door.
  airlock('airlock'),

  /// The escort's post.
  post('post');

  const SendHomeSpot(this.wire);
  @override
  final String wire;

  static SendHomeSpot? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// Somewhere a send-home script can walk to: one of the [SendHomeSpot]s, or a spot in the hall (or,
/// [below], in the dungeon).
class SendHomePlace {
  const SendHomePlace.named(SendHomeSpot this.spot) : x = 0, z = 0, below = false;
  const SendHomePlace.at(this.x, this.z, {this.below = false}) : spot = null;

  final SendHomeSpot? spot;
  final double x;
  final double z;
  final bool below;

  Object toJson() => spot?.wire ?? {'x': x, 'z': z, if (below) 'below': true};
}

/// The kinds of step a send-home script can have (see [sendHomeSteps] for what each does).
enum SendHomeStepKind implements WireEnum {
  pack('pack'),
  fetch('fetch'),
  say('say'),
  walk('walk'),
  jail('jail'),
  eject('eject'),
  leave('leave'),
  wait('wait'),
  return_('return');

  const SendHomeStepKind(this.wire);
  @override
  final String wire;

  static SendHomeStepKind? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// Who says a `say` step's line.
enum SendHomeWho { worker, escort }

/// A step of what happens to a worker sent home (see docs/maps.md):
/// - `pack`: it packs its things into a box at its seat, and its laptop (or tome) shuts.
/// - `fetch`: the escort comes from its post to the worker ([run]: at a run).
/// - `say`: the worker, or its escort ([who]), says something (one of [text], picked at random).
/// - `walk`: the worker walks [to] somewhere, the escort holding on to it if it has fetched it.
/// - `jail`: it's thrown into its cell, and the door's locked behind it: it's kept there, for good.
/// - `eject`: it's shoved into the airlock and blown out into space: it's kept out there, adrift, for good.
/// - `leave`: it's gone (shrinking away, wherever it is).
/// - `wait`: a pause, [seconds] long.
/// - `return`: the escort goes back to its post (the worker's done with meanwhile).
class SendHomeStep {
  const SendHomeStep(this.kind, {this.run, this.who, this.text, this.to, this.seconds});

  final SendHomeStepKind kind;

  /// `fetch`: false when the escort walks; `walk`: true when the worker runs.
  final bool? run;
  final SendHomeWho? who;
  final List<String>? text;
  final SendHomePlace? to;
  final double? seconds;

  Map<String, dynamic> toJson() => {
    'do': kind.wire,
    'run': ?run,
    if (who != null) 'who': who!.name,
    'text': ?text,
    if (to != null) 'to': to!.toJson(),
    'seconds': ?seconds,
  };
}

/// The colors a map's `palette` can give: a castle's, then a station's.
const List<String> mapPaletteKeys = [
  'stone',
  'floor',
  'carpet',
  'wood',
  'trim',
  'hull',
  'deck',
  'panel',
  'metal',
  'glow',
];

/// A spot to sit or stand in, facing [rotY], and how high its floor is.
class Spot {
  const Spot({required this.x, required this.y, required this.z, required this.rotY});

  final double x;
  final double y;
  final double z;
  final double rotY;
}

/// A cell in the dungeon, worked out: see the config's `dungeon.cells`.
class CellPlan {
  const CellPlan({
    required this.x,
    required this.z,
    required this.rotY,
    required this.width,
    required this.depth,
    required this.outside,
    required this.threshold,
    required this.spots,
  });

  /// The middle of its bars, and the way they face (out into the vault).
  final double x;
  final double z;
  final double rotY;
  final double width;
  final double depth;

  /// Its door, in the middle of the bars: where the escort stands in front of it, and where its
  /// prisoner is thrown in from.
  final Pt outside;
  final Pt threshold;

  /// Where its prisoners sit, the first to be locked up first.
  final List<Spot> spots;
}

/// A seat in a dungeon cell: which cell, and the spot in it.
typedef CellSeat = ({int cell, Spot spot});

/// The dungeon stairs, worked out: which way they go down, how wide they are, where a walker comes
/// up to them in the hall ([top]), the top and bottom of the flight, and the foot of them in the vault.
typedef DungeonStairs = ({double rotY, double width, Pt top, Pt start, Pt end, Pt foot});

/// The dungeon under the hall, worked out from its config.
class DungeonPlan {
  const DungeonPlan({
    required this.bounds,
    required this.floor,
    required this.ceiling,
    required this.opening,
    required this.rails,
    required this.steps,
    required this.stairs,
    required this.cells,
    required this.seats,
    required this.pillars,
    required this.torches,
    required this.ossuary,
    required this.obstacles,
  });

  /// The vault.
  final Bounds bounds;

  /// Its floor, below the hall's (negative), and its ceiling, the underside of the hall's floor.
  final double floor;
  final double ceiling;

  /// The hole in the hall's floor over the stairs, and the rails round it.
  final NavRect opening;
  final NavRect rails;

  /// The stairs: a step at a time, its top and the floor it covers, from the top one down.
  final List<({double top, NavRect rect})> steps;
  final DungeonStairs stairs;
  final List<CellPlan> cells;

  /// Every seat in every cell, in the order they fill: round the cells one seat each, then round again.
  final List<CellSeat> seats;
  final List<Pt> pillars;
  final List<({double x, double z, double rotY})> torches;
  final Pt? ossuary;

  /// What's in the way down there, for walking round it.
  final Obstacles obstacles;
}

/// One of the hall's four walls.
enum WallSide implements WireEnum {
  west('west'),
  east('east'),
  north('north'),
  south('south');

  const WallSide(this.wire);
  @override
  final String wire;
}

/// What's cut through a wall.
enum OpeningKind { door, airlock, viewport }

/// Something cut through one of the hall's walls: [u] is its middle along the wall (x for a north or
/// south wall, z for the others), [y] its sill.
class WallOpening {
  const WallOpening({
    required this.wall,
    required this.kind,
    required this.u,
    required this.y,
    required this.width,
    required this.height,
  });

  final WallSide wall;
  final OpeningKind kind;
  final double u;
  final double y;
  final double width;
  final double height;
}

/// An airlock, worked out from its config. Its chamber is outside the hall, beyond the wall.
class AirlockPlan {
  const AirlockPlan({
    required this.wall,
    required this.out,
    required this.door,
    required this.front,
    required this.chamber,
    required this.hatch,
  });

  final WallSide wall;

  /// The way out through it: a step along x or z.
  final Pt out;

  /// The middle of its inner door, in the wall's inside face.
  final Pt door;

  /// Where the escort stops with a worker, in front of the inner door.
  final Pt front;

  /// The middle of the chamber, where a worker waits to be blown out, and the outer hatch at its far end.
  final Pt chamber;
  final Pt hatch;
}

/// Who comes for a worker sent home, worked out: their name and color, and their post (down in the
/// dungeon, with [below]).
typedef SendHomeEscort = ({String name, String color, Spot post, bool below});

class SendHomePlan {
  const SendHomePlan({
    this.escort,
    required this.steps,
    required this.keeps,
    required this.starveMs,
    required this.rotMs,
  });

  final SendHomeEscort? escort;
  final List<SendHomeStep> steps;

  /// Whoever's sent home is kept: locked up in the dungeon (its steps jail it), or adrift outside the
  /// airlock (they eject it).
  final bool keeps;

  /// How long until someone locked up has starved to death, and after that until they're bare bones (ms).
  final double starveMs;
  final double rotMs;
}

/// The plan's style: the office built in code, or one there's a builder for.
enum PlanStyle { office, castle, station }

/// A table as checked, with what was left out filled in: the sides with seats (1 is the table's
/// right, -1 its left).
typedef TablePlan = ({
  double x,
  double z,
  double length,
  double width,
  double rotY,
  int seats,
  List<int> sides,
  String name,
});

/// The dais a throne stands on.
typedef Dais = ({double width, double depth, double height, int steps});

/// Who sends out new workers: where, what the card over them says, and what they ask and the button
/// in their window.
typedef HeraldPlan = ({double x, double z, double rotY, String name, String says, String ask, String button});

/// A map checked and worked out: where everything is, by id.
class MapPlan {
  const MapPlan({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.style,
    this.config,
    required this.bounds,
    required this.height,
    required this.spawn,
    required this.desks,
    required this.overflow,
    required this.stations,
    required this.meeting,
    required this.byId,
    required this.seating,
    required this.seatingById,
    this.throne,
    this.dais,
    required this.lineup,
    this.herald,
    required this.door,
    required this.tables,
    this.council,
    required this.boards,
    this.obstacles,
    required this.outfit,
    required this.ageMinutes,
    this.dungeon,
    this.airlock,
    this.openings,
    this.sendHome,
  });

  final String id;
  final String name;
  final String icon;
  final String description;

  /// 'office' is the office built in code; any other is built from [config] by its style's builder.
  final PlanStyle style;
  final MapConfig? config;
  final Bounds bounds;

  /// How high the walls are.
  final double height;

  /// Where you stand when you arrive.
  final ({double x, double y, double z, double rotY}) spawn;

  /// The regular seats, then the overflow ones that only come out once they're all taken (the office's bean bags).
  final List<DeskDef> desks;
  final List<DeskDef> overflow;
  final List<DeskDef> stations;
  final List<DeskDef> meeting;

  /// Everywhere a worker can be, by id.
  final Map<String, DeskDef> byId;

  /// Where people can sit (the office's couches, the castle's throne).
  final List<SeatDef> seating;
  final Map<String, SeatDef> seatingById;
  final SeatDef? throne;

  /// The dais the throne stands on (its front is 2.4 m in front of the throne, and the steps down go on from there).
  final Dais? dais;

  /// The spots workers waiting on someone stand in, first in line first.
  final List<({double x, double z, double rotY})> lineup;
  final HeraldPlan? herald;
  final ({double x, double z}) door;
  final List<TablePlan> tables;

  /// The meeting table's middle, and which side the head of the table is on.
  final ({double x, double z, double rotY})? council;
  final Map<BoardKey, BoardDef> boards;

  /// What's in the way on the floor, for walking round it (the office has its own: [officeNav]).
  final Obstacles? obstacles;

  /// How the workers look here: an outfit ('peasant' or 'none'), and how many minutes of work until
  /// they look worn out (0: they never do). TS `agents`.
  final String outfit;
  final double ageMinutes;

  /// The dungeon under the hall, worked out (see dungeon.dart).
  final DungeonPlan? dungeon;

  /// The airlock in one of the hall's walls, worked out (see airlock.dart).
  final AirlockPlan? airlock;

  /// What's cut through the hall's walls, wall by wall: the way in, the airlock and the windows.
  final List<WallOpening>? openings;

  /// What happens to a worker sent home, checked: none, and it walks out of the door.
  final SendHomePlan? sendHome;
}

/// What Settings lists: every map there is to pick, and the custom ones that didn't load.
class MapChoice {
  const MapChoice({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    this.custom = false,
    this.error,
  });

  final String id;
  final String name;
  final String icon;
  final String description;

  /// From the office's `.agent-office/maps/` folder.
  final bool custom;

  /// Why it can't be picked.
  final String? error;
}
