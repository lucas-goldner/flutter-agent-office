// The office: floor, walls, windows and doors, desks, bean bags, the wall boards, the lounge, the
// kitchen, the loft, the elevator, the gong, the whiteboard, and outside the balcony, the garage and
// the street (a port of office.ts). What you bump into is office_colliders.dart.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/decor.dart' show WallId, WallRect, wallFacing;
import 'package:office_shared/floors.dart';
import 'package:office_shared/layout.dart' as lay;
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;

import '../collider.dart';
import '../labels.dart';
import '../text.dart';
import '../toon.dart';
import 'elevator.dart';
import 'geo.dart';
import 'gong.dart';
import 'jukebox.dart';
import 'loft.dart';
import 'office_colliders.dart';
import 'outside.dart';
import 'parts.dart';
import 'shell.dart';
import 'stack.dart';
import 'tower.dart';
import 'whiteboard.dart';

export 'elevator.dart' show Elevator;
export 'gong.dart' show Gong;
export 'jukebox.dart' show JukeboxView;
export 'loft.dart' show Face;
export 'outside.dart' show Halo, Lamp, NightBulb, NightParts;
export 'stack.dart' show FloorStack, StackState;
export 'whiteboard.dart' show WhiteboardStand;

/// A desk or a bean bag: somewhere a worker sits.
class DeskView {
  DeskView({
    required this.def,
    required this.group,
    required this.laptopAnchor,
    required this.seatAnchor,
    required this.chair,
    required this.vacancy,
    required this.vacancyY,
    Node? stage,
  }) : stage = stage ?? Node(name: 'stage');

  /// Where the worker gets up to dance when a pull request merges: its feet, and the way it faces.
  final Node stage;

  final DeskDef def;
  final Node group;

  /// The laptop goes in here: placed, turned and sized for this seat.
  final Node laptopAnchor;

  /// The worker goes in here, the same way.
  final Node seatAnchor;
  final Node chair;
  final Node vacancy;

  /// How high the vacancy marker floats.
  final double vacancyY;
}

class Office {
  Office._(
    this._fixtures,
    this._looks,
    this._doors,
    this._beanbags, {
    required this.group,
    required this.colliders,
    required this.interactables,
    required this.desks,
    required this.boardMeshes,
    required this.tvScreen,
    required this.bossScreen,
    required this.elevator,
    required this.gong,
    required this.jukebox,
    required this.whiteboard,
    required this.night,
    required this.stack,
    required this._level,
  });

  final _Level _level;

  /// You're on floor [index] of a building [count] floors tall (0 is the bottom one): the rest of the
  /// building goes up over you and down under you, the street that many storeys down, and only the
  /// bottom floor has its exit door.
  void setLevel(int index, int count) {
    final l = _level;
    final drop = index * storey;
    l.ground.position = vm.Vector3(0, -drop, 0);
    for (final (c, top, bottom) in l.base) {
      // Walls up into the sky stay that way.
      if (top <= 50) c.top = top - drop;
      c.bottom = bottom - drop;
    }
    night.street = streetBelow(index);
    l.exit.y = -drop;
    l.exit.locked = index > 0;
    l.plug.group.visible = index > 0;
    final has = colliders.contains(l.plug.collider);
    if (index > 0 && !has) colliders.add(l.plug.collider);
    if (index == 0 && has) colliders.remove(l.plug.collider);
    l.tower.set(index, count);
  }

  final Node group;
  final List<Collider> colliders;
  final List<Interactable> interactables;

  /// Every seat by id: the desks and the bean bags.
  final Map<String, DeskView> desks;

  /// The four wall boards' faces, by the kind of board: 'issues', 'pulls', 'services', 'queue'.
  final Map<String, Face> boardMeshes;
  final Face tvScreen;

  /// The monitor on the boss's desk upstairs, where DEADFALL plays (ui/arcade.ts).
  final Face bossScreen;
  final Elevator elevator;

  /// The merge gong by the PR board.
  final Gong gong;
  final JukeboxView jukebox;

  /// The rolling whiteboard everyone draws on together.
  final WhiteboardStand whiteboard;

  /// Lights, windows and glass for the sky to change with the time of day and the weather.
  final NightParts night;

  /// The ceiling, the floor, and the ladder and fire pole between the floors of the building.
  final FloorStack stack;

  /// The potted plants' leaves (their pots are merged with the decor): hidden while holiday.dart
  /// turns the plants into Christmas trees.
  late final Node plantLeaves;

  final List<WallRect> _fixtures;
  final Looks _looks;
  final List<Door> _doors;
  final Map<String, _Beanbag> _beanbags;

  /// What's already on the walls (boards, the TV, windows…), so pictures don't hang over it.
  List<WallRect> fixtures() => _fixtures;

  /// Brings out the bean bags in [out] and puts the rest away. Returns the colliders of the ones
  /// that just came out, in case someone is standing there.
  List<Collider> setBeanbags(Set<String> out) {
    final appeared = <Collider>[];
    for (final e in _beanbags.entries) {
      final b = e.value;
      final show = out.contains(e.key);
      if (show == b.view.group.visible) continue;
      b.view.group.visible = show;
      b.it.off = !show;
      if (show) {
        colliders.add(b.collider);
        appeared.add(b.collider);
      } else {
        colliders.remove(b.collider);
      }
    }
    return appeared;
  }

  /// The sign over the elevator doors: which floor you're on.
  void setProjectName(String name) => elevator.setSign('🛗 $name');

  /// Paints the walls, their trim and the floor in a floor's colours, so each project looks like itself.
  void setLook(FloorPalette p) {
    setToonColor(_looks.wall, hex(p.wall));
    setToonColor(_looks.trim, hex(p.trim));
    _looks.paintPlanks(p);
  }

  /// Animates the office; doors open for anyone in [people] who comes up to them.
  void update(double t, double dt, Iterable<vm.Vector3> people) {
    final near = <Door>{};
    for (final p in people) {
      for (final d in _doors) {
        if ((p.y - d.y).abs() < 1.6 && math.sqrt(math.pow(p.x - d.x, 2) + math.pow(p.z - d.z, 2)) < 2.4) near.add(d);
      }
    }
    for (final d in _doors) {
      final want = near.contains(d) && !d.locked ? 1.0 : 0.0;
      if (d.open == want) continue;
      d.open = want > d.open ? math.min(1, d.open + dt * 2.5) : math.max(0, d.open - dt * 1.6);
      d.show(d.open);
    }
    for (final d in desks.values) {
      if (!d.vacancy.visible || !d.group.visible) continue;
      d.vacancy.position = vm.Vector3(0, d.vacancyY + math.sin(t * 2 + d.def.x) * 0.06, 0);
      d.vacancy.rotation = yaw(t * 1.2);
    }
    elevator.update(dt);
    gong.update(dt);
  }
}

/// What moves when you change floors (see Office.setLevel).
class _Level {
  _Level(this.ground, this.base, this.exit, this.plug, this.tower);

  final Node ground;

  /// The ground's colliders, and where their tops and bottoms are from the bottom floor.
  final List<(Collider, double, double)> base;
  final Door exit;
  final ({Node group, Collider collider}) plug;
  final Tower tower;
}

class _Beanbag {
  _Beanbag(this.view, this.it, this.collider);

  final DeskView view;
  final Interactable it;
  final Collider collider;
}

DeskView _buildDesk(DeskDef def, int index, Material trimMat) {
  final group = Node(name: def.id);
  group.position = vm.Vector3(def.x, 0, def.z);
  group.rotation = yaw(def.rotY);
  const width = DeskSize.width, depth = DeskSize.depth, height = DeskSize.height;
  // The desk itself never moves: one mesh per material.
  final body = Node(name: 'desk');
  body.add(mesh(roundedBox(width - 0.06, 0.08, depth - 0.04, 0.08), tc(Palette.desk), 0, height - 0.04, 0));
  final legMat = tc('#8d99ae');
  for (final sx in [-1, 1]) {
    for (final sz in [-1, 1]) {
      body.add(
        mesh(
          cyl(0.035, 0.035, height - 0.08, 8),
          legMat,
          sx * (width / 2 - 0.14),
          (height - 0.08) / 2,
          sz * (depth / 2 - 0.12),
        ),
      );
    }
  }
  // Modesty panel facing away from the worker.
  body.add(mesh(box(width - 0.3, 0.32, 0.03), trimMat, 0, height - 0.26, -depth / 2 + 0.06));
  // Little desk decorations.
  switch (index % 3) {
    case 0:
      body.add(mesh(cyl(0.06, 0.05, 0.12, 10), tc(Palette.chairs[index % 6]), width / 2 - 0.25, height + 0.06, -0.2));
    case 1:
      body.add(place(plant(0.35), x: -width / 2 + 0.25, y: height, z: -0.25, scale: 0.35));
    default:
      final books = Node(name: 'books');
      const colors = ['#e63946', '#457b9d', '#f4a261'];
      for (var i = 0; i < 3; i++) {
        books.add(mesh(box(0.08, 0.24, 0.18), tc(colors[i]), i * 0.09, 0.12, 0));
      }
      body.add(place(books, x: width / 2 - 0.35, y: height, z: -0.3));
  }
  group.add(mergeByMaterial(body));

  final laptopAnchor = place(Node(name: 'laptop-anchor'), y: height, z: -0.06, scale: 1.3);
  group.add(laptopAnchor);
  // On the chair, facing the desk.
  final seatAnchor = place(Node(name: 'seat-anchor'), y: 0.4, z: 0.93, rot: yaw(math.pi), scale: 0.82);
  group.add(seatAnchor);

  // Up on the desk beside the laptop, clear of the mug or books at the back, facing the chair.
  final stage = place(Node(name: 'stage'), x: 0.72, y: height - 0.07, z: 0.18);
  group.add(stage);

  final ch = place(chair(Palette.chairs[index % Palette.chairs.length]), z: 0.9);
  group.add(ch);

  const vacancyY = height + 0.55;
  final vacancy = vacancyMarker(vacancyY);
  group.add(vacancy);
  return DeskView(
    def: def,
    group: group,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    chair: ch,
    vacancy: vacancy,
    vacancyY: vacancyY,
    stage: stage,
  );
}

const _beanbagColors = ['#ff6b6b', '#4ecdc4', '#9b5de5', '#ffd166', '#f15bb5', '#00bbf9', '#06d6a0', '#fb8500'];

/// An overflow seat: a squashy bean bag, and a low lap desk in front of it for the laptop.
DeskView _buildBeanbag(DeskDef def, int index) {
  final group = Node(name: def.id);
  group.position = vm.Vector3(def.x, 0, def.z);
  group.rotation = yaw(def.rotY);
  final bag = Node(name: 'bag');
  final cloth = tc(_beanbagColors[index % _beanbagColors.length]);
  bag.add(place(mesh(sphere(0.62, 20, 14), cloth), y: 0.3, scale3: vm.Vector3(1, 0.52, 1)));
  // Slumped up behind the worker, like a back rest.
  bag.add(place(mesh(sphere(0.5, 18, 12), cloth), y: 0.6, z: 0.32, scale3: vm.Vector3(1.05, 0.95, 0.7)));
  final chairNode = mergeByMaterial(bag);
  group.add(chairNode);

  final tray = Node(name: 'lap-desk');
  tray.add(mesh(roundedBox(0.95, 0.05, 0.6, 0.05), tc(Palette.wood), 0, 0.42, 0));
  for (final sx in [-1, 1]) {
    tray.add(mesh(box(0.05, 0.4, 0.5), tc('#8a5a3b'), sx * 0.4, 0.2, 0));
  }
  group.add(place(mergeByMaterial(tray), z: -0.8));

  final laptopAnchor = place(Node(name: 'laptop-anchor'), y: 0.445, z: -0.8, scale: 1.05);
  group.add(laptopAnchor);
  // Sunk into the bag, facing the lap desk.
  final seatAnchor = place(Node(name: 'seat-anchor'), y: 0.32, z: 0.04, rot: yaw(math.pi), scale: 0.82);
  group.add(seatAnchor);

  // Standing up on the bag, sunk in a little.
  final stage = place(
    Node(name: 'stage'),
    y: BeanbagBox.top - 0.1,
    z: -0.05,
    rot: yaw(math.pi),
  );
  group.add(stage);

  const vacancyY = 1.25;
  final vacancy = vacancyMarker(vacancyY);
  group.add(vacancy);
  return DeskView(
    def: def,
    group: group,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    chair: chairNode,
    vacancy: vacancy,
    vacancyY: vacancyY,
    stage: stage,
  );
}

/// A framed board on a wall; the face shows the board later (cork, chalk or whiteboard).
({Node group, Face face}) _wallBoard(double width, double height, String frameColor, String faceColor) {
  final g = Node(name: 'board');
  g.add(place(mesh(roundedBox(width + 0.3, 0.12, height + 0.3, 0.1), tc(frameColor)), rot: euler(math.pi / 2)));
  final mat = flat(faceColor);
  final face = mesh(planeXY(width, height), mat, 0, 0, 0.07, false);
  g.add(face);
  return (group: g, face: Face(face, mat, width, height));
}

Office buildOffice({required LabelHub labels}) {
  final group = Node(name: 'office');
  final interactables = <Interactable>[];
  final fixtures = <WallRect>[];
  void fixture(WallId wall, double u, double y, double w, double h) =>
      fixtures.add(WallRect(wall: wall, u0: u - w / 2, u1: u + w / 2, y0: y - h / 2, y1: y + h / 2));

  // What each floor paints its own way (see setLook): the walls, their trim, the planks.
  final looks = Looks();

  // Floor, and the ceiling, with the ways up and down to the other floors through them (see stack.dart).
  final planks = Toon.create(hex('#ffffff'));
  looks.planks.add(planks);
  // The stack's colliders come and go with the floors; the rest go in ahead of them at the end.
  final colliders = <Collider>[];
  final stack = buildStack(colliders, planks);
  group.add(stack.group);
  interactables.addAll(stack.interactables);
  // The ladder and its signs, up the west wall.
  fixture(Side.west, Ladder.z + 0.6, wallHeight / 2, Ladder.width + 2.4, wallHeight);

  // What never moves and needs no clicking: rugs, plants, lamps, the coffee table, the kitchen
  // counter… merged into a few meshes at the end.
  final decor = Node(name: 'decor');

  // Rugs under each desk cluster.
  const rugs = [(-10.5, -4.0), (-1.5, -4.0), (-10.5, 4.0), (-1.5, 4.0)];
  for (var i = 0; i < rugs.length; i++) {
    decor.add(mesh(roundedBox(6.2, 0.02, 4.6, 0.6), tc(Palette.rugs[i]), rugs[i].$1, 0.011, rugs[i].$2, false));
  }

  final night = NightParts();

  // Outside walls, with real windows you see out of and a door out.
  buildWalls(group, looks);
  final glazing = Node(name: 'glazing');
  for (final o in windows) {
    glazing.add(windowIn(o));
    fixture(o.wall, o.u, (o.y0 + o.y1) / 2 - 0.03, o.width + 0.2, o.y1 - o.y0 + 0.12);
    final wet = wetPane(o, night.wetGlass);
    night.wetPanes.add(wet);
    group.add(wet);
  }
  group.add(mergeByMaterial(glazing));
  final doors = <Door>[];
  // Down to the street, which is the bottom floor's: its exit door and the steps down from it, the
  // posts under its balcony, the garage under it and the street out front. On a floor above it, all
  // of it is that many storeys further down (see setLevel).
  final ground = Node(name: 'ground');
  final exit = buildExitDoor(night);
  ground.add(exit.group);
  doors.add(exit.door);
  final stairs = Node(name: 'exit-stairs');
  buildExitStairs(stairs);
  buildBalconyPosts(stairs);
  ground.add(mergeByMaterial(stairs));
  // The door, its frame and the EXIT sign over it.
  fixture(exitDoor.wall, exitDoor.u, (exitDoor.y1 + 0.7) / 2, exitDoor.width + 0.3, exitDoor.y1 + 0.7);
  // Out the glass doors on the south wall: the balcony.
  final slider = buildBalconyDoor();
  group.add(slider.group);
  doors.add(slider.door);
  fixture(balconyDoor.wall, balconyDoor.u, (balconyDoor.y1 + 0.1) / 2, balconyDoor.width + 0.2, balconyDoor.y1 + 0.1);
  buildBalcony(group, interactables, night);

  buildGarage(ground);
  // The clouds stay up in the sky, however far down the street is.
  buildStreet(ground, night, group);
  group.add(ground);
  final groundCs = groundColliders();
  // Upstairs there's no way out on the west side: the doorway is wall like the rest of it.
  final plug = exitPlug(looks);
  group.add(plug.group);
  // The rest of the building, above and below this floor.
  final tower = buildTower(colliders, night);
  group.add(tower.group);

  // Desks.
  final desks = <String, DeskView>{};
  for (var i = 0; i < lay.desks.length; i++) {
    final def = lay.desks[i];
    final view = _buildDesk(def, i, looks.trim);
    group.add(view.group);
    desks[def.id] = view;
    final seat = deskSeat(def, 1.25);
    final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: seat.x, z: seat.z, radius: 1.3);
    interactables.add(it);
    tagInteract(view.group, it);
  }

  // Bean bags, put away until every desk is taken.
  final beanbags = <String, _Beanbag>{};
  for (var i = 0; i < lay.beanbags.length; i++) {
    final def = lay.beanbags[i];
    final view = _buildBeanbag(def, i);
    view.group.visible = false;
    group.add(view.group);
    desks[def.id] = view;
    final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: def.x, z: def.z, radius: 1.8, off: true);
    interactables.add(it);
    tagInteract(view.group, it);
    beanbags[def.id] = _Beanbag(view, it, beanbagCollider(def));
  }

  // Boards on the walls.
  final boardMeshes = <String, Face>{};
  const boards = [
    ('issues', InteractKind.issues, Boards.issues, Palette.cork),
    ('pulls', InteractKind.pulls, Boards.pulls, Palette.cork),
    ('services', InteractKind.services, Boards.services, '#23303b'),
    ('queue', InteractKind.queue, Boards.queue, '#ffffff'),
  ];
  for (final (key, kind, b, faceColor) in boards) {
    // Out from the wall, the way the board faces.
    final nx = math.sin(b.rotY);
    final nz = math.cos(b.rotY);
    // The queue is a whiteboard in an aluminium frame; the others hang in wood.
    final board = _wallBoard(b.width, b.height, key == 'queue' ? '#aab4be' : Palette.wood, faceColor);
    group.add(place(board.group, x: b.x + nx * 0.08, y: b.y, z: b.z + nz * 0.08, rot: yaw(b.rotY)));
    boardMeshes[key] = board.face;
    final label = textPlane(b.label, const TextOpts(bg: '#fffaf3', size: 64));
    group.add(
      place(label, x: b.x + nx * 0.04, y: b.y + b.height / 2 + 0.5, z: b.z + nz * 0.04, rot: yaw(b.rotY), scale: 1.3),
    );
    final it = Interactable(kind: kind, x: b.x + nx * 1.6, z: b.z + nz * 1.6, radius: 2.4);
    interactables.add(it);
    tagInteract(board.group, it);
    // The board and its label above it, up to the ceiling.
    final wall = wallFacing(b.rotY);
    final bottom = b.y - (b.height + 0.3) / 2;
    fixture(
      wall,
      wall == Side.north || wall == Side.south ? b.x : b.z,
      (bottom + wallHeight) / 2,
      b.width + 0.3,
      wallHeight - bottom,
    );
  }

  // Lounge: TV, couch, coffee table, beanbags, and the jukebox in the corner.
  final tvGroup = Node(name: 'tv');
  tvGroup.add(
    place(mesh(roundedBox(Tv.width + 0.3, 0.14, Tv.height + 0.3, 0.12), tc(Palette.ink)), rot: euler(math.pi / 2)),
  );
  final tvMat = flat('#1b1d2e');
  final tvNode = mesh(planeXY(Tv.width, Tv.height), tvMat, 0, 0, 0.08, false);
  tvGroup.add(tvNode);
  group.add(place(tvGroup, x: Tv.x - 0.1, y: Tv.y, z: Tv.z, rot: yaw(-math.pi / 2)));
  final tv = Interactable(kind: InteractKind.tv, x: Tv.x - 4.5, z: Tv.z, radius: 3.2);
  interactables.add(tv);
  tagInteract(tvGroup, tv);
  fixture(Side.east, Tv.z, Tv.y, Tv.width + 0.3, Tv.height + 0.3);

  final couch = Node(name: 'couch');
  final couchMat = tc('#5b8def');
  couch.add(mesh(roundedBox(1, 0.45, 4.2, 0.2), couchMat, 0, 0.3, 0));
  couch.add(mesh(roundedBox(0.35, 0.9, 4.2, 0.15), couchMat, -0.45, 0.55, 0));
  couch.add(mesh(roundedBox(1, 0.7, 0.35, 0.15), couchMat, 0, 0.45, -2.0));
  couch.add(mesh(roundedBox(1, 0.7, 0.35, 0.15), couchMat, 0, 0.45, 2.0));
  couch.add(mesh(roundedBox(0.2, 0.45, 0.5, 0.1), tc('#ffd166'), -0.2, 0.75, -0.9));
  couch.add(mesh(roundedBox(0.2, 0.45, 0.5, 0.1), tc('#ef476f'), -0.2, 0.75, 0.9));
  final sofa = place(mergeByMaterial(couch), x: 10.5);
  group.add(sofa);
  seatable(sofa, 'couch', 2.6, interactables);

  final table = Node(name: 'coffee-table');
  table.add(mesh(cyl(0.9, 0.9, 0.08, 24), tc(Palette.wood), 0, 0.42, 0));
  table.add(mesh(cyl(0.12, 0.2, 0.4, 12), tc(Palette.deskLeg), 0, 0.2, 0));
  table.position = vm.Vector3(13, 0, 0);
  decor.add(table);
  decor.add(mesh(roundedBox(7, 0.02, 7, 1.2), tc('#ffc6ff'), 13.4, 0.011, 0, false));

  for (var i = 0; i < loungeBeanbags.length; i++) {
    final (c, x, z) = loungeBeanbags[i];
    final bean = place(mesh(sphere(0.6, 16, 12), tc(c)), x: x, y: 0.35, z: z, scale3: vm.Vector3(1, 0.6, 1));
    group.add(bean);
    seatable(bean, 'lounge-beanbag-${i + 1}', 1.4, interactables);
  }
  final jukebox = buildJukebox(labels: labels);
  group.add(jukebox.group);
  interactables.add(jukebox.interactable);
  fixture(Side.east, lay.Jukebox.z, lay.Jukebox.height / 2, lay.Jukebox.width + 0.1, lay.Jukebox.height);

  // Kitchen corner: counter, coffee machine and fridge.
  final kitchen = Node(name: 'kitchen');
  kitchen.add(mesh(box(5, 0.95, 1), tc('#8ecae6'), 0, 0.475, 0));
  kitchen.add(mesh(box(5.1, 0.08, 1.1), tc(Palette.desk), 0, 0.99, 0));
  final machine = Node(name: 'coffee');
  machine.add(mesh(roundedBox(0.6, 0.7, 0.5, 0.08), tc('#343a40'), 0, 0.35, 0));
  machine.add(mesh(cyl(0.08, 0.07, 0.14, 10), tc('#ffffff'), 0, 0.1, 0.12));
  machine.add(mesh(sphere(0.05, 8, 8), tc('#ef476f', emissive: '#ef476f'), 0.18, 0.55, 0.26));
  // Clickable, so a node of its own (at -1.2 along the counter, as the TS places it in the kitchen).
  final coffee = place(mergeByMaterial(machine), x: -14.5 - 1.2, y: 1.03, z: 12.2);
  group.add(coffee);
  kitchen.add(mesh(roundedBox(1.1, 2.2, 1, 0.1), tc('#f8f9fa'), 3.2, 1.1, 0));
  kitchen.add(mesh(box(0.06, 0.5, 0.06), tc('#adb5bd'), 2.75, 1.4, 0.52));
  decor.add(place(kitchen, x: -14.5, z: 12.2));
  final cup = Interactable(kind: InteractKind.coffee, x: -15.7, z: 10.9, radius: 1.4);
  interactables.add(cup);
  tagInteract(coffee, cup);
  // Counter, coffee machine and fridge, in front of the south wall.
  fixture(Side.south, -14.5, 0.55, 5.1, 1.1);
  fixture(Side.south, -15.7, 0.9, 0.6, 1.8);
  fixture(Side.south, -11.3, 1.1, 1.1, 2.2);

  // Plants around the room: the pots with the decor, the leaves on their own, so holiday.dart can
  // trim them into Christmas trees.
  final leaves = Node(name: 'plant-leaves');
  for (final (x, z, s) in roomPlants) {
    final pot = place(plant(s), x: x, z: z, scale: s);
    final leaf = place(plant(s), x: x, z: z, scale: s);
    for (final c in pot.children.skip(1).toList()) {
      c.detach();
    }
    leaf.children.first.detach();
    decor.add(pot);
    leaves.add(leaf);
  }
  final plantLeaves = mergeByMaterial(leaves);
  group.add(plantLeaves);

  // Ceiling lamps (cartoon pendants), hung on long cords down from the high ceiling.
  const lampY = 4.05;
  for (final (x, z) in const [(-10.5, -4.0), (-1.5, -4.0), (-10.5, 4.0), (-1.5, 4.0), (13.0, 0.0)]) {
    decor.add(place(pendant(wallHeight - lampY), x: x, y: lampY, z: z, scale: 0.8));
    night.halos.add(Halo(at: vm.Vector3(x, lampY - 0.12, z), size: 1.3, color: '#ffe08a'));
  }

  final bossScreen = buildLoft(group, interactables, looks);

  // The elevator to the other floors, against the north wall between the PR board and the queue.
  final elevator = buildElevator();
  group.add(elevator.group);
  interactables.add(elevator.interactable);
  fixture(Side.north, lay.Elevator.x, wallHeight / 2, lay.Elevator.width + 0.1, wallHeight);

  // The gong, between the PR board and the elevator.
  final gong = buildGong();
  group.add(gong.group);
  interactables.add(gong.interactable);
  fixture(Side.north, lay.Gong.x, (lay.Gong.height + 0.3) / 2, lay.Gong.width + 1.2, lay.Gong.height + 0.3);

  // The whiteboard, out on the floor between the desks and the lounge.
  final whiteboard = buildWhiteboard();
  group.add(whiteboard.group);
  interactables.add(whiteboard.interactable);
  // Pictures stay clear of the stairs (step by step, so they can hang above them) and of what's on
  // the loft's walls upstairs, as buildLoft places it: the couch and the sign.
  const run = (Stairs.toX - Stairs.fromX) / Stairs.steps;
  const rise = Loft.y / Stairs.steps;
  for (var i = 1; i <= Stairs.steps; i++) {
    fixture(Side.south, Stairs.fromX + (i - 0.5) * run, i * rise / 2, run, i * rise);
  }
  fixture(Side.east, LoftPlan.cz, Loft.y + 0.5, 2.4, 1);
  fixture(Side.south, Loft.maxX - 3, Loft.y + 1.9, 2.6, 0.6);

  group.add(mergeByMaterial(decor));
  looks.paintPlanks(floorPalettes[0]);
  return Office._(
      fixtures,
      looks,
      doors,
      beanbags,
      group: group,
      colliders: colliders..insertAll(0, officeColliders(elevator: elevator.colliders, ground: groundCs)),
      interactables: interactables,
      desks: desks,
      boardMeshes: boardMeshes,
      tvScreen: Face(tvNode, tvMat, Tv.width, Tv.height),
      bossScreen: bossScreen,
      elevator: elevator,
      gong: gong,
      jukebox: jukebox,
      whiteboard: whiteboard,
      night: night,
      stack: stack,
      level: _Level(ground, [for (final c in groundCs) (c, c.top, c.bottom ?? 0)], exit.door, plug, tower),
    )
    ..plantLeaves = plantLeaves
    ..setLevel(0, 1);
}
