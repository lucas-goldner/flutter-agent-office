// The upstairs office: a loft on posts in the south-east corner, with glass on the two sides that
// face the desks, reached by stairs along the south wall (buildLoft in office.ts). Its colliders
// are loftColliders().

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';
import 'shell.dart';

/// A flat face something is shown on later: a board, the TV, the boss's monitor. [node] is a
/// +z-facing plane [width] x [height] with its own unlit [material].
class Face {
  Face(this.node, this.material, this.width, this.height);

  final Node node;
  final UnlitMaterial material;
  final double width;
  final double height;
}

/// Builds the loft into [group] and returns the boss's monitor, where Minesweeper plays (ui/arcade.dart).
Face buildLoft(Node group, List<Interactable> interactables, Looks looks) {
  const minX = Loft.minX, maxX = Loft.maxX, minZ = Loft.minZ, maxZ = Loft.maxZ, floorY = Loft.y, height = Loft.height;
  const w = maxX - minX, d = maxZ - minZ;
  const cx = LoftPlan.cx, cz = LoftPlan.cz, roofY = LoftPlan.roofY;
  const slabT = LoftPlan.slabT;
  const t = LoftPlan.glassT;
  final wallMat = looks.wall;
  final trimMat = looks.trim;
  final frameMat = tc('#ffffff');
  final woodMat = tc(Palette.wood);
  // Everything that never moves and needs no clicking, merged at the end.
  final stat = Node(name: 'loft');

  // Floor slab, planked like downstairs, with a trim fascia you see from below.
  stat.add(mesh(box(w, slabT, d), trimMat, cx, floorY - slabT / 2, cz));
  group.add(place(plankedFloor(w, d, looks: looks), x: cx, y: floorY + 0.005, z: cz));

  // Posts holding up the open corner.
  for (final x in [minX + 0.15, cx]) {
    stat.add(mesh(cyl(0.12, 0.12, floorY - slabT, 12), trimMat, x, (floorY - slabT) / 2, minZ + 0.15));
  }

  // The outside walls carry on up behind the loft (buildWalls); the sun shines through them and the roof.
  stat.add(mesh(box(w + wallT, 0.2, d + wallT), wallMat, cx + wallT / 2, roofY + 0.1, cz + wallT / 2, false));
  stat.add(mesh(box(w + 0.34, 0.24, 0.04), trimMat, cx + 0.15, roofY + 0.1, minZ - 0.02, false));
  stat.add(mesh(box(0.04, 0.24, d + 0.34), trimMat, minX - 0.02, roofY + 0.1, cz + 0.15, false));
  stat.add(mesh(box(w, 0.25, 0.04), trimMat, cx, floorY + 0.125, maxZ - 0.02, false));
  stat.add(mesh(box(0.04, 0.25, d), trimMat, maxX - 0.02, floorY + 0.125, cz, false));

  // Floor-to-ceiling glass on the north and west sides, so you can look down on everyone working.
  const doorZ = LoftPlan.doorZ;
  void pane(double len, double px, double pz, double rotY) =>
      stat.add(place(glassPane(len, height), x: px, y: floorY + height / 2, z: pz, rot: yaw(rotY)));
  void bar(double bw, double bh, double bd, double x, double y, double z) => stat.add(mesh(box(bw, bh, bd), frameMat, x, y, z, false));
  const northZ = minZ + t / 2;
  const westX = minX + t / 2;
  for (var i = 0; i < 6; i++) {
    pane(w / 6, minX + (i + 0.5) * (w / 6), northZ, 0);
  }
  for (var i = 0; i <= 6; i++) {
    bar(0.1, height, t + 0.04, minX + i * (w / 6), floorY + height / 2, northZ);
  }
  bar(w, 0.12, t + 0.06, cx, floorY + 0.06, northZ);
  bar(w, 0.12, t + 0.06, cx, roofY - 0.06, northZ);
  const westLen = doorZ - minZ;
  for (var i = 0; i < 2; i++) {
    pane(westLen / 2, westX, minZ + (i + 0.5) * (westLen / 2), math.pi / 2);
  }
  for (var i = 0; i <= 2; i++) {
    bar(t + 0.04, height, 0.1, westX, floorY + height / 2, minZ + i * (westLen / 2));
  }
  bar(t + 0.06, 0.12, westLen, westX, floorY + 0.06, minZ + westLen / 2);
  bar(t + 0.06, 0.12, westLen, westX, roofY - 0.06, minZ + westLen / 2);
  // Over the door at the top of the stairs.
  const doorTop = LoftPlan.doorTop;
  stat.add(mesh(box(t + 0.04, roofY - doorTop, maxZ - doorZ), wallMat, westX, (roofY + doorTop) / 2, (doorZ + maxZ) / 2, false));

  // Stairs: a solid run of steps up the south wall, wood treads, a handrail on the open side.
  const fromX = Stairs.fromX, toX = Stairs.toX, steps = Stairs.steps;
  const sw = Stairs.maxZ - Stairs.minZ;
  const run = (toX - fromX) / steps;
  const rise = floorY / steps;
  final profile = Shape2()..moveTo(0, 0);
  for (var i = 0; i < steps; i++) {
    profile
      ..lineTo(i * run, (i + 1) * rise - 0.04)
      ..lineTo((i + 1) * run, (i + 1) * rise - 0.04);
  }
  profile.lineTo(toX - fromX, 0);
  stat.add(mesh(extrudeShape(profile, sw), wallMat, fromX, 0, Stairs.minZ));
  for (var i = 1; i <= steps; i++) {
    stat.add(mesh(box(run + 0.04, 0.06, sw), woodMat, fromX + (i - 0.5) * run - 0.02, i * rise - 0.03, Stairs.minZ + sw / 2, false));
  }
  const railZ = Stairs.minZ + 0.06;
  const railH = 0.9;
  final inkMat = tc(Palette.deskLeg);
  for (var i = 1; i <= steps; i += 2) {
    stat.add(mesh(cyl(0.03, 0.03, railH, 6), inkMat, fromX + (i - 0.5) * run, i * rise + railH / 2, railZ, false));
  }
  const x0 = fromX + 0.5 * run;
  const x1 = fromX + (steps - 0.5) * run;
  final hlen = math.sqrt(math.pow(x1 - x0, 2) + math.pow((x1 - x0) * (rise / run), 2)) + 0.1;
  stat.add(place(mesh(box(hlen, 0.07, 0.07), woodMat, 0, 0, 0, false), x: (x0 + x1) / 2, y: (rise + floorY) / 2 + railH, z: railZ, rot: euler(0, 0, math.atan2(rise, run))));

  // Inside: the big desk facing the glass, a comfy couch, a telescope aimed at the desks.
  const deskX = LoftPlan.deskX, deskZ = LoftPlan.deskZ;
  final desk = Node(name: 'boss-desk');
  final wood = Node(name: 'desk');
  wood.add(mesh(roundedBox(2.6, 0.1, 1.2, 0.1), woodMat, 0, 0.78, 0));
  wood.add(mesh(box(2.4, 0.66, 0.08), tc('#8a5a3b'), 0, 0.4, -0.5));
  for (final sx in [-1, 1]) {
    wood.add(mesh(box(0.1, 0.72, 1.0), tc('#8a5a3b'), sx * 1.15, 0.37, 0));
  }
  wood.add(mesh(roundedBox(0.9, 0.55, 0.06, 0.03), tc(Palette.ink), 0, 1.18, -0.2));
  wood.add(mesh(box(0.08, 0.2, 0.08), tc(Palette.ink), 0, 0.93, -0.2));
  wood.add(mesh(cyl(0.06, 0.05, 0.12, 10), tc('#ffd166'), 0.9, 0.89, 0.15));
  desk.add(mergeByMaterial(wood));
  // Minesweeper plays on it (ui/arcade.dart).
  final screenMat = flat('#4cc9f0');
  final screen = mesh(planeXY(0.8, 0.45), screenMat, 0, 1.18, -0.165, false);
  desk.add(screen);
  desk.add(place(textPlane('👑 BOSS', const TextOpts(bg: '#ffd166', size: 48)), y: 0.5, z: -0.55, rot: yaw(math.pi), scale: 0.55));
  final bossChair = chair('#2b2d42');
  desk.add(place(bossChair, z: 1.0, scale: 1.2));
  final chairIt = seatable(bossChair, 'boss-chair', 1.2, interactables);
  // Clicking the screen is using the chair: sit down, then play.
  tagInteract(screen, chairIt);
  desk.position = vm.Vector3(deskX, floorY, deskZ);
  group.add(desk);

  final couch = Node(name: 'loft-couch');
  final couchMat = tc('#ef476f');
  couch.add(mesh(roundedBox(1, 0.45, 2.4, 0.2), couchMat, 0, 0.3, 0));
  couch.add(mesh(roundedBox(0.35, 0.9, 2.4, 0.15), couchMat, 0.45, 0.55, 0));
  for (final sz in [-1, 1]) {
    couch.add(mesh(roundedBox(1, 0.7, 0.3, 0.15), couchMat, 0, 0.45, sz * 1.1));
  }
  couch.add(mesh(roundedBox(0.2, 0.45, 0.5, 0.1), tc('#ffd166'), 0.2, 0.75, 0.4));
  final sofa = place(mergeByMaterial(couch), x: maxX - 0.65, y: floorY, z: cz);
  group.add(sofa);
  seatable(sofa, 'loft-couch', 1.8, interactables);

  stat.add(mesh(roundedBox(4.6, 0.02, 3.2, 0.6), tc('#caffbf'), deskX - 0.3, floorY + 0.015, cz + 0.1, false));

  final scope = Node(name: 'telescope');
  for (var i = 0; i < 3; i++) {
    final a = i / 3 * math.pi * 2;
    final leg = mesh(cyl(0.025, 0.025, 1.1, 6), inkMat, 0, 0, 0);
    scope.add(place(leg, x: math.sin(a) * 0.2, y: 0.52, z: math.cos(a) * 0.2, rot: euler(math.cos(a) * -0.35, 0, math.sin(a) * 0.35)));
  }
  final tube = Node(name: 'tube');
  tube.add(mesh(transformed(cyl(0.1, 0.06, 0.9, 14), rotX(math.pi / 2)), tc('#ffd166'), 0, 0, 0.1));
  tube.add(mesh(transformed(cyl(0.11, 0.11, 0.08, 14), rotX(math.pi / 2)), tc(Palette.ink), 0, 0, 0.55));
  const scopeX = minX + 0.9, scopeZ = minZ + 0.9;
  // Aimed at the desks: its +z toward (-6, 0.8, 0).
  tube.position = vm.Vector3(0, 1.08, 0);
  tube.rotation = lookAlong(vm.Vector3(-6 - scopeX, 0.8 - (floorY + 1.08), 0 - scopeZ));
  scope.add(tube);
  scope.position = vm.Vector3(scopeX, floorY, scopeZ);
  stat.add(scope);

  for (final (px, pz, s) in LoftPlan.plants) {
    stat.add(place(plant(s), x: px, y: floorY, z: pz, scale: s));
  }

  stat.add(place(pendant(), x: deskX, y: roofY - 0.4, z: cz, scale: 0.8));

  group.add(mergeByMaterial(stat));

  // Signs: one on the back wall inside, one over the glass for everyone downstairs.
  group.add(place(textPlane('👑 Boss Office', const TextOpts(bg: '#fffaf3', size: 64)), x: maxX - 3, y: floorY + 1.9, z: maxZ - 0.04, rot: yaw(math.pi), scale: 0.8));
  group.add(
    place(
      textPlane('👑 Boss Office', const TextOpts(bg: '#2b2d42', color: '#fffaf3', size: 64, border: '#fffaf3')),
      x: cx,
      y: roofY + 0.2,
      z: minZ - 0.02,
      rot: yaw(math.pi),
      scale: 1.4,
    ),
  );
  return Face(screen, screenMat, 0.8, 0.45);
}
