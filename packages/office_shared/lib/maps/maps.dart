// Maps: what the building looks like inside, checked and worked out (see types.dart). The office is
// the default; the castle and the space station come with it; any other is a JSON file in the
// office's .agent-office/maps/. Ported from src/shared/maps/index.ts.

import 'dart:convert';
import 'dart:math' as math;

import '../json_util.dart';
import '../layout.dart';
import '../nav.dart';
import 'airlock.dart';
import 'castle.dart';
import 'check.dart';
import 'dungeon.dart';
import 'props.dart';
import 'station.dart';
import 'station_props.dart';
import 'types.dart';

export 'airlock.dart'
    show
        Adrift,
        AirlockSize,
        Drift,
        HatchSize,
        ViewportSize,
        adrift,
        adriftFrom,
        hullThickness,
        nearestWall,
        wallOut,
        wallPoint;
export 'castle.dart' show castleMap;
export 'check.dart' show MapError;
export 'dungeon.dart'
    show
        DungeonLimits,
        dungeonClear,
        dungeonPillar,
        dungeonSlab,
        levelRoute,
        ossuaryRadius,
        prisonSeat,
        rectsOverlap,
        rotHours,
        sendHomeSteps,
        starveHours,
        wasting;
export 'props.dart' show Footprint, PropSize, boxFootprint, propFootprint, propKinds, propTop;
export 'station.dart' show stationMap;
export 'station_props.dart' show StationSize, stationFootprint, stationPropKinds, stationTop;
export 'types.dart';

/// The office: built in code, and what the building is until someone picks another map (TS OFFICE_MAP).
const String officeMap = 'office';

/// The maps that come with the office, besides the office itself.
final List<MapConfig> builtinMaps = [castleMap, stationMap];

/// The props each style of map can put up: their kinds, the floor each takes and how high it reaches.
final Map<
  MapStyle,
  ({Map<String, String> kinds, Footprint? Function(PropConfig) footprint, double Function(PropConfig) top})
>
_styleProps = {
  MapStyle.castle: (kinds: propKinds, footprint: propFootprint, top: propTop),
  MapStyle.station: (kinds: stationPropKinds, footprint: stationFootprint, top: stationTop),
};

const List<StationKind> _stationKinds = [StationKind.issues, StationKind.pulls, StationKind.queue];

/// How far in from a table's edge a seat's place setting is; the worker sits 0.85 out from it (see
/// deskSeat), on the bench.
const double _placeIn = 0.35;

/// How far out from a table's edge the middle of the bench down that side is.
const double benchOut = 0.52;

/// The round meeting table: how big it is, how far out the chairs' place settings and the chairs are,
/// and how far behind it (away from the head of the table) the easel with the meeting's board stands.
/// [tome] is the book at each place: its size next to the model's, and how far toward its chair it
/// lies from the place. Five of them open round the table take a table this big to lie clear of each other.
abstract final class Council {
  static const double radius = 1.3;
  static const double height = 0.78;
  static const double place = 0.85;
  static const double chairs = 1.7;
  static const double easel = 3.1;
  static const tome = (scale: 0.85, z: 0.04);
}

/// The throne's footprint.
abstract final class ThroneSize {
  static const double width = 1.9;
  static const double depth = 1.9;
}

/// The most tables, seats a side and props a map can have: plenty for a hall, and not so many a
/// browser chokes building it.
abstract final class MapLimits {
  static const int tables = 40;
  static const int seats = 12;
  static const int props = 400;
}

/// The dais a throne stands on when its map doesn't say.
const Dais defaultDais = (width: 8, depth: 4.5, height: 0.9, steps: 3);

const Map<BoardKey, String> _defaultBoardLabel = {
  BoardKey.issues: 'Issues',
  BoardKey.queue: '📋 Task queue',
  BoardKey.pulls: 'Pull Requests',
  BoardKey.services: '🌐 Services',
};

// ---- The office -----------------------------------------------------------------------------------

/// Every map's desks, by id: the office's room, then its back office (see [Wing]), which is only there
/// to sit at on a floor built out that far ([deskBuilt]), on whichever map, so a worker hired there
/// has a seat on every map.
final List<DeskDef> _mapDesks = [...desks, ...wingDesks];

const Map<BoardKey, BoardDef> _officeBoards = {
  BoardKey.issues: Boards.issues,
  BoardKey.queue: Boards.queue,
  BoardKey.pulls: Boards.pulls,
  BoardKey.services: Boards.services,
};

MapPlan _officePlan() => MapPlan(
  id: officeMap,
  name: 'Office',
  icon: '🏢',
  description:
      'The office: desks, a lounge, the boss’s loft upstairs, a floor for every project, and a bar on the roof.',
  style: PlanStyle.office,
  bounds: const Bounds(minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ),
  height: wallHeight,
  spawn: (x: Elevator.x, y: 0, z: (ElevatorCar.minZ + ElevatorCar.maxZ) / 2, rotY: 0),
  desks: _mapDesks,
  overflow: beanbags,
  stations: stations,
  meeting: meetingSeats,
  byId: {
    for (final d in [..._mapDesks, ...beanbags, ...stations, ...meetingSeats]) d.id: d,
  },
  seating: seating,
  seatingById: seatingById,
  lineup: const [],
  door: (x: Floor.minX + 0.45, z: exitDoor.u),
  tables: const [],
  boards: _officeBoards,
  outfit: 'none',
  ageMinutes: 0,
);

/// The office's plan (TS OFFICE_PLAN).
final MapPlan officePlan = _officePlan();

// ---- Checking a map ---------------------------------------------------------------------------------

/// Keys a JSON object could use to reach an object's prototype, which a merge skips.
const Set<String> _unsafe = {'__proto__', 'constructor', 'prototype'};

/// [over] on top of [base]: objects merged key by key, anything else (lists included, and null) replaced.
Object? mergeConfig(Object? base, Object? over) {
  if (base is! Map || over is! Map) return over;
  final out = <String, dynamic>{...Map<String, dynamic>.from(base)};
  for (final MapEntry(:key, :value) in over.entries) {
    if (key is! String || _unsafe.contains(key)) continue;
    out[key] = out.containsKey(key) ? mergeConfig(out[key], value) : value;
  }
  return out;
}

/// [m] with its `extends` set to [to], or without one when [to] is null (TS `extends: undefined`).
MapConfig _withExtends(MapConfig m, Object? to) {
  final out = {...m};
  if (to == null) {
    out.remove('extends');
  } else {
    out['extends'] = to;
  }
  return out;
}

/// The whole config of [config], with whatever it `extends` filled in under it (a chain of them, at
/// most a few deep). [known] finds a map by id: the built-in ones and the other custom ones.
MapConfig resolveConfig(MapConfig config, MapConfig? Function(String id) known) {
  var out = config;
  final seen = <Object?>{config['id']};
  Object? parent = config['extends'];
  while (parent is String && parent.isNotEmpty) {
    if (seen.contains(parent)) throw MapError('it extends itself (through $parent)');
    if (seen.length > 5) throw const MapError('it extends too many maps in a row');
    seen.add(parent);
    final base = known(parent);
    if (base == null) {
      throw MapError(
        parent == officeMap
            ? 'the office is built in code, so a map can’t extend it: extend "castle" instead'
            : 'it extends "$parent", which there’s no map called',
      );
    }
    out = mergeConfig(base, _withExtends(out, base['extends'])) as MapConfig;
    parent = base['extends'];
  }
  return _withExtends(out, config['extends']);
}

final RegExp _mapId = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// JS `String(v)` for a value in an error message.
String _jsString(Object? v, bool present) => !present ? 'undefined' : (v == null ? 'null' : '$v');

String _cut(String s, int max) => s.length > max ? s.substring(0, max) : s;

/// Checks a map's config is complete and sane, and works out where everything goes. [input] is
/// whatever a file had in it: nothing is taken on trust, least of all that it's a map config.
MapPlan planMap(Object? input) {
  if (!isObj(input)) throw const MapError('it isn’t a JSON object');
  final c = objOf(input);
  final id0 = c['id'];
  if (id0 is! String || id0.length > 40 || !_mapId.hasMatch(id0)) {
    throw const MapError('its id should be up to 40 lowercase letters, digits and dashes');
  }
  final id = id0;
  if (id == officeMap) throw const MapError('"office" is the office’s own id');
  final name = checkStr(c['name'], 'name', 40);
  final style = MapStyle.tryParse(c['style']);
  if (style == null) {
    throw MapError(
      'its style "${_jsString(c['style'], c.containsKey('style'))}" isn’t one there’s a builder for (${MapStyle.values.map((s) => s.wire).join(', ')})',
    );
  }
  final kinds = _styleProps[style]!;
  if (!isObj(c['hall'])) throw const MapError('it needs a hall: { width, length, height }');
  final hall = objOf(c['hall']);
  final width = checkNum(hall['width'], 'hall.width', 8, 110);
  final length = checkNum(hall['length'], 'hall.length', 8, 110);
  final height = checkNum(hall['height'], 'hall.height', 4, 40);
  final bounds = Bounds(minX: -width / 2, maxX: width / 2, minZ: -length / 2, maxZ: length / 2);
  void inside(double x, double z, String what, [double margin = 0.2]) {
    if (x < bounds.minX + margin || x > bounds.maxX - margin || z < bounds.minZ + margin || z > bounds.maxZ - margin) {
      throw MapError('$what (${fixed1(x)}, ${fixed1(z)}) is outside the hall');
    }
  }

  ({double x, double z, double rotY}) place(Object? p, String what) {
    if (!isObj(p)) throw MapError('it needs $what: { x, z }');
    final o = objOf(p);
    final x = checkNum(o['x'], '$what.x');
    final z = checkNum(o['z'], '$what.z');
    final rotY = o['rotY'] == null ? 0.0 : checkNum(o['rotY'], '$what.rotY');
    inside(x, z, what);
    return (x: x, z: z, rotY: rotY);
  }

  // An optional number: null when it's left out, else checked like checkNum.
  double? opt(Object? v, String what, num min, num max) => v == null ? null : checkNum(v, what, min, max);
  final rects = <NavRect>[];
  final circles = <NavCircle>[];

  // The seats at the tables: every table's side toward the middle of the hall first, then the far sides.
  final rawTables = c['tables'];
  if (rawTables is! List || rawTables.isEmpty) throw const MapError('it needs tables for the workers to sit at');
  if (rawTables.length > MapLimits.tables) {
    throw MapError('it has ${rawTables.length} tables, and a map can have ${MapLimits.tables}');
  }
  final inner = <({({double x, double z, double rotY}) def, String table})>[];
  final outer = <({({double x, double z, double rotY}) def, String table})>[];
  final tables = <TablePlan>[];
  for (var i = 0; i < rawTables.length; i++) {
    final what = 'tables[$i]';
    if (!isObj(rawTables[i])) throw MapError('$what should be { x, z, length, seats }');
    final t = objOf(rawTables[i]);
    final x = checkNum(t['x'], '$what.x');
    final z = checkNum(t['z'], '$what.z');
    final len = checkNum(t['length'], '$what.length', 1, 100);
    final w = t['width'] == null ? 1.4 : checkNum(t['width'], '$what.width', 0.6, 4);
    final r = t['rotY'] == null ? 0.0 : checkNum(t['rotY'], '$what.rotY');
    final n = checkNum(t['seats'], '$what.seats', 1, MapLimits.seats);
    if (n != n.truncateToDouble()) throw MapError('$what.seats should be a whole number');
    final along = (math.sin(r), math.cos(r));
    final right = (math.cos(r), -math.sin(r));
    for (final end in const [-1, 1]) {
      inside(x + (along.$1 * len * end) / 2, z + (along.$2 * len * end) / 2, 'the end of $what');
    }
    // The side facing the middle of the hall is the inner one.
    final rightInner = right.$1 * x + right.$2 * z <= 0;
    final sides = t['sides'] ?? 'both';
    if (sides != 'both' && sides != 'inner' && sides != 'outer') {
      throw MapError('$what.sides should be "both", "inner" or "outer"');
    }
    final table = t['name'] is String && (t['name'] as String).trim().isNotEmpty
        ? _cut((t['name'] as String).trim(), 40)
        : 'Table ${i + 1}';
    rects.add(boxFootprint(x, z, w, len, r));
    final seated = <int>[];
    tables.add((x: x, z: z, length: len, width: w, rotY: r, seats: n.toInt(), sides: seated, name: table));
    for (final s in const [1, -1]) {
      final isInner = (s == 1) == rightInner;
      if (sides != 'both' && (sides == 'inner') != isInner) continue;
      seated.add(s);
      final nx = right.$1 * s;
      final nz = right.$2 * s;
      // The bench down that side, all of it (and whoever sits on it) inside the hall.
      rects.add(boxFootprint(x + nx * (w / 2 + benchOut), z + nz * (w / 2 + benchOut), 0.42, len - 0.2, r));
      for (final end in const [-1, 1]) {
        inside(
          x + nx * (w / 2 + benchOut + 0.22) + (along.$1 * (len - 0.2) * end) / 2,
          z + nz * (w / 2 + benchOut + 0.22) + (along.$2 * (len - 0.2) * end) / 2,
          'the bench along $what',
          0,
        );
      }
      final out = w / 2 - _placeIn;
      for (var k = 0; k < n; k++) {
        final t0 = (k - (n - 1) / 2) * (len / n);
        final def = (x: x + along.$1 * t0 + nx * out, z: z + along.$2 * t0 + nz * out, rotY: math.atan2(nx, nz));
        (isInner ? inner : outer).add((def: def, table: table));
      }
    }
  }
  final all = [...inner, ...outer];
  final need = _mapDesks.length + beanbags.length;
  if (all.length < need) {
    throw MapError(
      'its tables seat ${all.length}, and a map needs $need (${_mapDesks.length} seats and ${beanbags.length} more for when they’re all taken)',
    );
  }
  final counts = <String, int>{};
  final named = [
    for (final s in all.take(need))
      () {
        final k = (counts[s.table] ?? 0) + 1;
        counts[s.table] = k;
        return (def: s.def, label: '${s.table}, seat $k');
      }(),
  ];
  final mapDeskList = [
    for (var i = 0; i < _mapDesks.length; i++)
      DeskDef(
        id: _mapDesks[i].id,
        x: named[i].def.x,
        z: named[i].def.z,
        rotY: named[i].def.rotY,
        label: named[i].label,
      ),
  ];
  final overflow = [
    for (var i = 0; i < beanbags.length; i++)
      DeskDef(
        id: beanbags[i].id,
        x: named[_mapDesks.length + i].def.x,
        z: named[_mapDesks.length + i].def.z,
        rotY: named[_mapDesks.length + i].def.rotY,
        label: named[_mapDesks.length + i].label,
      ),
  ];

  // The board agents' lecterns.
  if (!isObj(c['stations'])) throw const MapError('it needs stations: where the Issues, PR and Queue agents stand');
  final rawStations = objOf(c['stations']);
  final stationDefs = [
    for (final kind in _stationKinds)
      () {
        final p = place(rawStations[kind.wire], 'stations.${kind.wire}');
        final agent = stationAgent[kind]!.name;
        // The agent stands behind its lectern: that's in the hall too.
        inside(p.x + math.sin(p.rotY) * 0.9, p.z + math.cos(p.rotY) * 0.9, 'where the $agent stands', 0);
        // The lectern, and the agent standing behind it.
        final corners = [
          for (final t in const [-1, 1])
            for (final s in const [-0.25, 0.9])
              (
                p.x + math.cos(p.rotY) * t * 0.4 + math.sin(p.rotY) * s,
                p.z - math.sin(p.rotY) * t * 0.4 + math.cos(p.rotY) * s,
              ),
        ];
        rects.add((
          corners.map((q) => q.$1).reduce(math.min),
          corners.map((q) => q.$1).reduce(math.max),
          corners.map((q) => q.$2).reduce(math.min),
          corners.map((q) => q.$2).reduce(math.max),
        ));
        return DeskDef(id: 'station-${kind.wire}', station: kind, x: p.x, z: p.z, rotY: p.rotY, label: agent);
      }(),
  ];

  // The fixtures (the build tower): each optional, each in the way like a lectern.
  final fixtures = <FixtureKey, FixturePlan>{};
  if (c['fixtures'] != null) {
    if (!isObj(c['fixtures'])) throw const MapError('fixtures should be { build }');
    final raw = objOf(c['fixtures']);
    for (final k in FixtureKey.values) {
      if (raw[k.wire] == null) continue;
      final p = place(raw[k.wire], 'fixtures.${k.wire}');
      final corners = [
        for (final t in const [-1, 1])
          for (final s in const [-0.3, 0.3])
            (
              p.x + math.cos(p.rotY) * t * 0.4 + math.sin(p.rotY) * s,
              p.z - math.sin(p.rotY) * t * 0.4 + math.cos(p.rotY) * s,
            ),
      ];
      rects.add((
        corners.map((q) => q.$1).reduce(math.min),
        corners.map((q) => q.$1).reduce(math.max),
        corners.map((q) => q.$2).reduce(math.min),
        corners.map((q) => q.$2).reduce(math.max),
      ));
      fixtures[k] = p;
    }
  }

  // The meeting table: five chairs round it, the head of the table first.
  final council = place(c['council'], 'council');
  final meeting = [
    for (var i = 0; i < meetingSeats.length; i++)
      () {
        final m = meetingSeats[i];
        final a = council.rotY + (i * math.pi * 2) / meetingSeats.length;
        circles.add((council.x + math.sin(a) * Council.chairs, council.z + math.cos(a) * Council.chairs, 0.28));
        return DeskDef(
          id: m.id,
          room: true,
          x: council.x + math.sin(a) * Council.place,
          z: council.z + math.cos(a) * Council.place,
          rotY: a,
          label: m.label,
        );
      }(),
  ];
  circles.add((council.x, council.z, Council.radius));
  final ex = council.x - math.sin(council.rotY) * Council.easel;
  final ez = council.z - math.cos(council.rotY) * Council.easel;
  inside(ex, ez, 'the council’s easel');
  rects.add(boxFootprint(ex, ez, 2.6, 0.5, council.rotY));

  // The boards on the walls.
  if (!isObj(c['boards'])) throw const MapError('it needs boards: issues, queue, pulls and services');
  final rawBoards = objOf(c['boards']);
  final boards = <BoardKey, BoardDef>{};
  for (final k in boardKeys) {
    final b0 = rawBoards[k.wire];
    if (!isObj(b0)) throw MapError('it needs boards.${k.wire}: { x, y, z, rotY, width, height }');
    final b = objOf(b0);
    boards[k] = BoardDef(
      x: checkNum(b['x'], 'boards.${k.wire}.x', bounds.minX, bounds.maxX),
      y: checkNum(b['y'], 'boards.${k.wire}.y', 0.5, height),
      z: checkNum(b['z'], 'boards.${k.wire}.z', bounds.minZ, bounds.maxZ),
      rotY: checkNum(b['rotY'], 'boards.${k.wire}.rotY'),
      width: checkNum(b['width'], 'boards.${k.wire}.width', 1, 12),
      height: checkNum(b['height'], 'boards.${k.wire}.height', 0.8, 8),
      label: b['label'] is String && (b['label'] as String).trim().isNotEmpty
          ? _cut((b['label'] as String).trim(), 40)
          : _defaultBoardLabel[k]!,
    );
  }

  // The throne, the Hand beside it, and the line in front of it.
  // Each of these can be left out (or set to null, to take away one a map it extends has).
  final seatingList = <SeatDef>[];
  SeatDef? throne;
  Dais? dais;
  if (c['throne'] != null) {
    final p = place(c['throne'], 'throne');
    final th = objOf(c['throne']);
    final d = th['dais'];
    if (d != null && !isObj(d)) throw const MapError('throne.dais should be { width, depth, height, steps }');
    if (d != null) {
      final o = objOf(d);
      final dd = (
        width: checkNum(o['width'], 'throne.dais.width', 2, 40),
        depth: checkNum(o['depth'], 'throne.dais.depth', 2.6, 20),
        height: checkNum(o['height'], 'throne.dais.height', 0, 3),
      );
      final steps = checkNum(o['steps'], 'throne.dais.steps', 0, 10);
      if (steps != steps.truncateToDouble()) throw const MapError('throne.dais.steps should be a whole number');
      dais = (width: dd.width, depth: dd.depth, height: dd.height, steps: steps.toInt());
    } else {
      dais = defaultDais;
    }
    final label = th['label'] is String && (th['label'] as String).trim().isNotEmpty
        ? _cut((th['label'] as String).trim(), 40)
        : '👑 Throne';
    throne = SeatDef(
      id: 'throne',
      label: label,
      x: p.x,
      y: dais.height,
      z: p.z,
      rotY: p.rotY,
      places: const [0],
      hips: 0.74,
      depth: 0.12,
      out: 1.1,
    );
    seatingList.add(throne);
    rects.add(boxFootprint(p.x, p.z - math.cos(p.rotY) * 0.2, ThroneSize.width, ThroneSize.depth, p.rotY));
  }
  HeraldPlan? herald;
  // Which of `circles` is the herald's own spot, which where people stand may be in.
  var heraldAt = -1;
  if (c['herald'] != null) {
    final p = place(c['herald'], 'herald');
    final h = objOf(c['herald']);
    String text(Object? v, int max, String dflt) => v is String && v.trim().isNotEmpty ? _cut(v.trim(), max) : dflt;
    herald = (
      x: p.x,
      z: p.z,
      rotY: p.rotY,
      name: text(h['name'], 40, 'Herald'),
      says: text(h['says'], 80, 'Speak to me to send out a new worker'),
      ask: text(h['ask'], 80, 'What should they work on?'),
      button: text(h['button'], 30, 'Send them out'),
    );
    heraldAt = circles.length;
    circles.add((p.x, p.z, 0.35));
  }
  final lineup = <({double x, double z, double rotY})>[];
  if (c['lineup'] != null) {
    final l0 = c['lineup'];
    if (!isObj(l0) || (l0 as Map)['step'] is! List) {
      throw const MapError('lineup should be { x, z, rotY, step: [dx, dz], count }');
    }
    final l = objOf(l0);
    final count = checkNum(l['count'], 'lineup.count', 1, 30);
    if (count != count.truncateToDouble()) throw const MapError('lineup.count should be a whole number');
    final step = l['step'] as List;
    final dx = checkNum(step.isNotEmpty ? step[0] : null, 'lineup.step[0]', -5, 5);
    final dz = checkNum(step.length > 1 ? step[1] : null, 'lineup.step[1]', -5, 5);
    for (var i = 0; i < count; i++) {
      final x = checkNum(l['x'], 'lineup.x') + dx * i;
      final z = checkNum(l['z'], 'lineup.z') + dz * i;
      inside(x, z, 'lineup spot ${i + 1}');
      lineup.add((x: x, z: z, rotY: checkNum(l['rotY'], 'lineup.rotY')));
    }
  }

  // Everything else.
  final props = c['props'] ?? const [];
  if (props is! List) throw const MapError('props should be a list');
  if (props.length > MapLimits.props)
    throw MapError('it has ${props.length} props, and a map can have ${MapLimits.props}');
  for (var i = 0; i < props.length; i++) {
    final what = 'props[$i]';
    final p0 = props[i];
    if (!isObj(p0) || (p0 as Map)['kind'] is! String) throw MapError('$what should be { kind, x, z }');
    final p = objOf(p0);
    final kind = p['kind'] as String;
    if (!kinds.kinds.containsKey(kind)) {
      throw MapError(
        '$what is a "$kind", which isn’t a kind of prop a ${style.wire}-style map has (${kinds.kinds.keys.join(', ')})',
      );
    }
    inside(checkNum(p['x'], '$what.x'), checkNum(p['z'], '$what.z'), '$what (a $kind)', 0);
    // Everything the builder reads, in sizes it can build.
    opt(p['y'], '$what.y', 0, 100);
    opt(p['rotY'], '$what.rotY', -1e4, 1e4);
    opt(p['scale'], '$what.scale', 0.2, 5);
    opt(p['width'], '$what.width', 0.3, 20);
    opt(p['height'], '$what.height', 0.3, 20);
    opt(p['length'], '$what.length', 0.3, 120);
    if (p['light'] != null && p['light'] is! bool) throw MapError('$what.light should be true or false');
    // What hangs on a wall, or from the roof, has to fit under the walls' top.
    final prop = PropConfig.fromJson(p);
    final top = kinds.top(prop);
    if (top > height) {
      throw MapError(
        "props[$i] (a $kind) reaches ${fixed1(top)} m up, over the hall's ${jsNum(height)} m walls: lower its y, or raise hall.height",
      );
    }
    final f = kinds.footprint(prop);
    if (f?.rect != null) rects.add(f!.rect!);
    if (f?.circle != null) circles.add(f!.circle!);
  }
  if (props.where((p) => p is Map && p['kind'] == 'gong').length > 1) throw const MapError('it has more than one gong');

  // The dungeon under the hall: the hole in the floor over its stairs, with rails round it, has to be clear.
  if (c['dungeon'] != null && style == MapStyle.station) {
    throw const MapError(
      'a station-style map has no dungeon to dig: take it away ("dungeon": null), and give it an airlock instead',
    );
  }
  if (c['airlock'] != null && style != MapStyle.station)
    throw const MapError('only a station-style map has an airlock');
  final dungeon = c['dungeon'] == null ? null : planDungeon(c['dungeon'], bounds);
  if (dungeon != null) {
    final (x0, x1, z0, z1) = dungeon.rails;
    final hit =
        rects.any((r) => rectsOverlap(r, dungeon.rails)) ||
        circles.any((o) {
          final dx = o.$1 - o.$1.clamp(x0, x1);
          final dz = o.$2 - o.$2.clamp(z0, z1);
          return math.sqrt(dx * dx + dz * dz) < o.$3;
        });
    if (hit) {
      throw const MapError(
        'the dungeon stairs come up through something in the hall (a table, a bench, a pillar or the like): move them, or it',
      );
    }
    rects.add(dungeon.rails);
  }

  if (c['palette'] != null) {
    if (!isObj(c['palette'])) {
      throw const MapError('palette should be colors by name, like { stone, floor, carpet, wood, trim } for a castle');
    }
    for (final MapEntry(:key, :value) in objOf(c['palette']).entries) {
      if (value is! String || value.length > 40) throw MapError('palette.$key should be a CSS color');
    }
  }
  final door = place(c['door'], 'door');
  // A station's walls: the way in, the airlock and the windows cut through them.
  final airlock = c['airlock'] == null ? null : planAirlock(c['airlock'], bounds);
  final openings = style == MapStyle.station ? wallOpenings(c, bounds, height, airlock) : null;
  final spawn = c['spawn'] != null && c['spawn'] != false
      ? place(c['spawn'], 'spawn')
      : (x: door.x, z: door.z, rotY: math.atan2(-door.x, -door.z));
  // Where people and workers stand has to be clear of what's in the way (the herald's own spot aside).
  bool free(double x, double z) =>
      !rects.any((r) => x > r.$1 && x < r.$2 && z > r.$3 && z < r.$4) &&
      !circles.indexed.any((e) {
        final (i, o) = e;
        if (i == heraldAt) return false;
        final dx = x - o.$1;
        final dz = z - o.$2;
        return math.sqrt(dx * dx + dz * dz) < o.$3;
      });
  void clear(double x, double z, String what) {
    if (!free(x, z)) {
      throw MapError('$what (${fixed1(x)}, ${fixed1(z)}) is inside something: a table, a bench, a pillar or the like');
    }
  }

  for (var i = 0; i < lineup.length; i++) {
    clear(lineup[i].x, lineup[i].z, 'lineup spot ${i + 1}');
  }
  if (herald != null) clear(herald.x, herald.z, 'the herald');
  for (final MapEntry(key: k, value: f) in fixtures.entries) {
    final (x, z) = fixtureFront(f);
    inside(x, z, 'where you use the ${k.wire}', 0);
    clear(x, z, 'where you use the ${k.wire}');
  }
  clear(spawn.x, spawn.z, 'spawn');
  clear(door.x, door.z, 'door');
  if (dungeon != null) clear(dungeon.stairs.top.$1, dungeon.stairs.top.$2, 'the way onto the dungeon stairs');
  if (airlock != null) clear(airlock.front.$1, airlock.front.$2, 'the way up to the airlock');
  final sendHome = planSendHome(c['sendHome'], bounds, free, dungeon, airlock);
  final agents = c['agents'] is Map ? objOf(c['agents']) : const <String, dynamic>{};
  final outfit = agents['outfit'] == 'peasant' ? 'peasant' : 'none';
  final ageMinutes = agents['ageMinutes'] == null
      ? 0.0
      : checkNum(agents['ageMinutes'], 'agents.ageMinutes', 0, 100000);
  final byId = {
    for (final d in [...mapDeskList, ...overflow, ...stationDefs, ...meeting]) d.id: d,
  };
  for (final d in byId.values) {
    inside(d.x, d.z, d.label);
  }
  return MapPlan(
    id: id,
    name: name,
    icon: c['icon'] is String && (c['icon'] as String).trim().isNotEmpty
        ? _cut((c['icon'] as String).trim(), 8)
        : '🗺️',
    description: c['description'] is String ? _cut(c['description'] as String, 400) : '',
    style: style == MapStyle.castle ? PlanStyle.castle : PlanStyle.station,
    config: c,
    bounds: bounds,
    height: height,
    spawn: (x: spawn.x, y: 0, z: spawn.z, rotY: spawn.rotY),
    desks: mapDeskList,
    overflow: overflow,
    stations: stationDefs,
    meeting: meeting,
    byId: byId,
    seating: seatingList,
    seatingById: {for (final s in seatingList) s.id: s},
    throne: throne,
    dais: dais,
    lineup: lineup,
    herald: herald,
    door: (x: door.x, z: door.z),
    tables: tables,
    council: council,
    boards: boards,
    obstacles: Obstacles(rects: rects, circles: circles),
    outfit: outfit,
    ageMinutes: ageMinutes,
    dungeon: dungeon,
    airlock: airlock,
    openings: openings,
    sendHome: sendHome,
    fixtures: fixtures,
  );
}

/// Where you stand to use a map's fixture: a metre in front of it.
(double, double) fixtureFront(FixturePlan f) => (f.x - math.sin(f.rotY), f.z - math.cos(f.rotY));

// ---- Which maps there are -------------------------------------------------------------------------

/// A custom map read from a file, checked: its config if it can be used, else why not.
class CustomMap {
  const CustomMap({required this.file, this.config, this.error});

  factory CustomMap.fromJson(Map<String, dynamic> j) =>
      CustomMap(file: asString(j['file']), config: asMapOrNull(j['config']), error: asStringOrNull(j['error']));

  final String file;
  final MapConfig? config;
  final String? error;

  Map<String, dynamic> toJson() => {'file': file, 'config': ?config, 'error': ?error};
}

/// Checks the custom maps (JSON from the office's .agent-office/maps/) against the built-in ones and
/// each other: each comes back with its whole config (what it extends filled in), or why it can't be used.
List<CustomMap> checkCustomMaps(List<({String file, Object? json})> files) {
  final raw = <String, MapConfig>{};
  final out = [
    for (final f in files)
      () {
        final json = f.json;
        if (!isObj(json)) return CustomMap(file: f.file, error: 'it isn’t a JSON object');
        final config = objOf(json);
        final id = config['id'];
        if (id is! String) return CustomMap(file: f.file, error: 'it needs an id');
        if (id == officeMap || builtinMaps.any((m) => m['id'] == id)) {
          return CustomMap(
            file: f.file,
            error: '"$id" is a built-in map’s id: pick another, and "extends": "$id" to start from it',
          );
        }
        if (raw.containsKey(id)) return CustomMap(file: f.file, error: 'another file has the id "$id" too');
        raw[id] = config;
        return CustomMap(file: f.file, config: config);
      }(),
  ];
  MapConfig? known(String id) => raw[id] ?? builtinMaps.where((m) => m['id'] == id).firstOrNull;
  return [
    for (final m in out)
      if (m.config == null)
        m
      else
        () {
          try {
            final config = resolveConfig(m.config!, known);
            planMap(config);
            return CustomMap(file: m.file, config: config);
          } on MapError catch (e) {
            return CustomMap(file: m.file, error: e.message);
          } catch (e) {
            return CustomMap(file: m.file, error: '$e');
          }
        }(),
  ];
}

/// Every map there is to pick, the office first, and the custom ones that won't load with why.
List<MapChoice> mapChoices([List<CustomMap> custom = const []]) {
  MapPlan plan(MapConfig c) => planOf(c['id'] as String?, custom);
  return [
    MapChoice(id: officePlan.id, name: officePlan.name, icon: officePlan.icon, description: officePlan.description),
    for (final c in builtinMaps)
      () {
        final p = plan(c);
        return MapChoice(id: p.id, name: p.name, icon: p.icon, description: p.description);
      }(),
    for (final m in custom)
      if (m.config == null)
        MapChoice(id: m.file, name: m.file, icon: '⚠️', description: '', custom: true, error: m.error)
      else
        () {
          final p = plan(m.config!);
          return MapChoice(id: p.id, name: p.name, icon: p.icon, description: p.description, custom: true);
        }(),
  ];
}

final Map<String, ({MapConfig config, String key, MapPlan plan})> _plans = {};

/// The plan of the map [id]: the office, a built-in map, or a custom one (already checked, see
/// [checkCustomMaps]). Anything else, or one that won't load, is the office.
MapPlan planOf(String? id, [List<CustomMap> custom = const []]) {
  if (id == null || id.isEmpty || id == officeMap) return officePlan;
  final config =
      custom.where((m) => m.config?['id'] == id).firstOrNull?.config ??
      builtinMaps.where((m) => m['id'] == id).firstOrNull;
  if (config == null) return officePlan;
  final hit = _plans[id];
  // The same config as last time (it's asked for often): no need to look any closer.
  if (hit != null && identical(hit.config, config)) return hit.plan;
  final key = jsonEncode(config);
  if (hit != null && hit.key == key) {
    _plans[id] = (config: config, key: key, plan: hit.plan);
    return hit.plan;
  }
  try {
    final plan = planMap(config);
    _plans[id] = (config: config, key: key, plan: plan);
    return plan;
  } catch (_) {
    return officePlan;
  }
}

/// Whether [id] names a map that can be picked.
bool isMapChoice(Object? id, [List<CustomMap> custom = const []]) =>
    id is String &&
    (id == officeMap || builtinMaps.any((m) => m['id'] == id) || custom.any((m) => m.config?['id'] == id));

final RegExp _seatKey = RegExp(r'^([\w-]+):(\d+)$');

/// The place a peer's `seat` names on [plan] (see seatAt), or null if there's no such place.
SeatPlace? seatOn(MapPlan plan, String key) {
  final m = _seatKey.firstMatch(key);
  final seat = m != null ? plan.seatingById[m[1]] : null;
  final i = m != null ? int.tryParse(m[2]!) : null;
  return seat != null && i != null && i < seat.places.length ? seatPlace(seat, i) : null;
}

/// The place [key] names on [plan], if it's somewhere you can sit from where you are (see seatHere):
/// up on the roof, or down on a floor.
SeatPlace? seatHereOn(MapPlan plan, String key, bool onRoof) {
  if (plan.style == PlanStyle.office || onRoof) return seatHere(key, onRoof);
  return seatOn(plan, key);
}
