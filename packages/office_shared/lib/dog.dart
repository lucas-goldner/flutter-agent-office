// The office dog. Every floor has one. The server decides what it does (see server/dog.ts) and sends
// one DogState per leg of its day. Every browser works out from that state where the dog is at any
// moment, so everyone on the floor sees it in the same spot without a stream of moves.

import 'dart:math' as math;

import 'json_util.dart';
import 'nav.dart' show Pt;

/// What the dog does once it gets where it's going.
enum DogAct implements WireEnum {
  stand('stand'),
  sit('sit'),
  lie('lie'),
  nap('nap'),
  sniff('sniff'),
  bark('bark'),
  wag('wag');

  const DogAct(this.wire);
  @override
  final String wire;

  static DogAct parse(Object? v) => parseWire(values, v, DogAct.stand);
}

List<Pt> _readPath(Object? v) => v is List
    ? [
        for (final p in v)
          if (p is List && p.length >= 2 && p[0] is num && p[1] is num) ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ]
    : <Pt>[];

class DogState {
  const DogState({
    required this.name,
    required this.coat,
    required this.path,
    required this.speed,
    required this.elapsed,
    required this.act,
    this.face,
    this.workerId,
    this.following,
    this.petBy,
  });

  factory DogState.fromJson(Map<String, dynamic> j) => DogState(
        name: asString(j['name']),
        coat: asInt(j['coat']),
        path: _readPath(j['path']),
        speed: asDouble(j['speed']),
        elapsed: asDouble(j['elapsed']),
        act: DogAct.parse(j['act']),
        face: asDoubleOrNull(j['face']),
        workerId: asStringOrNull(j['workerId']),
        following: asStringOrNull(j['following']),
        petBy: asStringOrNull(j['petBy']),
      );

  final String name;

  /// Which of [dogCoats] it wears.
  final int coat;

  /// This leg: from where it was when the leg began, on through each point in turn. Never empty.
  final List<Pt> path;

  /// Meters per second along the path.
  final double speed;

  /// How long ago the leg began, in ms, as of when the server sent it.
  final double elapsed;
  final DogAct act;

  /// Which way it faces once it's there (rotation around y; 0 looks down +z).
  final double? face;

  /// Barking: the worker that needs input. Napping: the worker whose desk it's under.
  final String? workerId;

  /// The person it's trotting after.
  final String? following;

  /// Wagging: who just petted it.
  final String? petBy;

  Map<String, dynamic> toJson() => {
        'name': name,
        'coat': coat,
        'path': [for (final (x, z) in path) [x, z]],
        'speed': speed,
        'elapsed': elapsed,
        'act': act.wire,
        'face': ?face,
        'workerId': ?workerId,
        'following': ?following,
        'petBy': ?petBy,
      };
}

const int dogNameMax = 24;

/// A new floor's dog is called one of these until someone names it in ⚙️ Settings (none is a worker's name).
const List<String> dogNames = ['Biscuit', 'Pancake', 'Peanut', 'Pepper', 'Cookie', 'Bagel', 'Ziggy', 'Pretzel', 'Maple', 'Scout'];

/// Coats: [body, belly and muzzle, ears].
const List<(String, String, String)> dogCoats = [
  ('#e0a458', '#fff1d6', '#b36f35'), // golden
  ('#3b3d4f', '#ffffff', '#23242f'), // black and white
  ('#8a5a3b', '#f0d2b0', '#5e3a24'), // chocolate
  ('#f3dcb0', '#fffaf0', '#d9a066'), // cream
  ('#a4acb6', '#f4f6f8', '#6f7884'), // grey
  ('#cf6a45', '#fbe1d2', '#9c4527'), // red
];

/// Once it gets to a desk whose worker needs input, it barks this often...
const int barkEveryS = 14;

/// ...for this long, then sits there quietly (still pointing) until someone answers.
const int barkForS = 120;

/// A name for a floor's dog, and a coat, picked from its id so it keeps them.
({String name, int coat}) dogDefaults(String floorId) {
  var h = 0;
  // Like `for (const ch of floorId) ch.charCodeAt(0)`: the first UTF-16 unit of each code point.
  for (final rune in floorId.runes) {
    final unit = rune > 0xffff ? 0xd800 + ((rune - 0x10000) >> 10) : rune;
    h = (h * 31 + unit) % 0x100000000;
  }
  return (name: dogNames[h % dogNames.length], coat: (h >> 8) % dogCoats.length);
}

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');

/// Takes control characters out and trims to [dogNameMax]; '' when nothing's left.
String cleanDogName(String raw) {
  var s = raw.replaceAll(_controlChars, '').trim();
  if (s.length > dogNameMax) s = s.substring(0, dogNameMax);
  return s.trim();
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

double pathLength(List<Pt> path) {
  var len = 0.0;
  for (var i = 1; i < path.length; i++) {
    len += _hypot(path[i].$1 - path[i - 1].$1, path[i].$2 - path[i - 1].$2);
  }
  return len;
}

/// Seconds from the start of the leg until it arrives.
double legSeconds(List<Pt> path, double speed) => speed > 0 ? pathLength(path) / speed : 0;

class DogPose {
  const DogPose({required this.x, required this.z, required this.heading, required this.moving});

  final double x;
  final double z;

  /// Which way it's facing (rotation around y).
  final double heading;

  /// Still on its way.
  final bool moving;

  @override
  String toString() => 'DogPose(x: $x, z: $z, heading: $heading, moving: $moving)';
}

/// Where the dog is `t` seconds into its leg, and which way it faces.
DogPose dogAt(DogState s, double t) => dogAtLeg(s.path, s.speed, s.face, t);

/// [dogAt] from the parts of a [DogState] it needs.
DogPose dogAtLeg(List<Pt> p, double speed, double? face, double t) {
  var left = math.max(0.0, t) * speed;
  var heading = face ?? 0.0;
  for (var i = 1; i < p.length; i++) {
    final dx = p[i].$1 - p[i - 1].$1;
    final dz = p[i].$2 - p[i - 1].$2;
    final len = _hypot(dx, dz);
    if (len < 1e-6) continue;
    heading = math.atan2(dx, dz);
    if (left < len) {
      final k = left / len;
      return DogPose(x: p[i - 1].$1 + dx * k, z: p[i - 1].$2 + dz * k, heading: heading, moving: true);
    }
    left -= len;
  }
  final (x, z) = p.isEmpty ? (0.0, 0.0) : p.last;
  return DogPose(x: x, z: z, heading: face ?? heading, moving: false);
}
