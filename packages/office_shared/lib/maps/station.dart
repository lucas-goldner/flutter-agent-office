// The space station: a long pressurised deck in orbit, the Earth rolling by outside its windows. At
// the forward end is the bridge, a raised deck under a wall of glass with the captain's chair on it,
// where you sit; the workers sit at the benches down both sides, and line up before the chair when
// they're done or need you. The First Officer stands at your left and brings a new worker aboard
// when you speak to them. The boards are displays on the side walls, a board agent at a console
// under each. Aft is the hatch workers come in through, and in the starboard wall, between two big
// observation windows, the airlock: a worker sent home is marched to it by Security and blown out
// into space, and everyone ever ejected is still adrift out there, to be seen from those windows.
//
// It's all data, like the castle (castle.dart): moving something is changing a number here, or a
// map of your own that `extends: 'station'` in the office's .agent-office/maps/ (docs/maps.md).
//
// The deck runs forward (-z, the bridge) to aft (+z, the hatch); x is across it, port (-x) to starboard.
// Ported from src/shared/maps/station.ts.

import 'dart:math' as math;

import 'types.dart';

const double _w = 30;
const double _l = 58;
const double _h = 7.6;

/// Just off the inside of each side wall.
const double _wallX = _w / 2 - 0.08;

/// The benches' rows, either side of the middle of the deck.
const double _benchX = 7.6;

/// Where the boards hang along the side walls, and the windows between and beyond them.
const List<double> _boardsZ = [-14, -3];
const List<(double z, double width)> _sideWindows = [(-21, 5), (-8.5, 4), (7, 6), (19.5, 6)];

/// The airlock, in the starboard wall between its two observation windows.
const double _airlockZ = 13;
double _facing(int side) => side < 0 ? math.pi / 2 : -math.pi / 2;

List<Map<String, dynamic>> _props() => [
  // The hull's ribs, clear of the windows and the boards.
  for (final z in const [-26, -17.4, -11.15, -5.85, 1.5, 15.6, 24]) {'kind': 'rib', 'x': 0, 'z': z},
  // The bridge's wall of glass, forward, and the windows down both sides.
  for (final x in const [-8.6, 0, 8.6])
    {'kind': 'viewport', 'x': x, 'z': -_l / 2, 'y': 1.5, 'width': 7.6, 'height': 4.6, 'rotY': 0},
  for (final (z, width) in _sideWindows)
    for (final side in const [-1, 1])
      {
        'kind': 'viewport',
        'x': side * (_w / 2),
        'z': z,
        'y': 1.1,
        'width': width,
        'height': 3.8,
        'rotY': _facing(side),
      },
  // Light: pods over the bridge, the benches and the hatch, and strips in the deck down the middle.
  {'kind': 'lamp', 'x': 0, 'z': -24.5, 'y': _h - 0.9, 'light': true},
  for (final z in const [-8, 6])
    for (final side in const [-1, 1]) {'kind': 'lamp', 'x': side * _benchX, 'z': z, 'y': _h - 0.9, 'light': true},
  {'kind': 'lamp', 'x': 0, 'z': 21, 'y': _h - 0.9, 'light': true},
  for (final z in const [-15, 8]) {'kind': 'lamp', 'x': 0, 'z': z, 'y': _h - 0.9},
  for (final side in const [-1, 1]) {'kind': 'strip', 'x': side * 2.4, 'z': 3.3, 'width': 0.3, 'length': 46},
  // A holo-table in the middle of the deck, the Earth turning over it.
  {'kind': 'hologram', 'x': 0, 'z': -1},
  // Displays: across from the airlock, and either side of the hatch.
  {'kind': 'screen', 'x': -_wallX, 'z': _airlockZ, 'y': 2.9, 'width': 4, 'height': 2.2, 'rotY': math.pi / 2},
  for (final side in const [-1, 1])
    {'kind': 'screen', 'x': side * 6.4, 'z': _l / 2 - 0.08, 'y': 2.8, 'width': 3.2, 'height': 1.8, 'rotY': math.pi},
  // Something green under a window each side, cargo by the hatch.
  for (final side in const [-1, 1]) {'kind': 'planter', 'x': side * (_w / 2 - 0.45), 'z': -8.5, 'rotY': _facing(side)},
  {'kind': 'crate', 'x': -5.6, 'z': 27.6},
  {'kind': 'crate', 'x': -7.3, 'z': 27.5, 'scale': 0.75, 'rotY': 0.4},
  {'kind': 'crate', 'x': 5.3, 'z': 27.7, 'rotY': -0.2},
  // The merge gong, port of the bridge; something hot to drink, aft.
  {'kind': 'gong', 'x': -9.6, 'z': -19.6, 'rotY': math.pi / 2},
  {'kind': 'dispenser', 'x': -_w / 2 + 0.45, 'z': 25.5, 'rotY': math.pi / 2},
];

/// The space station (TS STATION).
final MapConfig stationMap = {
  'id': 'station',
  'name': 'Space station',
  'icon': '🚀',
  'description':
      'A space station in orbit, the Earth rolling by outside its windows. Workers sit at the benches down either side and line up before your captain’s chair on the bridge when they’re done or need you. Speak to the First Officer to bring a new one aboard; send one home, and Security marches it to the airlock and blows it out into space, where everyone ever ejected is still adrift.',
  'style': 'station',
  'hall': {'width': _w, 'length': _l, 'height': _h},
  'spawn': {'x': -2.6, 'z': -17.5, 'rotY': math.pi},
  'door': {'x': 0, 'z': _l / 2 - 1.4},
  // The bridge: a raised deck right up to the forward windows, the captain's chair on it.
  'throne': {
    'x': 0,
    'z': -24.2,
    'rotY': 0,
    'dais': {'width': 14, 'depth': 7.2, 'height': 0.6, 'steps': 2},
    'label': '🚀 Captain’s chair',
  },
  'herald': {
    'x': 3.2,
    'z': -23.2,
    'rotY': -0.35,
    'name': 'First Officer',
    'says': 'Speak to me to bring a new worker aboard',
    'ask': 'What’s their mission, Captain?',
    'button': 'Make it so 🚀',
  },
  'lineup': {
    'x': 0,
    'z': -22.4,
    'rotY': math.pi,
    'step': [0, 1.3],
    'count': 8,
  },
  'tables': [
    {'name': 'Port forward bench', 'x': -_benchX, 'z': -8, 'length': 10, 'seats': 4},
    {'name': 'Starboard forward bench', 'x': _benchX, 'z': -8, 'length': 10, 'seats': 4},
    {'name': 'Port aft bench', 'x': -_benchX, 'z': 6, 'length': 10, 'seats': 4},
    {'name': 'Starboard aft bench', 'x': _benchX, 'z': 6, 'length': 10, 'seats': 4},
  ],
  'stations': {
    'issues': {'x': -13.2, 'z': _boardsZ[0], 'rotY': -math.pi / 2},
    'queue': {'x': -13.2, 'z': _boardsZ[1], 'rotY': -math.pi / 2},
    'pulls': {'x': 13.2, 'z': _boardsZ[0], 'rotY': math.pi / 2},
  },
  // The build tower on the starboard side, under its window.
  'fixtures': {
    'build': {'x': 14.3, 'z': 5, 'rotY': math.pi / 2},
  },
  // The briefing table, aft on the starboard side.
  'council': {'x': 10, 'z': 24.8, 'rotY': math.pi},
  'boards': {
    'issues': {
      'x': -_wallX,
      'y': 3.3,
      'z': _boardsZ[0],
      'rotY': math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '📡 Incoming signals',
    },
    'queue': {
      'x': -_wallX,
      'y': 3.3,
      'z': _boardsZ[1],
      'rotY': math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '📋 Mission queue',
    },
    'pulls': {
      'x': _wallX,
      'y': 3.3,
      'z': _boardsZ[0],
      'rotY': -math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '🔀 Docking requests',
    },
    'services': {
      'x': _wallX,
      'y': 3.3,
      'z': _boardsZ[1],
      'rotY': -math.pi / 2,
      'width': 4.4,
      'height': 2.6,
      'label': '🌐 Subsystems',
    },
  },
  'props': _props(),
  'agents': {'outfit': 'none', 'ageMinutes': 0},
  'palette': {'hull': '#dfe5ee', 'deck': '#3d4858', 'panel': '#aeb8c8', 'metal': '#56627a', 'glow': '#35d6ff'},
  'airlock': {'x': _w / 2 - 0.4, 'z': _airlockZ},
  // Sent home, a worker's marched to the airlock by Security and blown out into space, for good.
  'sendHome': {
    'escort': {
      'name': 'Security',
      'post': {'x': 13.3, 'z': _airlockZ + 2.3, 'rotY': -math.pi / 2},
      'color': '#27313f',
    },
    'steps': [
      {'do': 'fetch'},
      {
        'do': 'say',
        'who': 'escort',
        'text': [
          'Captain’s orders. You’re off the crew.',
          'On your feet. Your shift ends at the airlock.',
          'You’ve been reassigned. To space.',
          'Come quietly. Mind the vacuum.',
        ],
      },
      {'do': 'pack'},
      {
        'do': 'say',
        'text': [
          '😨 Not the airlock!',
          '😰 But my pull request…',
          '😭 I was nearly done!',
          '🥺 Just one more commit!',
          '🫠 I didn’t pack a suit…',
          '😶 …',
        ],
      },
      {'do': 'walk', 'to': 'airlock'},
      {'do': 'eject'},
      {
        'do': 'say',
        'who': 'escort',
        'text': ['🚀 Bon voyage.', '🫡 Thank you for your service.', '🌌 Mind the gap.', '👋 Should have shipped it.'],
      },
      {'do': 'return'},
    ],
    'starveHours': 1,
    'rotHours': 12,
  },
};
