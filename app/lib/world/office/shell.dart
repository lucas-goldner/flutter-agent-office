// The building's shell: the outside walls with their windows and doors, the exit door and the
// stairs down to the street, and the smoking balcony (from office.ts). Colliders for all of it are
// in office_colliders.dart.

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/floors.dart';
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'outside.dart';
import 'parts.dart';

/// A door that opens by itself when someone comes up to it, and closes behind them.
class Door {
  Door(this.x, this.y, this.z, this.show);

  final double x;
  final double y;
  final double z;

  /// 0 shut, 1 wide open.
  double open = 0;
  final void Function(double open) show;
}

/// The materials a floor paints in its own colours (see Office.setLook): the walls, their trim, the planks.
class Looks {
  Looks() : wall = toonUnique(hex(Palette.wall)), trim = toonUnique(hex(Palette.wallTrim));

  final PreprocessedMaterial wall;
  final PreprocessedMaterial trim;
  final List<PreprocessedMaterial> planks = [];

  /// Repaints the planks in [p] and hands them to every planked floor.
  void paintPlanks(FloorPalette p) {
    planksTexture(p).then((t) {
      for (final m in planks) {
        setToonTexture(m, t);
      }
    });
  }
}

/// Chunky planks in a floor's colours, 512 pixels square.
Future<Texture2D> planksTexture(FloorPalette p) => canvasTexture(512, 512, (g) {
  g.drawRect(const Rect.fromLTWH(0, 0, 512, 512), fill(linColor(p.floor)));
  for (var row = 0; row < 8; row++) {
    final offset = (row % 2) * 128.0;
    for (var col = -1; col < 3; col++) {
      final x = col * 256 + offset;
      g.drawRect(Rect.fromLTWH(x + 2, row * 64 + 2, 252, 60), fill(linColor((row + col) % 3 == 0 ? p.floorAlt : p.floor)));
    }
    g.drawRect(Rect.fromLTWH(0, row * 64.0, 512, 3), fill(linColor(p.seam)));
  }
});

/// A planked floor w x d, the planks repeating every 6 m, facing up (floorTexture() in office.ts).
Node plankedFloor(double w, double d, {String color = '#ffffff', Looks? looks}) {
  final mat = Toon.create(hex(color));
  if (looks != null) {
    looks.planks.add(mat);
  } else {
    planksTexture(floorPalettes[0]).then((t) => setToonTexture(mat, t));
  }
  return mesh(groundPlane(w, d, w / 6, d / 6), mat, 0, 0, 0, false);
}

/// The middle of an outside wall at [u] along it, and the turn that makes local +z point outdoors.
({double x, double z, double rotY}) onWall(Side side, double u) => switch (side) {
  Side.north => (x: u, z: Floor.minZ - wallT / 2, rotY: math.pi),
  Side.south => (x: u, z: Floor.maxZ + wallT / 2, rotY: 0.0),
  Side.west => (x: Floor.minX - wallT / 2, z: u, rotY: -math.pi / 2),
  Side.east => (x: Floor.maxX + wallT / 2, z: u, rotY: math.pi / 2),
};

/// Stands a wall-built group (along x, outdoors toward +z) in its wall.
Node mount(Node g, Opening o) {
  final at = onWall(o.wall, o.u);
  return place(g, x: at.x, z: at.z, rot: yaw(at.rotY));
}

/// A window filling its hole in an outside wall: a frame lining the hole, a mullion, sills and real glass.
Node windowIn(Opening o) {
  final g = Node(name: 'window');
  final frame = tc('#ffffff');
  final w = o.width;
  final h = o.y1 - o.y0;
  const f = 0.09;
  const d = wallT + 0.04;
  // Built along x with the outside toward +z, then turned onto its wall.
  g.add(mesh(box(w, f, d), frame, 0, o.y1 - f / 2, 0, false));
  g.add(mesh(box(w, f, d), frame, 0, o.y0 + f / 2, 0, false));
  for (final sx in [-1, 1]) {
    g.add(mesh(box(f, h, d), frame, sx * (w / 2 - f / 2), (o.y0 + o.y1) / 2, 0, false));
  }
  g.add(mesh(box(f * 0.8, h - 2 * f, 0.08), frame, 0, (o.y0 + o.y1) / 2, 0, false));
  g.add(place(glassPane(w - 2 * f, h - 2 * f), y: (o.y0 + o.y1) / 2));
  g.add(mesh(box(w + 0.2, 0.06, 0.2), frame, 0, o.y0 - 0.03, -(wallT / 2 + 0.08)));
  g.add(mesh(box(w + 0.2, 0.06, 0.16), frame, 0, o.y0 - 0.03, wallT / 2 + 0.06));
  return mount(g, o);
}

/// Rain on the outside of a window's glass (see sky.ts), kept out of the merged glazing so it keeps
/// its UVs. Hidden until the sky shows it.
Node wetPane(Opening o, Material mat) {
  const f = 0.09;
  final w = o.width - 2 * f;
  final h = o.y1 - o.y0 - 2 * f;
  // The drops are the same size on every window, whatever its size (three's v runs up; ours down).
  final u1 = w / 0.9, vOff = o.u * 0.37;
  final geo = planeXYuv(w, h, 0, -(h / 0.9 + vOff), u1, -vOff);
  final g = Node(name: 'wet');
  g.add(mesh(geo, mat, 0, (o.y0 + o.y1) / 2, 0.05, false));
  g.visible = false;
  return mount(g, o);
}

/// A door's frame and threshold, lining its hole in the wall (built like windowIn: along x, outdoors toward +z).
Node doorFrame(Opening o) {
  final g = Node(name: 'door');
  final frame = tc('#ffffff');
  const f = 0.08;
  const d = wallT + 0.04;
  g.add(mesh(box(o.width, f, d), frame, 0, o.y1 - f / 2, 0, false));
  for (final sx in [-1, 1]) {
    g.add(mesh(box(f, o.y1, d), frame, sx * (o.width / 2 - f / 2), o.y1 / 2, 0, false));
  }
  g.add(mesh(box(o.width, 0.03, d), tc('#8d99ae'), 0, 0.015, 0, false));
  return g;
}

/// The way out: a teal door with a porthole in the west wall. It swings outward, onto the landing.
({Node group, Door door}) buildExitDoor(NightParts night) {
  const o = exitDoor;
  final g = doorFrame(o);
  const f = 0.08;
  final leafW = o.width - 2 * f - 0.02;
  final leafH = o.y1 - f - 0.02;
  final portX = leafW / 2, portY = leafH - 0.55;
  const portR = 0.2;
  final shape = Shape2(16)
    ..moveTo(0, 0)
    ..lineTo(leafW, 0)
    ..lineTo(leafW, leafH)
    ..lineTo(0, leafH)
    ..addHoleArc(portX, portY, portR, 0, math.pi * 2, true);
  final leafGeo = transformed(extrudeShape(shape, 0.06), vm.Matrix4.translationValues(0, 0, -0.03));
  final leaf = Node(name: 'leaf');
  leaf.add(mesh(leafGeo, tc('#2a9d8f'), 0, 0.01, 0));
  leaf.add(mesh(circleXY(portR, 20, true), glassMat, portX, portY + 0.01, 0, false));
  leaf.add(mesh(torusXY(portR, 0.035, 8, 24), tc('#ffffff'), portX, portY + 0.01, 0, false));
  // A push bar inside, a pull handle outside.
  leaf.add(mesh(box(leafW * 0.7, 0.05, 0.05), tc('#adb5bd'), leafW * 0.5, 1.0, -0.07));
  leaf.add(mesh(box(0.05, 0.3, 0.05), tc('#adb5bd'), leafW - 0.15, 1.0, 0.07));
  // Hinged on the outer face, so it opens out of the building.
  final hinge = Node(name: 'hinge')..position = vm.Vector3(-o.width / 2 + f + 0.01, 0, wallT / 2 - 0.05);
  hinge.add(leaf);
  g.add(hinge);

  final exit = textPlane('EXIT', const TextOpts(bg: '#2a9d4b', color: '#ffffff', size: 64, border: '#ffffff'));
  g.add(place(exit, y: o.y1 + 0.35, z: -(wallT / 2 + 0.03), rot: yaw(math.pi), scale: 0.7));
  // A lamp over it outside.
  g.add(mesh(box(0.32, 0.1, 0.18), tc(Palette.ink), 0, o.y1 + 0.42, wallT / 2 + 0.09));
  g.add(mesh(sphere(0.08, 10, 8), tc('#fff7d6', emissive: '#ffe08a'), 0, o.y1 + 0.33, wallT / 2 + 0.12, false));

  final at = onWall(o.wall, o.u);
  // Over the landing, where it lights the way down at night.
  final lampAt = vm.Vector3(at.x - wallT / 2 - 0.14, o.y1 + 0.33, at.z);
  night.halos.add(Halo(at: lampAt, size: 0.9, color: '#ffe08a'));
  night.lamps.add(Lamp(x: lampAt.x - 0.6, y: lampAt.y, z: lampAt.z, reach: 5, color: '#ffe3a3', power: 2.2));
  final door = Door(at.x, 0, at.z, (k) => hinge.rotation = yaw(-1.8 * k * k * (3 - 2 * k)));
  return (group: mount(g, o), door: door);
}

/// Glass doors out to the balcony that slide apart, into the wall on either side, when someone comes up.
({Node group, Door door}) buildBalconyDoor() {
  const o = balconyDoor;
  final g = doorFrame(o);
  const f = 0.08;
  final half = (o.width - 2 * f) / 2;
  final h = o.y1 - f;
  final alu = tc('#aab4be');
  final panels = <(Node, double)>[];
  for (final side in [-1, 1]) {
    final p = Node(name: 'panel');
    final pw = half + 0.02;
    for (final y in [0.04, h - 0.04]) {
      p.add(mesh(box(pw, 0.08, 0.05), alu, 0, y, 0, false));
    }
    for (final x in [-pw / 2 + 0.035, pw / 2 - 0.035]) {
      p.add(mesh(box(0.07, h, 0.05), alu, x, h / 2, 0, false));
    }
    p.add(place(glassPane(pw - 0.14, h - 0.16), y: h / 2));
    p.add(mesh(box(0.03, 0.45, 0.08), tc(Palette.ink), -side * (pw / 2 - 0.12), 1.05, 0, false));
    final x0 = side * half / 2;
    p.position = vm.Vector3(x0, 0, 0);
    g.add(p);
    panels.add((p, x0));
  }
  final at = onWall(o.wall, o.u);
  final door = Door(at.x, 0, at.z, (k) {
    final e = k * k * (3 - 2 * k);
    for (final (p, x0) in panels) {
      p.position = vm.Vector3(x0 + x0.sign * e * (half + 0.04), 0, 0);
    }
  });
  return (group: mount(g, o), door: door);
}

/// A sagging string of party bulbs from [a] to [b], in [bulbs] (one per colour); they light up at night.
Node stringLights(vm.Vector3 a, vm.Vector3 b, double sag, List<(String, Material)> bulbs, NightParts night) {
  final mid = (a + b) * 0.5;
  mid.y -= sag * 2;
  vm.Vector3 at(double t) => a * ((1 - t) * (1 - t)) + mid * (2 * (1 - t) * t) + b * (t * t);
  final pts = [for (var i = 0; i <= 24; i++) at(i / 24)];
  var length = 0.0;
  for (var i = 1; i < pts.length; i++) {
    length += pts[i].distanceTo(pts[i - 1]);
  }
  final g = Node(name: 'string-lights');
  g.add(mesh(tubeThrough(pts, 0.012), tc(Palette.ink), 0, 0, 0, false));
  final n = math.max(2, (length / 0.5).round());
  for (var i = 1; i < n; i++) {
    final p = at(i / n);
    final (color, mat) = bulbs[i % bulbs.length];
    g.add(mesh(sphere(0.055, 8, 6), mat, p.x, p.y - 0.06, p.z, false));
    night.halos.add(Halo(at: vm.Vector3(p.x, p.y - 0.06, p.z), size: 0.55, color: color));
  }
  return mergeByMaterial(g);
}

/// Makes [obj] somewhere to sit (see seating): walk up to it, or look at it, and press E.
Interactable seatable(Node obj, String seatId, double radius, List<Interactable> interactables) {
  final seat = seatingById[seatId]!;
  final it = Interactable(kind: InteractKind.seat, seatId: seatId, x: seat.x, y: seat.y, z: seat.z, radius: radius);
  interactables.add(it);
  tagInteract(obj, it);
  return it;
}

/// The smoking balcony off the south wall, over the garage entrance: a deck with a glass railing on
/// its three open sides, string lights, a bench under the window, a bistro table, plants and the
/// ashtray, where you take a smoke break.
void buildBalcony(Node group, List<Interactable> interactables, NightParts night) {
  const minX = Balcony.minX, maxX = Balcony.maxX, minZ = Balcony.minZ, maxZ = Balcony.maxZ;
  const w = maxX - minX, d = maxZ - minZ;
  const cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
  // Everything that doesn't move and isn't textured goes in here, merged at the end.
  final parts = Node(name: 'balcony');
  parts.add(mesh(box(w, slab - 0.01, d), tc(Palette.wallTrim), cx, -slab / 2 - 0.005, cz));
  group.add(place(plankedFloor(w, d, color: '#d6a574'), x: cx, y: 0.002, z: cz));

  // Posts down to the street at the outer corners.
  const postH = -slab - streetY;
  for (final x in [minX + 0.25, maxX - 0.25]) {
    parts.add(mesh(cyl(0.12, 0.12, postH, 12), tc('#e6e8ee'), x, streetY + postH / 2, maxZ - 0.25));
  }

  // The railing: posts, a wooden top rail and glass between, on the three open sides.
  const railH = 1.05;
  final ink = tc(Palette.deskLeg);
  final wood = tc(Palette.wood);
  for (final (x0, z0, x1, z1) in balconySides) {
    final len = math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0));
    final alongX = z0 == z1;
    final n = (len / 1.6).ceil();
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      parts.add(mesh(box(0.06, railH, 0.06), ink, x0 + (x1 - x0) * t, railH / 2, z0 + (z1 - z0) * t, false));
    }
    parts.add(mesh(alongX ? box(len + 0.1, 0.07, 0.12) : box(0.12, 0.07, len + 0.1), wood, (x0 + x1) / 2, railH + 0.02, (z0 + z1) / 2));
    for (var i = 0; i < n; i++) {
      final t = (i + 0.5) / n;
      parts.add(
        place(glassPane(len / n - 0.1, railH - 0.2), x: x0 + (x1 - x0) * t, y: (railH - 0.2) / 2 + 0.08, z: z0 + (z1 - z0) * t, rot: yaw(alongX ? 0 : math.pi / 2)),
      );
    }
  }

  // Lamp poles on the outer corners, with string lights to them from the wall and between them.
  const poleH = 2.7;
  final sw = vm.Vector3(minX + balconyInset, poleH, maxZ - balconyInset);
  final se = vm.Vector3(maxX - balconyInset, poleH, maxZ - balconyInset);
  for (final p in [sw, se]) {
    parts.add(mesh(cyl(0.035, 0.035, poleH - railH, 6), ink, p.x, (poleH + railH) / 2, p.z, false));
  }
  final bulbs = [for (final c in ['#ffd166', '#ff8fa3', '#8ecae6', '#caffbf']) (c, bulb(night, c, 0.4) as Material)];
  final wallPoint = vm.Vector3(-6.5, 3.5, minZ + 0.02);
  parts.add(stringLights(sw, se, 0.35, bulbs, night));
  parts.add(stringLights(sw, wallPoint, 0.3, bulbs, night));
  parts.add(stringLights(wallPoint, se, 0.35, bulbs, night));
  // At night they light the deck, the table and whoever's out there.
  for (final x in [cx - 3.2, cx + 3.2]) {
    night.lamps.add(Lamp(x: x, y: 2.4, z: cz, reach: 5.5, color: '#ffc9a6', power: 2.4));
  }

  // A bench under the window, a bistro table with two stools, and plants.
  final bench = Node(name: 'bench');
  bench.add(mesh(roundedBox(2, 0.08, 0.46, 0.05), wood, 0, 0.45, 0));
  bench.add(mesh(box(2, 0.32, 0.06), wood, 0, 0.78, -0.2));
  for (final sx in [-0.85, 0.85]) {
    bench.add(mesh(box(0.06, 0.45, 0.4), ink, sx, 0.22, 0));
  }
  bench.position = vm.Vector3(-9, 0, minZ + 0.3);
  // Somewhere to sit, so not merged with the rest: its own meshes carry what E is about when you look at it.
  group.add(bench);
  seatable(bench, 'bench', 1.6, interactables);
  const tx = balconyTableX, tz = balconyTableZ;
  final table = Node(name: 'table');
  table.add(mesh(cyl(0.42, 0.42, 0.05, 20), tc('#fffaf3'), 0, 0.74, 0));
  table.add(mesh(cyl(0.04, 0.04, 0.7, 8), ink, 0, 0.37, 0));
  table.add(mesh(cyl(0.25, 0.28, 0.04, 16), ink, 0, 0.02, 0));
  table.add(mesh(cyl(0.06, 0.05, 0.12, 10), tc('#ef476f'), 0.15, 0.82, 0.05));
  table.position = vm.Vector3(tx, 0, tz);
  parts.add(table);
  for (final sx in [-1, 1]) {
    final x = tx + sx * 0.8;
    final stool = Node(name: 'stool');
    stool.add(mesh(cyl(0.2, 0.2, 0.06, 16), tc(sx < 0 ? '#5bc0eb' : '#ff8a5b'), 0, 0.46, 0));
    stool.add(mesh(cyl(0.03, 0.03, 0.44, 6), ink, 0, 0.22, 0));
    stool.add(mesh(cyl(0.16, 0.18, 0.03, 12), ink, 0, 0.015, 0));
    stool.position = vm.Vector3(x, 0, tz);
    group.add(stool);
    seatable(stool, sx < 0 ? 'stool-1' : 'stool-2', 0.9, interactables);
  }
  for (final (px, pz, sc) in balconyPlants) {
    parts.add(place(plant(sc), x: px, z: pz, scale: sc));
  }

  group.add(mergeByMaterial(parts));

  // The ashtray: a standing bin with a sand-filled bowl and a couple of butts in it.
  final tray = Node(name: 'ashtray');
  final steel = tc('#8d99ae');
  tray.add(mesh(cyl(0.2, 0.22, 0.05, 16), steel, 0, 0.025, 0));
  tray.add(mesh(cyl(0.07, 0.07, 0.8, 10), steel, 0, 0.45, 0));
  tray.add(mesh(cyl(0.2, 0.14, 0.14, 16), steel, 0, 0.9, 0));
  tray.add(mesh(cyl(0.18, 0.18, 0.02, 16), tc('#e9d8a6'), 0, 0.965, 0, false));
  final buttGeo = transformed(cyl(0.014, 0.014, 0.07, 6), rotZ(math.pi / 2));
  for (final (bx, bz, a) in [(0.06, 0.02, 0.4), (-0.05, -0.06, 2.1), (-0.02, 0.08, 1.2)]) {
    tray.add(place(mesh(buttGeo, tc(a > 1 ? '#fffaf3' : '#e9a03b'), 0, 0, 0, false), x: bx, y: 0.98, z: bz, rot: yaw(a)));
  }
  tray.position = vm.Vector3(Ashtray.x, 0, Ashtray.z);
  group.add(tray);
  final it = Interactable(kind: InteractKind.smoke, x: Ashtray.x, z: Ashtray.z, radius: 1.8);
  interactables.add(it);
  tagInteract(tray, it);

  final sign = textPlane('🚬 Smoke break', const TextOpts(bg: '#2b2d42', color: '#fffaf3', size: 56, border: '#fffaf3'));
  group.add(place(sign, x: -6.5, y: 2.2, z: minZ + 0.02, scale: 0.8));
}

/// Outside the exit: a concrete landing level with the office floor, and steps running south
/// along the west wall down to the street, with a railing on the open side.
void buildExitStairs(Node group) {
  const minX = ExitStairs.minX, maxX = ExitStairs.maxX, z0 = ExitStairs.landingZ0, z1 = ExitStairs.landingZ1;
  const steps = ExitStairs.steps, run = ExitStairs.run;
  const width = maxX - minX;
  const rise = -streetY / steps;
  const treads = steps - 1;
  const l = z1 - z0;
  // Side profile: x runs south from the landing's north end, y is height.
  final profile = Shape2()
    ..moveTo(0, streetY)
    ..lineTo(0, 0)
    ..lineTo(l, 0);
  for (var i = 1; i <= treads; i++) {
    profile
      ..lineTo(l + (i - 1) * run, -i * rise)
      ..lineTo(l + i * run, -i * rise);
  }
  profile.lineTo(l + treads * run, streetY);
  group.add(place(mesh(extrudeShape(profile, width), tc('#d3d6dd')), x: maxX, z: z0, rot: yaw(-math.pi / 2)));
  final tread = tc('#b9bdc6');
  const cx = (minX + maxX) / 2;
  group.add(mesh(box(width, 0.04, l), tread, cx, -0.015, z0 + l / 2, false));
  for (var i = 1; i <= treads; i++) {
    final zs = z1 + (i - 1) * run;
    group.add(mesh(box(width, 0.04, run + 0.02), tread, cx, -i * rise - 0.015, zs + run / 2, false));
  }

  // The railing: round the landing's open sides, then down the stairs.
  final ink = tc(Palette.deskLeg);
  const railX = minX + 0.06;
  const railH = 1.0;
  void post(double x, double y, double z) => group.add(mesh(cyl(0.03, 0.03, railH, 6), ink, x, y + railH / 2, z, false));
  void rail(double xa, double ya, double za, double xb, double yb, double zb) {
    final dir = vm.Vector3(xb - xa, yb - ya, zb - za);
    final r = mesh(cyl(0.035, 0.035, dir.length, 6), ink, 0, 0, 0, false);
    group.add(place(r, x: (xa + xb) / 2, y: (ya + yb) / 2 + railH, z: (za + zb) / 2, rot: vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), dir.normalized())));
  }

  const nz = z0 + 0.06;
  post(maxX - 0.05, 0, nz);
  post(railX, 0, nz);
  post(railX, 0, z1);
  rail(maxX - 0.05, 0, nz, railX, 0, nz);
  rail(railX, 0, nz, railX, 0, z1);
  const bottomZ = z1 + (treads - 0.5) * run;
  for (var i = 2; i <= treads; i += 3) {
    post(railX, -i * rise, z1 + (i - 0.5) * run);
  }
  post(railX, -treads * rise, bottomZ);
  rail(railX, 0, z1, railX, -treads * rise, bottomZ);
}

/// The four outside walls, built in pieces around their windows and doors (see [wallsPlan]). Each
/// is painted inside in the floor's colours and outside in the building's. Behind the loft they
/// carry on up past the ceiling downstairs, to the loft's roof.
void buildWalls(Node group, Looks looks) {
  final inside = looks.wall;
  final outside = tc(Palette.exterior);
  const t = wallT;
  final plan = wallsPlan();
  // A box's faces go +x, -x, +y, -y, +z, -z; the one facing outdoors gets the outside paint.
  const outFace = {Side.east: 0, Side.west: 1, Side.south: 4, Side.north: 5};
  // Merged by material: the pieces that cast shadows, the ones up past the ceiling that don't, and the baseboards.
  final casting = Node(name: 'walls'), above = Node(name: 'walls-above'), trim = Node(name: 'baseboards');
  for (final p in plan.pieces) {
    final out = outFace[p.side]!;
    final mats = [for (var i = 0; i < 6; i++) i == out ? outside : inside];
    final len = p.u1 - p.u0, h = p.y1 - p.y0;
    final um = (p.u0 + p.u1) / 2, ym = (p.y0 + p.y1) / 2;
    final n = p.alongX ? boxFaces(len, h, t, mats) : boxFaces(t, h, len, mats);
    n.castsShadows = p.y1 <= wallHeight;
    (n.castsShadows ? casting : above).add(p.alongX ? place(n, x: um, y: ym, z: p.at) : place(n, x: p.at, y: ym, z: um));
  }
  for (final r in plan.runs) {
    final len = r.u1 - r.u0, um = (r.u0 + r.u1) / 2;
    trim.add(
      r.alongX ? mesh(box(len, 0.25, t + 0.04), looks.trim, um, 0.125, r.at, false) : mesh(box(t + 0.04, 0.25, len), looks.trim, r.at, 0.125, um, false),
    );
  }
  for (final n in [casting, above, trim]) {
    group.add(mergeByMaterial(n));
  }
}
