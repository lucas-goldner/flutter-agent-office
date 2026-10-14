// The office's furnishings modelled in Blender (#186): the potted plants, the desks' mugs and books, and
// the lounge's sofa, pillows, poufs and coffee table. A port of world/office/props.ts's model half. Each
// is a painted piece of a preloaded model (world/models.dart); if the model didn't load, the code-built
// one from before stands in, so the office still opens furnished.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../models.dart';
import '../toon.dart';
import 'geo.dart';
import 'parts.dart';

// The potted plants (blender/scripts/build_plants.py): each plant is a painted copy of one species in
// plants.glb. A species is its pot, named after it, with everything that grows out of the pot hung under
// it as `<species>_leaves` (see plantLeaves). The colours are the old code-built plants' pot and greens,
// the Christmas tree's trunk brown for the soil, the street trees' trunk brown for the ficus's, and the
// kitchen cupboards' blue for the snake plant's glazed pot.
enum PlantSpecies { monstera, snakePlant, ficus, succulent }

extension PlantSpeciesName on PlantSpecies {
  /// Its node in plants.glb.
  String get part => switch (this) {
    PlantSpecies.snakePlant => 'snake_plant',
    _ => name,
  };
}

/// The species that stand on the floor, which a row of plants takes turns with (see [floorPlant]).
const List<PlantSpecies> floorPlants = [PlantSpecies.monstera, PlantSpecies.snakePlant, PlantSpecies.ficus];

const Map<String, String> plantColors = {
  'Pot': Palette.pot,
  'Glaze': '#8ecae6',
  'Soil': '#6b4226',
  'Bark': '#8a5a3b',
  'Leaf': Palette.plant,
  'LeafDark': Palette.plantDark,
};

/// The floor species for the [i]th of a row of plants: they take turns, so no two neighbours match.
PlantSpecies floorPlant(int i) => floorPlants[i % floorPlants.length];

/// A potted plant of [species], [scale] times its modelled size, its origin on the floor in the middle of
/// its pot. At scale 1 a floor species' pot is the old one's size, so colliders of 0.3 * scale still fit
/// it; the succulent is desk-sized as it is. Without the model, the old code-built plant (a third the
/// size for the succulent).
Node pottedPlant(PlantSpecies species, [double scale = 1]) {
  final g = Node(name: 'plant');
  if (Models.instance.has(ModelName.plants)) {
    g.add(piece(ModelName.plants, species.part, palette(plantColors)));
    g.scale = vm.Vector3.all(scale);
  } else {
    final s = species == PlantSpecies.succulent ? 0.35 * scale : scale;
    g.add(plant());
    g.scale = vm.Vector3.all(s);
  }
  return g;
}

/// A plant's leaves, and whatever else grows out of its pot (stalks, a trunk): everything but the pot and
/// its soil. Christmas hides them and stands a little tree in the pot instead (world/holiday.dart).
List<Node> plantLeaves(Node potted) => [
  for (final n in walk(potted))
    if (n.name.endsWith('_leaves')) n,
];

// The desks' knick-knacks (blender/scripts/build_desk_props.py): a mug of coffee, and books in a few
// arrangements, each a piece of desk_props.glb. The colours are the old code-built books' covers, the
// book's page edges and the coffee in a worker's mug; the mug itself is painted whatever colour it's given.
const Map<String, String> deskPropColors = {
  'CoverRed': '#e63946',
  'CoverBlue': '#457b9d',
  'CoverOrange': '#f4a261',
  'Pages': '#f3ead8',
  'Coffee': '#6f4518',
};

/// The arrangements of books, which the desks with books take turns with (see [deskBooks]).
const List<String> deskBookArrangements = ['books_upright', 'books_leaning', 'books_stack'];

/// A mug of coffee, its body [color] ('#rrggbb'), its origin on the desk under the middle of its body
/// and its handle out to +x. Without the model, the old cylinder.
Node deskMug(String color) {
  if (!Models.instance.has(ModelName.deskProps)) return mesh(cyl(0.06, 0.05, 0.12, 10), tc(color), 0, 0.06, 0);
  final body = tc(color);
  final paint = palette(deskPropColors);
  return piece(ModelName.deskProps, 'mug', (name) => name == 'Mug' ? body : paint(name));
}

/// The [i]th arrangement of books (they take turns), spines to +z, its origin on the desk in the middle
/// of its footprint, at most the old code-built books' 0.26 by 0.18, and 0.24 tall. Without the model, the
/// old three boxes.
Node deskBooks(int i) {
  if (Models.instance.has(ModelName.deskProps)) {
    return piece(ModelName.deskProps, deskBookArrangements[i % deskBookArrangements.length], palette(deskPropColors));
  }
  final books = Node(name: 'books');
  const colors = ['#e63946', '#457b9d', '#f4a261'];
  for (var k = 0; k < 3; k++) {
    books.add(mesh(box(0.08, 0.24, 0.18), tc(colors[k]), (k - 1) * 0.09, 0.12, 0));
  }
  return books;
}

// The lounge's furniture (blender/scripts/build_lounge.py): the sofa, a throw pillow, a floor pouf and the
// coffee table, each a piece of lounge.glb placed on its own. Sofa is the old couch's blue, Wood and Frame
// the old coffee table's top and pedestal, WoodDark the sofa's feet. A pillow's or a pouf's Cloth is each
// copy's own colour, so it has none here: a copy that forgets its colour comes out magenta.
const Map<String, String> loungeColors = {
  'Sofa': '#5b8def',
  'WoodDark': '#8a5a3b',
  'Wood': Palette.wood,
  'Frame': Palette.deskLeg,
};

bool get _lounge => Models.instance.has(ModelName.lounge);

/// A pillow or a pouf, its Cloth in [color].
Node _upholstered(String part, String color) {
  final cloth = tc(color);
  final paint = palette(loungeColors);
  return piece(ModelName.lounge, part, (name) => name == 'Cloth' ? cloth : paint(name));
}

/// The lounge's couch: the sofa, facing +z like every model, with a throw pillow leaning on its back
/// cushions either side of its middle, halfway between its places (1.2 apart), clear of whoever sits
/// there. Its origin is on the floor under its middle, it's 4.2 long across x and 1.0 deep, and its seat
/// cushions' tops are 0.47 up. Without the model, the old code-built couch, laid out the same way.
Node loungeCouch() {
  final g = Node(name: 'couch');
  if (!_lounge) {
    final mat = tc('#5b8def');
    // The old couch ran along z with its back to -x; turned a quarter to face +z like the model.
    final old = Node(name: 'couch-code')..rotation = yaw(-math.pi / 2);
    old.add(mesh(roundedBox(1, 0.45, 4.2, 0.2), mat, 0, 0.3, 0));
    old.add(mesh(roundedBox(0.35, 0.9, 4.2, 0.15), mat, -0.45, 0.55, 0));
    old.add(mesh(roundedBox(1, 0.7, 0.35, 0.15), mat, 0, 0.45, -2.0));
    old.add(mesh(roundedBox(1, 0.7, 0.35, 0.15), mat, 0, 0.45, 2.0));
    old.add(mesh(roundedBox(0.2, 0.45, 0.5, 0.1), tc('#ffd166'), -0.2, 0.75, -0.9));
    old.add(mesh(roundedBox(0.2, 0.45, 0.5, 0.1), tc('#ef476f'), -0.2, 0.75, 0.9));
    return g..add(old);
  }
  g.add(piece(ModelName.lounge, 'sofa', palette(loungeColors)));
  for (final (x, color) in const [(0.6, '#ffd166'), (-0.6, '#ef476f')]) {
    // Standing on the seat, sunk in a little, its top tipped back onto the back cushions.
    g.add(place(_upholstered('pillow', color), x: x, y: 0.46, z: -0.08, rot: euler(-0.15)));
  }
  return g;
}

/// A floor pouf in [color], about 1.05 round and 0.4 tall, its origin on the floor under its middle.
/// Without the model, the old beanbag.
Node pouf(String color) {
  if (_lounge) return _upholstered('pouf', color);
  return Node(name: 'pouf')..add(place(mesh(sphere(0.6, 16, 12), tc(color)), y: 0.35, scale3: vm.Vector3(1, 0.6, 1)));
}

/// The lounge's round coffee table, 0.9 round, its top 0.46 up (where the holiday pumpkin stands).
Node coffeeTable() {
  if (_lounge) return piece(ModelName.lounge, 'coffee_table', palette(loungeColors));
  final table = Node(name: 'coffee-table');
  table.add(mesh(cyl(0.9, 0.9, 0.08, 24), tc(Palette.wood), 0, 0.42, 0));
  table.add(mesh(cyl(0.12, 0.2, 0.4, 12), tc(Palette.deskLeg), 0, 0.2, 0));
  return table;
}
