// A small seeded random (Mulberry32), and the 32-bit integer helpers it and the other hashes need.
// Ported from src/shared/rng.ts.

/// `Math.imul`: the low 32 bits of a * b, as a signed 32-bit int would wrap, returned unsigned
/// (0..2^32-1). Done in 16-bit halves so it stays exact on the web, where Dart ints are doubles.
int imul32(int a, int b) {
  a &= 0xffffffff;
  b &= 0xffffffff;
  final aHi = (a >> 16) & 0xffff;
  final aLo = a & 0xffff;
  final bHi = (b >> 16) & 0xffff;
  final bLo = b & 0xffff;
  final mid = ((aHi * bLo + aLo * bHi) & 0xffff) * 65536;
  return (aLo * bLo + mid) & 0xffffffff;
}

/// `x >>> 0`: [x] as an unsigned 32-bit int.
int u32(int x) => x & 0xffffffff;

/// A small seeded random (Mulberry32): the same numbers from 0 to 1, in the same order, for the same
/// seed on every machine. The scenery is laid out with it (the trees along the scenic loop, the city
/// round the roof, the Christmas trees and bats), and so are the jukebox's melodies and the DJ's
/// tracks, so everyone sees and hears the same thing. Changing it moves all of that: rng_test pins it.
double Function() mulberry32(int seed) {
  var a = u32(seed);
  return () {
    a = u32(a + 0x6d2b79f5);
    var t = a;
    t = imul32(t ^ (t >> 15), t | 1);
    t = u32(t ^ u32(t + imul32(t ^ (t >> 7), t | 61)));
    return u32(t ^ (t >> 14)) / 4294967296;
  };
}
