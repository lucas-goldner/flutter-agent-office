// The building's map as it's built (see office_shared's maps and world/world.dart): the office, or a map
// of its own (the castle, the station). Only one is in the scene at a time, like the office and the
// rooftop; the controller puts up the one the building's on (see OfficeController._applyMap). A port of
// core/worlds.ts.

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart' show stationAgent;
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart' show WorkerStatus, WorkerTask;

import '../world/character.dart';
import '../world/court.dart';
import '../world/fixtures.dart' show addFixtures;
import '../world/labels.dart';
import '../world/player.dart' show groundAt;
import '../world/styles.dart';
import '../world/world.dart';
import 'rooms_hub.dart' show stationInfo;

/// A board agent waiting by its board before anyone has asked it anything, and where.
typedef IdleAgent = ({Worker model, DeskView view});

/// A map's world, with its court (on a map with a line for the throne) and the board agents waiting in it.
typedef MapWorld = ({World world, Court? court, List<IdleAgent> idle});

class Worlds {
  Worlds({required this.theOffice, required this.labels, required this.parent, required this.footstep, this.mount});

  /// The office's own map, with everything that has (the elevator, the balcony, the lounge…).
  final OfficeWorld theOffice;
  final LabelHub labels;

  /// Where a map of its own's world goes (the controller's root, beside the office).
  final Node parent;
  final void Function(double x, double y, double z) footstep;

  /// Hangs the office's live faces on a world just built: its boards, its meeting board.
  final void Function(World w)? mount;

  late World _world = theOffice;
  Court? _court;
  List<IdleAgent> _idle = const [];

  /// The worlds built for maps of their own, by map id, with the plan each was built from (a custom map can change).
  final Map<String, ({MapPlan plan, MapWorld built})> _built = {};

  /// The world the building's map is built as.
  World get world => _world;

  /// On a map with a line for the throne: its workers walking between their seats and the line.
  Court? get court => _court;

  /// The board agents waiting by their boards in the world you're in (the office's are the rooms' own).
  List<IdleAgent> get idleAgents => _idle;

  /// Whether the building's on the office's own map.
  bool get inOffice => identical(_world, theOffice);

  /// Where everything is on the building's map: its seats by id, and places to sit.
  MapPlan get plan => _world.plan;

  /// The world for [p]: the office, or the one its style's builder puts up for it, the first time it's wanted.
  MapWorld worldFor(MapPlan p) {
    if (p.style == PlanStyle.office) return (world: theOffice, court: null, idle: const []);
    var b = _built[p.id];
    // A map of your own was edited since: it's built again.
    if (b != null && !identical(b.plan, p)) {
      b.built.world.group.detach();
      b.built.world.dispose();
      for (final a in b.built.idle) {
        a.model.dispose();
      }
      _built.remove(p.id);
      b = null;
    }
    if (b == null) {
      final build = worldBuilders[p.style];
      if (build == null) return (world: theOffice, court: null, idle: const []);
      final w = build(p, labels);
      // The build tower, where the map has one.
      addFixtures(w);
      w.group.visible = false;
      parent.add(w.group);
      double ground(double x, double z, double y) {
        final g = groundAt(w.colliders, x, z, y);
        final floor = streetOf(w);
        return g > floor ? g : floor;
      }

      final court = p.lineup.isEmpty ? null : Court(w.group, p, w.nav, ground, footstep);
      if (court != null) w.interactables.addAll(court.interactables);
      final built = (world: w, court: court, idle: _idleAgentsIn(w));
      mount?.call(w);
      b = (plan: p, built: built);
      _built[p.id] = b;
    }
    return b.built;
  }

  /// The building's on [next]'s map now (see the controller's _applyMap, which takes the old one down).
  void enter(MapWorld next) {
    _world = next.world;
    _court = next.court;
    _idle = next.idle;
  }

  /// The board agents waiting by their boards in [w].
  List<IdleAgent> _idleAgentsIn(World w) => [
    for (final def in w.plan.stations)
      if (w.desks[def.id] != null)
        () {
          final kind = def.station!;
          final agent = stationAgent[kind]!;
          final model = Worker(agent.name, agent.color, labels)
            ..setStatus(WorkerStatus.idle, false)
            ..setTask(WorkerTask(name: stationInfo[kind]!.offer, summary: stationInfo[kind]!.does))
            ..setOutfit(w.plan.outfit == 'peasant' ? 'peasant' : null);
          final view = w.desks[def.id]!;
          view.vacancy.children.first.add(model.root);
          return (model: model, view: view);
        }(),
  ];
}
