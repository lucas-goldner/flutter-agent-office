// The dungeon under a hall, and what happens to a worker sent home (the config's `dungeon` and
// `sendHome`). The dungeon is a vault dug out under the hall's floor, stairs down into it through a
// hole in that floor, and cells along its walls. A map's `sendHome` is a little script: steps a worker
// (and the escort that comes for it) go through one after another, say, the castle's Kingsguard
// running up from the dungeon, marching it down there and throwing it into a cell. A worker that's
// jailed is kept there for good (the server remembers it), and wastes away: thinner and thinner until
// it starves to death, then it rots down to bare bones. On a station it's the airlock instead
// (airlock.dart): a worker that's ejected is kept the same way, adrift outside.
//
// Everything here is worked out from plain numbers, so another map's dungeon, or its own way of
// seeing workers off, is just other numbers and other steps (docs/maps.md). The client acts the steps
// out; new kinds of step go in [sendHomeSteps] and there. Ported from src/shared/maps/dungeon.ts.

import 'dart:math' as math;

import '../nav.dart';
import 'check.dart';
import 'props.dart';
import 'types.dart';

/// How thick the hall's floor is over the vault: its ceiling is this far under the hall's floor.
const double dungeonSlab = 0.4;

/// Each stair down: at most this high, and this deep.
const double _rise = 0.24;
const double _tread = 0.34;

/// How wide the stairs are when the map doesn't say.
const double _stairsWidth = 2.2;

/// The rail round the hole in the hall's floor, this thick.
const double _rail = 0.2;

/// A pillar down there, and the heap of bones.
const double dungeonPillar = 0.9;
const double ossuaryRadius = 1.1;

/// How far apart prisoners sit, and how far off the walls.
const double _seatGap = 1.15;
const double _offWall = 0.45;

/// Where a worker is thrown in from (just outside the door), and where the escort stands to do it.
const double _thresholdOut = 0.35;
const double _outsideOut = 1.0;

abstract final class DungeonLimits {
  static const int cells = 40;
  static const int pillars = 40;
  static const int torches = 40;
  static const int steps = 30;
}

/// The kinds of step a send-home script can have (see [SendHomeStep]), and what each does.
const Map<SendHomeStepKind, String> sendHomeSteps = {
  SendHomeStepKind.pack: 'It packs its things into a box at its seat, and its laptop (or tome) shuts',
  SendHomeStepKind.fetch: 'The escort comes from its post to the worker',
  SendHomeStepKind.say: 'The worker (or, with "who": "escort", its escort) says something',
  SendHomeStepKind.walk: 'The worker walks somewhere, the escort holding on to it if it has fetched it',
  SendHomeStepKind.jail: 'It is thrown into a cell and locked in: it stays there for good',
  SendHomeStepKind.eject: 'It is shoved into the airlock and blown out into space: it stays out there for good',
  SendHomeStepKind.leave: 'It is gone, shrinking away wherever it is',
  SendHomeStepKind.wait: 'A pause, "seconds" long',
  SendHomeStepKind.return_: 'The escort goes back to its post',
};

/// Whether [a] is a multiple of a quarter turn: the stairs and the cells run along the walls.
double _quarter(double a, String what) {
  final k = (a / (math.pi / 2)).round();
  if ((a - (k * math.pi) / 2).abs() > 0.01) {
    throw MapError('$what should be a quarter turn: 0, 1.5708 (π/2), 3.1416 (π) or -1.5708');
  }
  return (k * math.pi) / 2;
}

bool _within(Bounds b, double x, double z, [double m = 0]) =>
    x > b.minX + m && x < b.maxX - m && z > b.minZ + m && z < b.maxZ - m;
bool _rectIn(Bounds b, NavRect r, [double m = 0]) =>
    r.$1 >= b.minX + m - 1e-6 && r.$2 <= b.maxX - m + 1e-6 && r.$3 >= b.minZ + m - 1e-6 && r.$4 <= b.maxZ - m + 1e-6;

/// Whether two rects overlap by more than a sliver (touching is fine). TS `overlaps`.
bool rectsOverlap(NavRect a, NavRect b) =>
    math.min(a.$2, b.$2) - math.max(a.$1, b.$1) > 0.02 && math.min(a.$4, b.$4) - math.max(a.$3, b.$3) > 0.02;
NavRect _grow(NavRect r, double m) => (r.$1 - m, r.$2 + m, r.$3 - m, r.$4 + m);
bool _inRect(NavRect r, double x, double z, [double m = 0]) =>
    x > r.$1 - m && x < r.$2 + m && z > r.$3 - m && z < r.$4 + m;
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// The places in a cell its prisoners sit, the ones along its back wall first (the middle one first),
/// then down its sides.
List<Spot> _cellSpots(({double x, double z, double rotY, double width, double depth}) c, double floor) {
  // The cell's own frame: `out` through its bars into the vault, `across` along them.
  final out = (math.sin(c.rotY), math.cos(c.rotY));
  final across = (math.cos(c.rotY), -math.sin(c.rotY));
  Spot at(double u, double v, double rotY) =>
      Spot(x: c.x + across.$1 * u - out.$1 * v, y: floor, z: c.z + across.$2 * u - out.$2 * v, rotY: rotY);
  final spots = <Spot>[];
  // Along the back wall, facing out through the bars.
  final back = math.max(1, ((c.width - 2 * _offWall) / _seatGap).floor() + 1);
  final span = math.min(c.width - 2 * _offWall, (back - 1) * _seatGap);
  final us = [for (var i = 0; i < back; i++) back == 1 ? 0.0 : -span / 2 + (span * i) / (back - 1)]
    ..sort((a, b) {
      final d = a.abs().compareTo(b.abs());
      return d != 0 ? d : a.compareTo(b);
    });
  for (final u in us) {
    spots.add(at(u, c.depth - _offWall, c.rotY));
  }
  // Down each side wall, facing across the cell, clear of the ones at the back and of the door.
  final sides = <double>[];
  for (var v = c.depth - _offWall - _seatGap; v >= 1.1; v -= _seatGap) {
    sides.add(v);
  }
  if (c.width >= 2 * _offWall + 1.3) {
    for (final v in sides) {
      for (final s in const [-1, 1]) {
        spots.add(at(s * (c.width / 2 - _offWall), v, c.rotY + (s < 0 ? -math.pi / 2 : math.pi / 2) + math.pi));
      }
    }
  }
  return spots;
}

/// Checks a map's dungeon and works out where everything in it is. [hall] is the hall above it: the
/// vault has to be under it (the hall's walls are its walls' tops), and so do the stairs' tops.
DungeonPlan planDungeon(Object? input, Bounds hall) {
  if (!isObj(input)) throw const MapError('dungeon should be { x, z, width, length, depth, stairs, cells }');
  final d = objOf(input);
  final x = checkNum(d['x'], 'dungeon.x');
  final z = checkNum(d['z'], 'dungeon.z');
  final width = checkNum(d['width'], 'dungeon.width', 4, 110);
  final length = checkNum(d['length'], 'dungeon.length', 4, 110);
  final depth = checkNum(d['depth'], 'dungeon.depth', 2.6, 20);
  final bounds = Bounds(minX: x - width / 2, maxX: x + width / 2, minZ: z - length / 2, maxZ: z + length / 2);
  if (!_rectIn(hall, (bounds.minX, bounds.maxX, bounds.minZ, bounds.maxZ), 0.2)) {
    throw const MapError('the dungeon should be under the hall, at least 0.2 m in from its walls');
  }
  final floor = -depth;
  const ceiling = -dungeonSlab;

  // The stairs: straight down from the hole in the hall's floor to the vault's.
  if (!isObj(d['stairs'])) throw const MapError('dungeon.stairs should be { x, z, rotY, width }');
  final st = objOf(d['stairs']);
  final sx = checkNum(st['x'], 'dungeon.stairs.x');
  final sz = checkNum(st['z'], 'dungeon.stairs.z');
  final rotY = _quarter(checkNum(st['rotY'] ?? 0, 'dungeon.stairs.rotY'), 'dungeon.stairs.rotY');
  final sw = st['width'] == null ? _stairsWidth : checkNum(st['width'], 'dungeon.stairs.width', 1.2, 6);
  final along = (math.sin(rotY).roundToDouble(), math.cos(rotY).roundToDouble());
  final n = (depth / _rise).ceil();
  final rise = depth / n;
  final run = n * _tread;
  final steps = [
    for (var i = 0; i < n; i++)
      (
        top: -(i + 1) * rise,
        rect: boxFootprint(sx + along.$1 * (i + 0.5) * _tread, sz + along.$2 * (i + 0.5) * _tread, sw, _tread, rotY),
      ),
  ];
  final opening = boxFootprint(sx + (along.$1 * run) / 2, sz + (along.$2 * run) / 2, sw, run, rotY);
  final rails = _grow(opening, _rail);
  final Pt start = (sx, sz);
  final Pt end = (sx + along.$1 * run, sz + along.$2 * run);
  final Pt top = (sx - along.$1 * 0.75, sz - along.$2 * 0.75);
  final Pt foot = (end.$1 + along.$1 * 0.7, end.$2 + along.$2 * 0.7);
  if (!_rectIn(bounds, opening)) {
    throw MapError(
      "the dungeon's stairs ($n steps, ${fixed1(run)} m long) should go down inside it: move them, or make the dungeon bigger",
    );
  }
  if (!_rectIn(hall, rails, 0.2)) throw const MapError('the top of the dungeon stairs should be in the hall');
  if (!_within(hall, top.$1, top.$2, 0.3)) {
    throw const MapError('there should be room in the hall to walk up to the dungeon stairs');
  }
  if (!_within(bounds, foot.$1, foot.$2, 0.3)) {
    throw const MapError('there should be room at the foot of the dungeon stairs: they run into the dungeon’s wall');
  }

  // The cells, along the walls.
  final rawCells = d['cells'];
  if (rawCells is! List || rawCells.isEmpty) {
    throw const MapError('dungeon.cells should be a list of cells, { x, z, rotY, width, depth }');
  }
  if (rawCells.length > DungeonLimits.cells) {
    throw MapError('the dungeon has ${rawCells.length} cells, and it can have ${DungeonLimits.cells}');
  }
  final rects = <NavRect>[opening];
  final circles = <NavCircle>[];
  final cells = <CellPlan>[];
  for (var i = 0; i < rawCells.length; i++) {
    final what = 'dungeon.cells[$i]';
    if (!isObj(rawCells[i])) throw MapError('$what should be { x, z, rotY, width, depth }');
    final c = objOf(rawCells[i]);
    final cell = (
      x: checkNum(c['x'], '$what.x'),
      z: checkNum(c['z'], '$what.z'),
      rotY: _quarter(checkNum(c['rotY'] ?? 0, '$what.rotY'), '$what.rotY'),
      width: checkNum(c['width'], '$what.width', 2, 12),
      depth: checkNum(c['depth'], '$what.depth', 1.8, 10),
    );
    final out = (math.sin(cell.rotY), math.cos(cell.rotY));
    final rect = boxFootprint(
      cell.x - (out.$1 * cell.depth) / 2,
      cell.z - (out.$2 * cell.depth) / 2,
      cell.width,
      cell.depth,
      cell.rotY,
    );
    if (!_rectIn(bounds, rect)) throw MapError('$what should be inside the dungeon');
    for (var j = 0; j < rects.length; j++) {
      if (rectsOverlap(rect, rects[j])) {
        throw MapError('$what runs into ${j == 0 ? 'the stairs' : 'dungeon.cells[${j - 1}]'}');
      }
    }
    rects.add(rect);
    final Pt outside = (cell.x + out.$1 * _outsideOut, cell.z + out.$2 * _outsideOut);
    if (!_within(bounds, outside.$1, outside.$2, 0.3)) {
      throw MapError("$what's door should open into the dungeon, with room in front of it");
    }
    cells.add(
      CellPlan(
        x: cell.x,
        z: cell.z,
        rotY: cell.rotY,
        width: cell.width,
        depth: cell.depth,
        outside: outside,
        threshold: (cell.x + out.$1 * _thresholdOut, cell.z + out.$2 * _thresholdOut),
        spots: _cellSpots(cell, floor),
      ),
    );
  }
  final most = cells.map((c) => c.spots.length).reduce(math.max);
  final seats = <CellSeat>[];
  for (var k = 0; k < most; k++) {
    for (var i = 0; i < cells.length; i++) {
      if (k < cells[i].spots.length) seats.add((cell: i, spot: cells[i].spots[k]));
    }
  }

  List<T> list<T>(Object? v, String what, int max, T Function(Map<String, dynamic> o, String what) each) {
    if (v == null) return [];
    if (v is! List) throw MapError('$what should be a list');
    if (v.length > max) throw MapError('$what has ${v.length}, and it can have $max');
    return [
      for (var i = 0; i < v.length; i++)
        if (!isObj(v[i])) throw MapError('$what[$i] should be { x, z }') else each(objOf(v[i]), '$what[$i]'),
    ];
  }

  final pillars = list<Pt>(d['pillars'], 'dungeon.pillars', DungeonLimits.pillars, (o, what) {
    final Pt p = (checkNum(o['x'], '$what.x'), checkNum(o['z'], '$what.z'));
    if (!_within(bounds, p.$1, p.$2, dungeonPillar / 2)) throw MapError('$what should be inside the dungeon');
    if (rects.any((r) => _inRect(r, p.$1, p.$2, dungeonPillar / 2)))
      throw MapError('$what is in a cell, or on the stairs');
    circles.add((p.$1, p.$2, dungeonPillar / 2 + 0.05));
    return p;
  });
  final torches = list(d['torches'], 'dungeon.torches', DungeonLimits.torches, (o, what) {
    final t = (
      x: checkNum(o['x'], '$what.x'),
      z: checkNum(o['z'], '$what.z'),
      rotY: checkNum(o['rotY'] ?? 0, '$what.rotY'),
    );
    if (!(t.x >= bounds.minX - 0.01 &&
        t.x <= bounds.maxX + 0.01 &&
        t.z >= bounds.minZ - 0.01 &&
        t.z <= bounds.maxZ + 0.01)) {
      throw MapError("$what should be on the dungeon's walls, or inside it");
    }
    return t;
  });
  Pt? ossuary;
  if (d['ossuary'] != null) {
    if (!isObj(d['ossuary'])) throw const MapError('dungeon.ossuary should be { x, z }');
    final o = objOf(d['ossuary']);
    final Pt p = (checkNum(o['x'], 'dungeon.ossuary.x'), checkNum(o['z'], 'dungeon.ossuary.z'));
    if (!_within(bounds, p.$1, p.$2, ossuaryRadius)) {
      throw const MapError('dungeon.ossuary should be inside the dungeon, with room for the heap');
    }
    if (rects.any((r) => _inRect(r, p.$1, p.$2, ossuaryRadius))) {
      throw const MapError('dungeon.ossuary is in a cell, or on the stairs');
    }
    circles.add((p.$1, p.$2, ossuaryRadius));
    ossuary = p;
  }
  final plan = DungeonPlan(
    bounds: bounds,
    floor: floor,
    ceiling: ceiling,
    opening: opening,
    rails: rails,
    steps: steps,
    stairs: (rotY: rotY, width: sw, top: top, start: start, end: end, foot: foot),
    cells: cells,
    seats: seats,
    pillars: pillars,
    torches: torches,
    ossuary: ossuary,
    obstacles: Obstacles(rects: rects, circles: circles),
  );
  // Where the escort stands and walkers go has to be clear.
  bool blocked(double px, double pz) =>
      rects.any((r) => _inRect(r, px, pz, 0.25)) || circles.any((c) => _hypot(px - c.$1, pz - c.$2) < c.$3 + 0.25);
  if (blocked(foot.$1, foot.$2))
    throw const MapError('the foot of the dungeon stairs runs into a cell, a pillar or the bones');
  for (var i = 0; i < cells.length; i++) {
    if (blocked(cells[i].outside.$1, cells[i].outside.$2)) {
      throw MapError("something's in the way of dungeon.cells[$i]'s door");
    }
  }
  return plan;
}

/// Whether (x, z) is clear to stand in, down in the dungeon.
bool dungeonClear(DungeonPlan d, double x, double z) =>
    _within(d.bounds, x, z, 0.3) &&
    !d.obstacles.rects.any((r) => _inRect(r, x, z, 0.25)) &&
    !d.obstacles.circles.any((c) => _hypot(x - c.$1, z - c.$2) < c.$3 + 0.25);

// ---- Sending workers home ---------------------------------------------------------------------

/// Without a word from the map, it takes a day to starve down there, and half a day more to rot to the bone.
const double starveHours = 24;
const double rotHours = 12;

String _placesList() => SendHomeSpot.values.map((p) => '"${p.wire}"').join(', ');

SendHomePlace _place(Object? v, String what) {
  if (v is String) {
    final spot = SendHomeSpot.tryParse(v);
    if (spot == null) throw MapError('$what should be one of ${_placesList()}, or { x, z }');
    return SendHomePlace.named(spot);
  }
  if (!isObj(v)) throw MapError('$what should be one of ${_placesList()}, or { x, z }');
  final o = objOf(v);
  if (o['below'] != null && o['below'] is! bool) throw MapError('$what.below should be true or false');
  return SendHomePlace.at(checkNum(o['x'], '$what.x'), checkNum(o['z'], '$what.z'), below: o['below'] == true);
}

/// Checks a map's `sendHome` against its hall ([hall], what's in its way [hallClear]), its dungeon and
/// its airlock, and fills in what it leaves out. Null when there's none: a worker just walks out of
/// the door.
SendHomePlan? planSendHome(
  Object? input,
  Bounds hall,
  bool Function(double x, double z) hallClear,
  DungeonPlan? dungeon, [
  AirlockPlan? airlock,
]) {
  if (input == null) return null;
  if (!isObj(input)) throw const MapError('sendHome should be { escort, steps }');
  final c = objOf(input);
  void needDungeon(String what) {
    if (dungeon == null) throw MapError('sendHome $what, and the map has no dungeon');
  }

  void needAirlock(String what) {
    if (airlock == null) throw MapError('sendHome $what, and the map has no airlock');
  }

  /// A spot someone can stand in: in the hall, or with [below], down in the dungeon.
  void standing(double x, double z, bool below, String what) {
    if (below) {
      needDungeon('has $what down in the dungeon');
      if (!dungeonClear(dungeon!, x, z)) {
        throw MapError('$what (${fixed1(x)}, ${fixed1(z)}) should be somewhere clear in the dungeon');
      }
    } else if (!_within(hall, x, z, 0.3) || !hallClear(x, z)) {
      throw MapError('$what (${fixed1(x)}, ${fixed1(z)}) should be somewhere clear in the hall');
    }
  }

  SendHomeEscort? escort;
  if (c['escort'] != null) {
    final e = c['escort'];
    if (!isObj(e) || !isObj((e as Map)['post'])) {
      throw const MapError('sendHome.escort should be { name, post: { x, z, rotY, below } }');
    }
    final p = objOf(e['post']);
    final below = p['below'] == true;
    final x = checkNum(p['x'], 'sendHome.escort.post.x');
    final z = checkNum(p['z'], 'sendHome.escort.post.z');
    final rotY = checkNum(p['rotY'] ?? 0, 'sendHome.escort.post.rotY');
    standing(x, z, below, 'sendHome.escort.post');
    final name = e['name'] is String && (e['name'] as String).trim().isNotEmpty
        ? _cut((e['name'] as String).trim(), 40)
        : 'Guard';
    final color = e['color'] is String && (e['color'] as String).length <= 40 ? e['color'] as String : '#8e1b1b';
    escort = (
      name: name,
      color: color,
      post: Spot(x: x, y: below ? dungeon!.floor : 0, z: z, rotY: rotY),
      below: below,
    );
  }
  void needEscort(String what) {
    if (escort == null) throw MapError('sendHome has $what, and no escort');
  }

  final rawSteps = c['steps'];
  if (rawSteps is! List || rawSteps.isEmpty) {
    throw const MapError(
      'sendHome.steps should be a list of steps, like [{ "do": "pack" }, { "do": "walk", "to": "door" }]',
    );
  }
  if (rawSteps.length > DungeonLimits.steps) {
    throw MapError('sendHome has ${rawSteps.length} steps, and it can have ${DungeonLimits.steps}');
  }
  // Once it's jailed or gone, only the escort has anything left to do.
  var done = '';
  final steps = <SendHomeStep>[];
  for (var i = 0; i < rawSteps.length; i++) {
    final what = 'sendHome.steps[$i]';
    final s0 = rawSteps[i];
    if (!isObj(s0) || (s0 as Map)['do'] is! String) throw MapError('$what should be { "do": … }');
    final s = objOf(s0);
    final kind = SendHomeStepKind.tryParse(s['do']);
    if (kind == null) {
      throw MapError(
        "$what does \"${s['do']}\", which isn't a step there is (${SendHomeStepKind.values.map((k) => k.wire).join(', ')})",
      );
    }
    final worker =
        kind == SendHomeStepKind.pack ||
        kind == SendHomeStepKind.walk ||
        kind == SendHomeStepKind.jail ||
        kind == SendHomeStepKind.eject ||
        kind == SendHomeStepKind.leave ||
        kind == SendHomeStepKind.fetch ||
        (kind == SendHomeStepKind.say && s['who'] != 'escort');
    if (worker && done.isNotEmpty) {
      throw MapError("$what: the worker's $done by then, so only its escort can do anything more");
    }
    switch (kind) {
      case SendHomeStepKind.pack:
      case SendHomeStepKind.leave:
        if (kind == SendHomeStepKind.leave) done = 'gone';
        steps.add(SendHomeStep(kind));
      case SendHomeStepKind.jail:
        needDungeon('jails workers');
        done = 'locked up';
        steps.add(const SendHomeStep(SendHomeStepKind.jail));
      case SendHomeStepKind.eject:
        needAirlock('ejects workers');
        done = 'out of the airlock';
        steps.add(const SendHomeStep(SendHomeStepKind.eject));
      case SendHomeStepKind.fetch:
        needEscort('an escort fetching the worker');
        steps.add(SendHomeStep(SendHomeStepKind.fetch, run: s['run'] == false ? false : null));
      case SendHomeStepKind.return_:
        needEscort('an escort going back to its post');
        steps.add(const SendHomeStep(SendHomeStepKind.return_));
      case SendHomeStepKind.wait:
        steps.add(SendHomeStep(SendHomeStepKind.wait, seconds: checkNum(s['seconds'], '$what.seconds', 0, 30)));
      case SendHomeStepKind.say:
        final who = s['who'] == 'escort' ? SendHomeWho.escort : SendHomeWho.worker;
        if (s['who'] != null && s['who'] != 'worker' && s['who'] != 'escort') {
          throw MapError('$what.who should be "worker" or "escort"');
        }
        if (who == SendHomeWho.escort) needEscort('its escort saying something');
        final text = s['text'];
        final lines = text is String ? [text] : (text is List ? text : null);
        if (lines == null || lines.isEmpty || lines.length > 20 || lines.any((l) => l is! String || l.trim().isEmpty)) {
          throw MapError("$what.text should be something to say, or a list of things (one's picked at random)");
        }
        steps.add(
          SendHomeStep(SendHomeStepKind.say, who: who, text: [for (final l in lines) _cut((l as String).trim(), 80)]),
        );
      case SendHomeStepKind.walk:
        final to = _place(s['to'], '$what.to');
        final spot = to.spot;
        if (spot == SendHomeSpot.stairs || spot == SendHomeSpot.dungeon || spot == SendHomeSpot.cell) {
          needDungeon('walks workers to the ${spot == SendHomeSpot.cell ? 'cells' : spot!.wire}');
        }
        if (spot == SendHomeSpot.airlock) needAirlock('walks workers to the airlock');
        if (spot == SendHomeSpot.post) needEscort('a walk to the escort’s post');
        if (spot == null) standing(to.x, to.z, to.below, '$what.to');
        steps.add(SendHomeStep(SendHomeStepKind.walk, to: to, run: s['run'] == true ? true : null));
    }
  }
  double hours(Object? v, String what, double dflt) => v == null ? dflt : checkNum(v, what, 0, 100000);
  final starve = hours(c['starveHours'], 'sendHome.starveHours', starveHours);
  final rot = hours(c['rotHours'], 'sendHome.rotHours', rotHours);
  return SendHomePlan(
    escort: escort,
    steps: steps,
    keeps: steps.any((s) => s.kind == SendHomeStepKind.jail || s.kind == SendHomeStepKind.eject),
    starveMs: math.max(1000, starve * 3600000),
    rotMs: math.max(1000, rot * 3600000),
  );
}

/// The first [max] UTF-16 units of [s], as JS `slice(0, max)` takes them.
String _cut(String s, int max) => s.length > max ? s.substring(0, max) : s;

// ---- Wasting away ------------------------------------------------------------------------------

/// How far gone someone locked up at [at] is by [now]: how thin (0–1), whether they've starved to
/// death, and how far they've rotted since (0–1).
({double thin, bool dead, double rot}) wasting(num at, num now, {required double starveMs, required double rotMs}) {
  final t = math.max(0, now - at).toDouble();
  final thin = math.min(1.0, t / starveMs);
  final dead = t >= starveMs;
  final rot = dead ? math.min(1.0, (t - starveMs) / rotMs) : 0.0;
  return (thin: thin, dead: dead, rot: rot);
}

/// Where the [k]th prisoner ever (0 the first) sits, of [total]: the latest ones fill the cells' seats
/// in turn, so everyone stays where they were thrown; the ones from before them, once every seat's
/// been taken, are only bones on the heap (null).
CellSeat? prisonSeat(DungeonPlan d, int k, int total) {
  final n = d.seats.length;
  if (n == 0 || k < total - n) return null;
  return d.seats[k % n];
}

// ---- Walking between the hall and the dungeon --------------------------------------------------

/// The way from [from] to [to], up or down the dungeon stairs if one of them is down in the dungeon
/// (`below`) and the other isn't: round the hall on [hall]'s grid, round the dungeon on [vault]'s.
List<Pt> levelRoute(DungeonPlan d, NavGrid hall, NavGrid vault, Pt from, bool fromBelow, Pt to, bool toBelow) {
  if (fromBelow == toBelow) return (fromBelow ? vault : hall).route(from, to);
  final s = d.stairs;
  if (!fromBelow) return [...hall.route(from, s.top), s.start, s.end, ...vault.route(s.foot, to)];
  return [...vault.route(from, s.foot), s.end, s.start, ...hall.route(s.top, to)];
}
