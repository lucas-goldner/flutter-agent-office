// The four boards, framed in wood and iron on the walls, with a painted sign over each. A port of
// world/castle/boards.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan, boardKeys;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show planeXY, yaw;
import '../office/office.dart' show Face;
import '../text.dart';
import '../toon.dart';
import 'kit.dart';

/// The boards' faces by [BoardKey.wire], for the office to paint (see the controller's boards).
Map<String, Face> buildBoards(Kit kit, MapPlan plan) {
  final m = kit.mats;
  final faces = <String, Face>{};
  for (final k in boardKeys) {
    final bd = plan.boards[k]!;
    final nx = math.sin(bd.rotY), nz = math.cos(bd.rotY);
    final g = Node(name: 'board-${k.wire}')
      ..position = vm.Vector3(bd.x + nx * 0.1, bd.y, bd.z + nz * 0.1)
      ..rotation = yaw(bd.rotY);
    g.add(mesh(g3.box(bd.width + 0.36, bd.height + 0.36, 0.12), m.woodDark));
    for (final sx in const [-1, 1]) {
      for (final sy in const [-1, 1]) {
        g.add(
          mesh(g3.box(0.3, 0.3, 0.05), m.iron, sx * (bd.width / 2 + 0.05), sy * (bd.height / 2 + 0.05), 0.08, false),
        );
      }
    }
    final mat = UnlitMaterial();
    final face = mesh(planeXY(bd.width, bd.height), mat, 0, 0, 0.07, false);
    g.add(face);
    faces[k.wire] = Face(face, mat, bd.width, bd.height);
    g.add(
      textPlane(bd.label, const TextOpts(bg: '#efe3c2', color: '#3b2618', size: 64, border: '#6b4526'))
        ..position = vm.Vector3(0, bd.height / 2 + 0.55, 0.06)
        ..scale = vm.Vector3.all(1.15),
    );
    final it = Interactable(
      kind: InteractKind.values.byName(k.wire),
      x: bd.x + nx * 1.6,
      z: bd.z + nz * 1.6,
      radius: 2.4,
    );
    kit.interactables.add(it);
    tagInteract(g, it);
    kit.group.add(g);
  }
  return faces;
}
