// The rooftop bar: the roof of the building, over its top floor. Nobody works up there. There's a DJ
// playing drum and bass under a rig of lights, a bar to drink at, and the city all around. The
// elevator goes up there from every floor. Shared by the server (who's up there, what they're
// holding) and the client (which builds it and plays the music). Port of src/shared/rooftop.ts.

import 'json_util.dart';

/// Where you are while you're on the roof (a peer's `floor`, and `floor.go`'s). It can never be a
/// project floor's id, which is only ever lowercase letters, digits and dashes.
const String roof = '@roof';
const String roofName = 'Rooftop bar';

/// What a drink comes in: a pint, a wine glass, a martini glass, a tall glass or a shot glass.
enum Glass implements WireEnum {
  pint('pint'),
  wine('wine'),
  martini('martini'),
  highball('highball'),
  shot('shot');

  const Glass(this.wire);
  @override
  final String wire;
}

enum DrinkId implements WireEnum {
  beer('beer'),
  wine('wine'),
  martini('martini'),
  maitai('maitai'),
  shot('shot'),
  mojito('mojito'),
  water('water');

  const DrinkId(this.wire);
  @override
  final String wire;

  static DrinkId? tryParse(Object? v) => parseWireOrNull(values, v);

  Drink get drink => drinkById[this]!;
}

class Drink {
  const Drink({
    required this.id,
    required this.name,
    required this.emoji,
    required this.blurb,
    required this.strength,
    required this.color,
    required this.glass,
  });

  final DrinkId id;
  final String name;
  final String emoji;

  /// What the menu says about it.
  final String blurb;

  /// How much it goes to your head. About 0.3 a drink is tipsy for half a minute or so; they add up,
  /// and past [boozeLimit] the bartender pours you a water instead. Water takes some of it away again.
  final double strength;

  /// The drink in the glass.
  final String color;
  final Glass glass;
}

const List<Drink> drinks = [
  Drink(
    id: DrinkId.beer,
    name: 'Lager',
    emoji: '🍺',
    blurb: 'Cold, from the tap',
    strength: 0.28,
    color: '#f2b134',
    glass: Glass.pint,
  ),
  Drink(
    id: DrinkId.wine,
    name: 'Red wine',
    emoji: '🍷',
    blurb: 'A generous pour',
    strength: 0.34,
    color: '#8e1c3c',
    glass: Glass.wine,
  ),
  Drink(
    id: DrinkId.martini,
    name: 'Martini',
    emoji: '🍸',
    blurb: 'Shaken, with an olive',
    strength: 0.45,
    color: '#e6f0c8',
    glass: Glass.martini,
  ),
  Drink(
    id: DrinkId.maitai,
    name: 'Mai tai',
    emoji: '🍹',
    blurb: 'Rum, lime, a little umbrella',
    strength: 0.45,
    color: '#ff8c42',
    glass: Glass.highball,
  ),
  Drink(
    id: DrinkId.shot,
    name: 'Tequila shot',
    emoji: '🥃',
    blurb: 'Salt, shot, lime. Careful',
    strength: 0.6,
    color: '#f7d488',
    glass: Glass.shot,
  ),
  Drink(
    id: DrinkId.mojito,
    name: 'Virgin mojito',
    emoji: '🍃',
    blurb: 'All of the mint, none of the rum',
    strength: 0,
    color: '#b7e4a0',
    glass: Glass.highball,
  ),
  Drink(
    id: DrinkId.water,
    name: 'Water',
    emoji: '💧',
    blurb: 'Clears your head a little',
    strength: -0.3,
    color: '#d6f1ff',
    glass: Glass.highball,
  ),
];

final Map<DrinkId, Drink> drinkById = Map.unmodifiable({for (final d in drinks) d.id: d});

bool isDrink(Object? v) => DrinkId.tryParse(v) != null;

/// How drunk you can get: past this the bartender cuts you off and pours you a water.
const double boozeLimit = 1.6;
