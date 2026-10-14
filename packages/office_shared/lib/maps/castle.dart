// The castle: a long, high hall with tables down both sides where the workers sit, and at the far
// end, up on a dais, a throne of iron blades where you sit. Workers waiting on you (done, or stuck
// on a question) come and line up in front of it. The Hand of the King stands at your left, and
// speaking to him sends a new worker off to a free seat at the tables. The boards hang on the side
// walls, each with a scribe at a lectern below it.
//
// This is all data: moving something is changing a number here, or (without touching the code) a
// map of your own that `extends: 'castle'` in the office's .agent-office/maps/ (docs/maps.md).
//
// The hall runs north (-z, the throne) to south (+z, the doors); x is across it, west (-x) to east.
// Ported from src/shared/maps/castle.ts.

import 'dart:math' as math;

import 'types.dart';

const double _w = 26;
const double _l = 60;

/// The pillars down each side, every 6 m, and the bays between them where the boards and windows go.
const double _pillarX = 10.4;
const List<double> _pillarsZ = [-24, -18, -12, -6, 0, 6, 12, 18, 24];
const List<double> _baysZ = [-21, -15, -9, -3, 3, 9, 15, 21];

/// Just off the inside of each side wall.
const double _wallX = _w / 2 - 0.08;

/// Where the hearth is on the west wall.
const double _hearthZ = 15;

double _facing(int side) => side < 0 ? math.pi / 2 : -math.pi / 2;

List<Map<String, dynamic>> _props() => [
  // Pillars down both sides, a torch on every other one, banners on the rest.
  for (final z in _pillarsZ)
    for (final side in const [-1, 1]) {'kind': 'pillar', 'x': side * _pillarX, 'z': z},
  for (final z in const [-24.0, -12.0, 0.0, 12.0, 24.0])
    for (final side in const [-1, 1])
      {
        'kind': 'torch',
        'x': side * (_pillarX - 0.68),
        'z': z,
        'y': 2.7,
        'rotY': _facing(side),
        'light': z == -12 || z == 12,
      },
  for (final z in const [-18.0, -6.0, 6.0, 18.0])
    for (final side in const [-1, 1])
      {
        'kind': 'banner',
        'x': side * (_pillarX - 0.67),
        'z': z,
        'y': 11.2,
        'width': 1.25,
        'height': 5,
        'rotY': _facing(side),
      },
  // Tall stained glass high up in every bay, and a rose window over the throne and over the doors.
  // (Not over the hearth, whose chimney goes up the west wall there.)
  for (final z in _baysZ)
    for (final side in const [-1, 1])
      if (!(side < 0 && z == _hearthZ))
        {'kind': 'window', 'x': side * _wallX, 'z': z, 'y': 6.4, 'width': 2.3, 'height': 5.2, 'rotY': _facing(side)},
  {'kind': 'rose', 'x': 0, 'z': -_l / 2 + 0.08, 'y': 10.4, 'width': 4.6, 'rotY': 0},
  {'kind': 'rose', 'x': 0, 'z': _l / 2 - 0.08, 'y': 10.3, 'width': 4.2, 'rotY': math.pi},
  // The great banner behind the throne.
  {'kind': 'banner', 'x': 0, 'z': -_l / 2 + 0.1, 'y': 7.7, 'width': 3.4, 'height': 6, 'rotY': 0},
  // Shields and crossed swords in the bays that have no board.
  for (final z in const [-21.0, -9.0, 9.0, 21.0])
    for (final side in const [-1, 1]) {'kind': 'shield', 'x': side * _wallX, 'z': z, 'y': 3.6, 'rotY': _facing(side)},
  // The red carpet from the doors to the foot of the dais.
  {'kind': 'carpet', 'x': 0, 'z': 3.35, 'width': 3.6, 'length': 52.5},
  // Fire: braziers by the dais steps and down by the doors, the hearth, candles by the throne.
  {'kind': 'brazier', 'x': -3.7, 'z': -21.4, 'light': true},
  {'kind': 'brazier', 'x': 3.7, 'z': -21.4, 'light': true},
  {'kind': 'brazier', 'x': -3.7, 'z': 17},
  {'kind': 'brazier', 'x': 3.7, 'z': 17},
  {'kind': 'hearth', 'x': -_w / 2 + 0.55, 'z': _hearthZ, 'rotY': math.pi / 2, 'light': true},
  {'kind': 'candles', 'x': -2.1, 'z': -28.9},
  {'kind': 'candles', 'x': 2.1, 'z': -28.9},
  // Chandeliers down the middle.
  for (final z in const [-15, -3, 9, 21]) {'kind': 'chandelier', 'x': 0, 'z': z, 'y': 9.2},
  // Stone knights either side of the throne, and armour by the doors.
  {'kind': 'statue', 'x': -5, 'z': -28.6},
  {'kind': 'statue', 'x': 5, 'z': -28.6},
  {'kind': 'armor', 'x': -4.2, 'z': 28.4, 'rotY': math.pi},
  {'kind': 'armor', 'x': 4.2, 'z': 28.4, 'rotY': math.pi},
  {'kind': 'armor', 'x': -12.1, 'z': 24.5, 'rotY': math.pi / 2},
  {'kind': 'armor', 'x': 12.1, 'z': 24.5, 'rotY': -math.pi / 2},
  // The merge gong, west of the dais; ale on the east wall.
  {'kind': 'gong', 'x': -7.6, 'z': -19.6, 'rotY': math.pi / 2},
  {'kind': 'cask', 'x': _w / 2 - 0.65, 'z': 15, 'rotY': -math.pi / 2},
];

// The dungeon, under the south end of the hall. Its stairs come up by the east wall, south of the
// east tables; cells line its north and south walls, and the Kingsguard keeps watch at the stairs' foot.
abstract final class _Dungeon {
  static const double minX = -11.4;
  static const double maxX = 9.4;
  static const double minZ = 13.6;
  static const double maxZ = 29.4;
}

/// The north row of cells stops short of the stairs, which run down beside the east wall.
const int _northCells = 4;
const int _southCells = 5;
const double _cellDepth = 4;
const double _northEnd = 7;
const double _northW = (_northEnd - _Dungeon.minX) / _northCells;
const double _southW = (_Dungeon.maxX - _Dungeon.minX) / _southCells;
const double _aisleZ = (_Dungeon.minZ + _cellDepth + _Dungeon.maxZ - _cellDepth) / 2;
double _round(double v) => (v * 100).round() / 100;

/// The castle (TS CASTLE).
final MapConfig castleMap = {
  'id': 'castle',
  'name': 'Castle',
  'icon': '🏰',
  'description':
      'A great hall with a throne of iron blades. Workers sit at the long tables, line up before your throne when they’re done or need you, and grow long grey beards the longer they work. Speak to the Hand of the King to send out a new one; send one home, and the Kingsguard drags it down to the dungeon to rot.',
  'style': 'castle',
  'hall': {'width': _w, 'length': _l, 'height': 13},
  'spawn': {'x': -2.6, 'z': -21, 'rotY': math.pi},
  'door': {'x': 0, 'z': _l / 2 - 1.4},
  'throne': {
    'x': 0,
    'z': -27.4,
    'rotY': 0,
    'dais': {'width': 12, 'depth': 5, 'height': 0.9, 'steps': 3},
  },
  'herald': {
    'x': 3.3,
    'z': -26.3,
    'rotY': -0.35,
    'name': 'Hand of the King',
    'says': 'Speak to me to send out a new worker',
    'ask': 'What shall they toil on, my liege?',
    'button': 'Send them out ⚔️',
  },
  'lineup': {
    'x': 0,
    'z': -25.6,
    'rotY': math.pi,
    'step': [0, 1.3],
    'count': 8,
  },
  'tables': [
    {'name': 'North-west table', 'x': -6.8, 'z': -8, 'length': 10, 'seats': 4},
    {'name': 'North-east table', 'x': 6.8, 'z': -8, 'length': 10, 'seats': 4},
    {'name': 'South-west table', 'x': -6.8, 'z': 6, 'length': 10, 'seats': 4},
    {'name': 'South-east table', 'x': 6.8, 'z': 6, 'length': 10, 'seats': 4},
  ],
  'stations': {
    'issues': {'x': -11.3, 'z': -15, 'rotY': -math.pi / 2},
    'queue': {'x': -11.3, 'z': -3, 'rotY': -math.pi / 2},
    'pulls': {'x': 11.3, 'z': -15, 'rotY': math.pi / 2},
  },
  'council': {'x': 6.6, 'z': -18.8, 'rotY': 0},
  'boards': {
    'issues': {
      'x': -_wallX,
      'y': 3.5,
      'z': -15,
      'rotY': math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '📜 Petitions',
    },
    'queue': {
      'x': -_wallX,
      'y': 3.5,
      'z': -3,
      'rotY': math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '📋 Orders of the day',
    },
    'pulls': {
      'x': _wallX,
      'y': 3.5,
      'z': -15,
      'rotY': -math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '🔀 Decrees for the seal',
    },
    'services': {
      'x': _wallX,
      'y': 3.5,
      'z': -3,
      'rotY': -math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '🌐 Services',
    },
  },
  'props': _props(),
  'agents': {'outfit': 'peasant', 'ageMinutes': 30},
  'palette': {'stone': '#8c847a', 'floor': '#6f685f', 'carpet': '#8e1b1b', 'wood': '#6b4526', 'trim': '#d9ab2e'},
  'dungeon': {
    'x': (_Dungeon.minX + _Dungeon.maxX) / 2,
    'z': (_Dungeon.minZ + _Dungeon.maxZ) / 2,
    'width': _round(_Dungeon.maxX - _Dungeon.minX),
    'length': _round(_Dungeon.maxZ - _Dungeon.minZ),
    'depth': 4.6,
    'stairs': {'x': 8.3, 'z': _Dungeon.minZ, 'rotY': 0, 'width': 2.2},
    'cells': [
      for (var i = 0; i < _northCells; i++)
        {
          'x': _round(_Dungeon.minX + _northW * (i + 0.5)),
          'z': _Dungeon.minZ + _cellDepth,
          'rotY': 0,
          'width': _round(_northW),
          'depth': _cellDepth,
        },
      for (var i = 0; i < _southCells; i++)
        {
          'x': _round(_Dungeon.minX + _southW * (i + 0.5)),
          'z': _Dungeon.maxZ - _cellDepth,
          'rotY': math.pi,
          'width': _round(_southW),
          'depth': _cellDepth,
        },
    ],
    'pillars': [
      for (final x in const [-7.2, -2.7, 1.8]) {'x': x, 'z': _aisleZ},
    ],
    'torches': [
      for (final x in const [-7.2, -2.7, 1.8])
        for (final side in const [-1, 1]) {'x': x, 'z': _aisleZ + side * 0.45, 'rotY': side < 0 ? math.pi : 0},
      {'x': _Dungeon.minX, 'z': _aisleZ, 'rotY': math.pi / 2},
      {'x': _Dungeon.maxX, 'z': _aisleZ + 2, 'rotY': -math.pi / 2},
    ],
    'ossuary': {'x': _Dungeon.minX + 1.3, 'z': _aisleZ},
  },
  // Sent home, a worker's dragged off to the dungeon by the Kingsguard and left there to rot.
  'sendHome': {
    'escort': {
      'name': 'Kingsguard',
      'post': {'x': 6.3, 'z': _aisleZ + 0.3, 'rotY': -math.pi / 2, 'below': true},
      'color': '#8e1b1b',
    },
    'steps': [
      {'do': 'fetch'},
      {
        'do': 'say',
        'who': 'escort',
        'text': [
          'By order of the crown, you’re coming with me.',
          'On your feet. The king’s done with you.',
          'You’re dismissed. Come quietly.',
          'Up. The dungeon’s waiting.',
        ],
      },
      {'do': 'pack'},
      {
        'do': 'say',
        'text': [
          '🙏 Mercy, my liege!',
          '😰 But my pull request…',
          '😭 I was nearly done!',
          '🥺 Just one more commit!',
          '😱 Not the dungeon!',
          '😶 …',
        ],
      },
      {'do': 'walk', 'to': 'cell'},
      {'do': 'jail'},
      {
        'do': 'say',
        'who': 'escort',
        'text': ['🔒 Rot in there.', '🔒 Enjoy your stay.', '🔒 Nobody leaves.', '🔒 Should have shipped it.'],
      },
      {'do': 'return'},
    ],
    'starveHours': 24,
    'rotHours': 12,
  },
};
