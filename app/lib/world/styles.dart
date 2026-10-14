// How each style of map is put up (see office_shared's maps): the castle's stone hall, the station's
// deck in orbit. A new style is a builder here, taking a map's plan to a World, and its name in
// MapStyle: every map in that style can then be picked, and the controller shows it like any other.
// A port of world/styles.ts.

import 'package:office_shared/maps/maps.dart' show MapPlan, PlanStyle;

import 'castle/castle.dart';
import 'labels.dart';
import 'world.dart';

typedef WorldBuilder = World Function(MapPlan plan, LabelHub labels);

final Map<PlanStyle, WorldBuilder> worldBuilders = {PlanStyle.castle: buildCastle};
