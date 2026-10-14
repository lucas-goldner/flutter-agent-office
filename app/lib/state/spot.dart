// Where you were standing, to come back to (state/persist.ts Spot, lastSpot, rememberSpot): saved every
// second and as the page goes, next to the floor, and sent with the floor when the page connects (#153).

import 'dart:convert';

import '../interop/browser.dart' show storageGet, storageSet;

const _spotKey = 'agent-office.spot';

/// Where you were standing, on which floor (or the roof), to be back there when you come back in.
class SavedSpot {
  const SavedSpot({
    required this.floor,
    this.name = '',
    this.map,
    this.throne = false,
    required this.x,
    required this.y,
    required this.z,
    required this.facing,
  });

  final String floor;

  /// What that floor was called, to say so if it's gone by then.
  final String name;

  /// The building's map then (see shared maps): a spot on another map is nowhere on this one.
  final String? map;

  /// Sitting on its throne.
  final bool throne;
  final double x, y, z, facing;

  Map<String, Object?> toJson() => {
    'floor': floor,
    'name': name,
    'map': ?map,
    if (throne) 'throne': true,
    'x': x,
    'y': y,
    'z': z,
    'facing': facing,
  };

  static SavedSpot? fromJson(Object? s) {
    bool finite(Object? v) => v is num && v.isFinite;
    if (s is! Map || s['floor'] is! String || (s['floor'] as String).isEmpty) return null;
    if (!finite(s['x']) || !finite(s['y']) || !finite(s['z']) || !finite(s['facing'])) return null;
    return SavedSpot(
      floor: s['floor'] as String,
      name: s['name'] is String ? s['name'] as String : '',
      map: s['map'] is String ? s['map'] as String : null,
      throne: s['throne'] == true,
      x: (s['x'] as num).toDouble(),
      y: (s['y'] as num).toDouble(),
      z: (s['z'] as num).toDouble(),
      facing: (s['facing'] as num).toDouble(),
    );
  }
}

/// The spot you were last in, if this browser has one.
SavedSpot? lastSpot() {
  try {
    return SavedSpot.fromJson(jsonDecode(storageGet(_spotKey) ?? 'null'));
  } catch (_) {
    return null; // storage blocked or garbage
  }
}

void rememberSpot(SavedSpot s) => storageSet(_spotKey, jsonEncode(s.toJson()));
