// The kitchen corner against the south wall, modelled in Blender (blender/scripts/build_kitchen.py, #186):
// a counter with a wooden top and a sink under the window, a chunky espresso machine (E at it pours you a
// cup) and a round-shouldered retro fridge with notes stuck on it. A port of world/kitchen.ts. Without
// the model, the code-built corner from before.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';

import 'collider.dart';
import 'models.dart';
import 'office/geo.dart';
import 'office/parts.dart';
import 'toon.dart';

class Kitchen {
  Kitchen(this.group, this.colliders, this.interactable, this.machine);

  /// Everything but the coffee machine.
  final Node group;
  final List<Collider> colliders;

  /// The coffee machine: E at it for a minute of quicker feet and higher jumps.
  final Interactable interactable;

  /// The machine itself, which a look or a click at offers the coffee (the counter and the fridge don't).
  final Node machine;
}

/// Every material in kitchen.glb by name: the old code-built kitchen's colours, and the office's wood for the top.
const Map<String, String> kitchenColors = {
  'Cabinet': '#8ecae6',
  'Wood': '#c98b5a',
  'Chrome': '#adb5bd',
  'Dark': '#343a40',
  'White': '#ffffff',
  'Fridge': '#f8f9fa',
  'Note': '#ffd166',
  'Memo': '#bde0fe',
  'Red': '#ef476f',
};

Kitchen buildKitchen() {
  final interactable = Interactable(kind: InteractKind.coffee, x: -15.7, z: 10.9, radius: 1.4);
  final colliders = [
    Collider(minX: -17, maxX: -12, minZ: 11.7, maxZ: 12.7, top: 1.03),
    Collider(minX: -11.85, maxX: -10.75, minZ: 11.7, maxZ: 12.7, top: 2.2),
  ];
  final m = model(ModelName.kitchen);
  final machine = m?.scene.getChildByName('coffee_machine');
  if (m != null && machine != null) {
    final paint = palette(kitchenColors);
    // The machine's little light glows, as the old one did.
    paintModel(m.scene, (name) => name == 'Glow' ? tc('#ef476f', emissive: '#ef476f') : paint(name));
    // Modelled facing +z like everything else; against the south wall it turns round to face into the
    // room, which puts the machine at x -15.7 and the fridge at x -11.3.
    final group = place(m.scene, x: -14.5, z: 12.2, rot: yaw(math.pi));
    tagInteract(machine, interactable);
    return Kitchen(group, colliders, interactable, machine);
  }
  // The code-built corner.
  final kitchen = Node(name: 'kitchen');
  kitchen.add(mesh(box(5, 0.95, 1), tc('#8ecae6'), 0, 0.475, 0));
  kitchen.add(mesh(box(5.1, 0.08, 1.1), tc(Palette.desk), 0, 0.99, 0));
  // The fridge (#156): its doors and handles on the room-facing side (-z); +z is tight against the wall.
  final fridge = Node(name: 'fridge');
  fridge.add(mesh(roundedBox(1.1, 2.2, 1, 0.1), tc('#e9ecef'), 0, 1.1, 0));
  fridge.add(mesh(roundedBox(1, 1.25, 0.05, 0.06), tc('#f8f9fa'), 0, 1.49, -0.5));
  fridge.add(mesh(roundedBox(1, 0.73, 0.05, 0.06), tc('#f1f3f5'), 0, 0.45, -0.5));
  fridge.add(mesh(box(0.94, 0.035, 0.025), tc('#adb5bd'), 0, 0.84, -0.535));
  fridge.add(mesh(roundedBox(0.09, 0.43, 0.09, 0.025), tc('#6c757d'), -0.35, 1.26, -0.57));
  fridge.add(mesh(roundedBox(0.09, 0.3, 0.09, 0.025), tc('#6c757d'), -0.35, 0.62, -0.57));
  kitchen.add(place(fridge, x: 3.2));
  final coffee = Node(name: 'coffee');
  coffee.add(mesh(roundedBox(0.6, 0.7, 0.5, 0.08), tc('#343a40'), 0, 0.35, 0));
  coffee.add(mesh(cyl(0.08, 0.07, 0.14, 10), tc('#ffffff'), 0, 0.1, 0.12));
  coffee.add(mesh(sphere(0.05, 8, 8), tc('#ef476f', emissive: '#ef476f'), 0.18, 0.55, 0.26));
  final placed = mergeByMaterial(coffee);
  kitchen.add(place(placed, x: -1.2, y: 1.03));
  tagInteract(placed, interactable);
  return Kitchen(place(kitchen, x: -14.5, z: 12.2), colliders, interactable, placed);
}
