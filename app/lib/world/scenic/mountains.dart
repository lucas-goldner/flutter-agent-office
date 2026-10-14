// The mountains to the south, the green foothills, and the spur the tunnel goes through
// (world/scenic/mountains.ts).

import 'dart:math' as math;

import 'package:office_shared/rng.dart';
import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import 'kit.dart';

enum _Band { grass, rock, dark, snow }

/// A mountain (or a green hill) with its foot [r] round (x, z) and [h] high: a lumpy, faceted cone,
/// grass at its foot, rock up its sides and, on the tall ones, snow on top. Its triangles go into
/// [out] by what they're made of, for merging.
void _mountain(Map<_Band, List<double>> out, double x, double z, double r, double h, int seed, [bool hill = false]) {
  final rand = mulberry32(seed);
  final n = r > 60 ? 14 : 11;
  const rings = 6;
  final ring = <List<vm.Vector3>>[];
  final spin = rand() * math.pi * 2;
  for (var k = 0; k < rings; k++) {
    final f = k / rings;
    final row = <vm.Vector3>[];
    for (var i = 0; i < n; i++) {
      final a = spin + ((i + (k > 0 ? (rand() - 0.5) * 0.5 : 0)) / n) * math.pi * 2;
      final rr = r * math.pow(1 - f, hill ? 0.7 : 1.1) * (k > 0 ? 0.82 + rand() * 0.3 : 1);
      final y = k > 0 ? h * f * (0.9 + rand() * 0.18) : -0.6;
      row.add(vm.Vector3(x + math.cos(a) * rr, G + y, z + math.sin(a) * rr));
    }
    ring.add(row);
  }
  final peak = vm.Vector3(x + (rand() - 0.5) * r * 0.12, G + h, z + (rand() - 0.5) * r * 0.12);
  final snowline = h * (0.58 + rand() * 0.08);
  void tri(vm.Vector3 a, vm.Vector3 b, vm.Vector3 c) {
    final y = (a.y + b.y + c.y) / 3 - G;
    final band = hill
        ? (y > h * 0.55 && rand() < 0.5 ? _Band.dark : _Band.grass)
        : h > 90 && y > snowline + (rand() - 0.5) * h * 0.08
        ? _Band.snow
        : y < h * 0.15
        ? _Band.grass
        : rand() < 0.5
        ? _Band.rock
        : _Band.dark;
    // Wound so they face out (and up).
    out[band]!.addAll([a.x, a.y, a.z, c.x, c.y, c.z, b.x, b.y, b.z]);
  }

  for (var k = 0; k < rings; k++) {
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      if (k == rings - 1) {
        tri(ring[k][i], ring[k][j], peak);
        continue;
      }
      tri(ring[k][i], ring[k][j], ring[k + 1][i]);
      tri(ring[k][j], ring[k + 1][j], ring[k + 1][i]);
    }
  }
}

/// The mountains, the foothills and the spur's shoulders, merged by what they're made of.
void buildMountains(ScenicKit kit) {
  final tris = {for (final b in _Band.values) b: <double>[]};
  for (var k = 0; k < mountains.length; k++) {
    final (x, z, r, h) = mountains[k];
    _mountain(tris, x, z, r, h, 100 + k);
    kit.colliders.add(
      Collider(
        minX: x - r * 0.55,
        maxX: x + r * 0.55,
        minZ: z - r * 0.55,
        maxZ: z + r * 0.55,
        bottom: G - 1,
        top: G + 1000,
      ),
    );
    kit.take(x, z, r * 0.9);
  }
  for (var k = 0; k < foothills.length; k++) {
    final (x, z, r, h) = foothills[k];
    _mountain(tris, x, z, r, h, 200 + k, true);
    kit.colliders.add(
      Collider(
        minX: x - r * 0.45,
        maxX: x + r * 0.45,
        minZ: z - r * 0.45,
        maxZ: z + r * 0.45,
        bottom: G - 1,
        top: G + 1000,
      ),
    );
    kit.take(x, z, r * 0.8);
  }
  // The shoulders of rock either side of each end of the tunnel.
  final spurs = [
    (Tunnel.x0 + 1, Tunnel.z - 22, 12.0, 17.0),
    (Tunnel.x0 + 2, Tunnel.z + 27, 15.0, 26.0),
    (Tunnel.x1 - 1, Tunnel.z - 22, 12.0, 16.0),
    (Tunnel.x1 - 2, Tunnel.z + 27, 15.0, 27.0),
  ];
  for (var k = 0; k < spurs.length; k++) {
    final (x, z, r, h) = spurs[k];
    _mountain(tris, x, z, r, h, 300 + k);
  }
  const colors = {_Band.grass: '#6a994e', _Band.rock: '#8e8aa0', _Band.dark: '#77738a', _Band.snow: '#f4f7fb'};
  for (final b in _Band.values) {
    if (tris[b]!.isEmpty) continue;
    // Never culled: they're what shows over the haze.
    kit.root.add(Loose(faceted(tris[b]!), Coat.plain(colors[b]!), shadow: true));
  }
}
