// A world: the building's map, built and ready to walk round (see office_shared's maps). The
// controller shows one at a time, the way it swaps the office for the rooftop, and talks to it
// through this: where the seats and the boards are, what's in the way, how workers walk in and out.
// The office has a great deal more of its own (the elevator, the balcony, the lounge…), which the
// controller only uses while the office is the world. A port of world/world.ts.
//
// Other parts of the client that differ by map (the back office, lamplight, fog, footsteps) go through
// this interface too: ask `controller.world` rather than reaching for the office.

import 'package:flutter_scene/scene.dart' show Fog, Node;
import 'package:office_shared/floors.dart';
import 'package:office_shared/layout.dart' show DeskDef, Floor, Loft, wallHeight, wallT;
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/nav.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show Person;
import 'collider.dart';
import 'confetti.dart' show ConfettiArea;
import 'office/office.dart';
import 'toon.dart' show ToonLight;

export 'office/office.dart' show DeskView, Face, Gong;

/// The ways a worker walks, on this map.
abstract interface class Ways {
  /// Out of the building from [seat], or from [from] if it's already up and about: the first point
  /// is where it gets down. `chute`: it goes over the balcony railing by parachute at the end.
  ({List<Pt> way, bool chute}) home(DeskDef seat, [Pt? from]);

  /// In to beside [seat]'s chair, from wherever workers come in (the office's elevator, the castle's doors).
  List<Pt> into(DeskDef seat);
}

/// [Ways] from two functions.
class WaysOf implements Ways {
  const WaysOf(this._home, this._in);

  final ({List<Pt> way, bool chute}) Function(DeskDef seat, Pt? from) _home;
  final List<Pt> Function(DeskDef seat) _in;

  @override
  ({List<Pt> way, bool chute}) home(DeskDef seat, [Pt? from]) => _home(seat, from);

  @override
  List<Pt> into(DeskDef seat) => _in(seat);
}

/// What the workers work on: laptops, or the castle's tomes.
enum WorldDevice { laptop, tome }

/// A room under the floor (the dungeon), up to [top], that the camera keeps inside while you're down there.
class Vault {
  const Vault(this.bounds, this.top);
  final Bounds bounds;
  final double top;
}

/// How thick a world's outside walls are, for keeping the camera on your side of them. [enclosed]:
/// walled and roofed all round, so no rain falls in it and there's no street or garage under it.
class WorldRoom {
  const WorldRoom({required this.wall, required this.enclosed, this.vault});
  final double wall;
  final bool enclosed;
  final Vault? vault;
}

/// Where the sounds are, when it isn't the office: its gong, and the windows sounds from outside come
/// in at. [vacuum]: there's nothing outside to hear (a station out in space).
class Acoustics {
  const Acoustics({this.gong, this.windows = const [], this.vacuum = false});
  final vm.Vector3? gong;
  final List<vm.Vector3> windows;
  final bool vacuum;
}

/// Where confetti rains when a pull request merges, and from how high over each spot.
typedef RainArea = ({ConfettiArea area, double Function(double x, double z) top});

/// Whoever stands by the throne and sends out new workers (the map's herald), and where to speak to them.
typedef Herald = ({Person person, Interactable interactable});

/// Who comes for a worker sent home (the map's sendHome.escort): where they keep watch, the one on
/// watch there, and how to call out another like them while that one's busy.
typedef Escort = ({Spot post, bool below, Person guard, Person Function() make});

/// What a world lights its own way (see [World.mood]): the toon light the sky has just set, the
/// scene's fog, 1 by day and 0 at night, the time, and where you're looking from.
typedef Mood = ({ToonLight light, Fog fog, double daylight, double t, vm.Vector3? eye});

/// A dungeon under the floor, where workers sent home can be locked up (see world/dungeon.dart).
abstract interface class DungeonSite {
  DungeonPlan get plan;

  /// The vault's own nav grid, for walking down there.
  NavGrid get nav;

  /// What's only worth drawing while someone might see it: whoever's locked up goes in here.
  Node get inside;

  /// Where its torches burn, for lighting it while you're down there.
  List<vm.Vector3> get lamps;

  /// Swings cell [i]'s door: 0 shut, 1 wide open.
  void swing(int i, double open);

  /// Where cell [i]'s lock is, to hear it.
  vm.Vector3 lock(int i);
}

/// An airlock in a wall, which workers sent home can be blown out of (see world/station).
abstract interface class AirlockSite {
  AirlockPlan get plan;

  /// Opens (1) or shuts (0) its inner door and its outer hatch.
  void setInner(double open);
  void setOuter(double open);
}

abstract class World {
  MapPlan get plan;
  Node get group;
  List<Collider> get colliders;
  List<Interactable> get interactables;

  /// Every seat by id: the desks, the overflow seats, the board agents' places and the meeting chairs.
  Map<String, DeskView> get desks;

  /// The boards' faces, by [BoardKey.wire].
  Map<String, Face> get boardMeshes;

  /// The meeting's output as it's written, and how the meeting's going, where the map shows them.
  Face? get meetingBoard => null;
  Face? get meetingSign => null;

  /// The gong a merged pull request rings, if the map has one.
  Gong? get gong => null;
  NavGrid get nav;
  Ways get ways;

  /// Where confetti rains when a pull request merges, and from how high over each spot.
  List<RainArea> get rain;
  WorldDevice get device;
  WorldRoom get room;

  /// Where the sounds are, when it isn't the office (null: the office's own).
  Acoustics? get acoustics => null;
  Herald? get herald => null;
  DungeonSite? get dungeon => null;
  AirlockSite? get airlock => null;
  Escort? get escort => null;

  /// Brings out the overflow seats in [out] and puts the rest away: the colliders of the ones that just came out.
  List<Collider> setBeanbags(Set<String> out);

  /// Paints it in a floor's colors, so each project looks like itself.
  void setLook(FloorPalette p);
  void setProjectName(String name);

  /// Animates it; doors open for anyone in [people] who comes up to it.
  void update(double t, double dt, Iterable<vm.Vector3> people);

  /// Lights it its own way, after the sky's had its say (the castle's torchlit hall). Null: the office's.
  void Function(Mood m)? get mood => null;

  /// Frees what it's made of: it's been taken down for good (a map of your own was edited, and is built again).
  void dispose() {}
}

/// How far down there's anything to stand on, on a map of its own: its dungeon's floor, or the hall's.
double streetOf(World w) => w.dungeon?.plan.floor ?? 0;

/// Where confetti rains from over (x, z) downstairs in the office: the ceiling, or under the loft, the underside of its floor.
double _ceilingOver(double x, double z) {
  final loft = x > Loft.minX && x < Loft.maxX && z > Loft.minZ && z < Loft.maxZ;
  return loft ? Loft.y - 0.35 : wallHeight - 0.1;
}

/// The office as a world. [upstairs] says whether this floor is above the bottom one (no exit door:
/// workers leave by the balcony), and [wing] how many rows its back office is built out.
class OfficeWorld extends World {
  OfficeWorld(this.office, this._upstairs, this._wing);

  final Office office;
  final bool Function() _upstairs;
  final int Function() _wing;

  @override
  MapPlan get plan => officePlan;
  @override
  Node get group => office.group;
  @override
  List<Collider> get colliders => office.colliders;
  @override
  List<Interactable> get interactables => office.interactables;
  @override
  Map<String, DeskView> get desks => office.desks;
  @override
  Map<String, Face> get boardMeshes => office.boardMeshes;

  /// The meeting room's, once the rooms are built (see office/rooms_hub.dart).
  Face? meetingBoardFace, meetingSignFace;
  @override
  Face? get meetingBoard => meetingBoardFace;
  @override
  Face? get meetingSign => meetingSignFace;
  @override
  Gong get gong => office.gong;
  @override
  NavGrid get nav => officeNav(_wing());
  @override
  late final Ways ways = WaysOf(
    (seat, from) =>
        _upstairs() ? (way: wayToBalcony(seat, _wing()), chute: true) : (way: wayHome(seat, _wing()), chute: false),
    (seat) => wayIn(seat, _wing()),
  );
  @override
  final List<RainArea> rain = const [
    (area: (minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ), top: _ceilingOver),
    (area: (minX: Loft.minX, maxX: Loft.maxX, minZ: Loft.minZ, maxZ: Loft.maxZ), top: _loftTop),
  ];
  static double _loftTop(double x, double z) => Loft.y + Loft.height - 0.1;
  @override
  WorldDevice get device => WorldDevice.laptop;
  @override
  WorldRoom get room => const WorldRoom(wall: wallT, enclosed: false);
  @override
  List<Collider> setBeanbags(Set<String> out) => office.setBeanbags(out);
  @override
  void setLook(FloorPalette p) => office.setLook(p);
  @override
  void setProjectName(String name) => office.setProjectName(name);
  @override
  void update(double t, double dt, Iterable<vm.Vector3> people) => office.update(t, dt, people);
}
