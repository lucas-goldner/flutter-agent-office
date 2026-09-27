// What a person looks like in the office, picked on the character select screen.
// Server and client share these lists so a look is just three small indexes on the wire.

import 'dart:math' as math;

const List<String> skinTones = ['#ffe3cc', '#ffd7b5', '#f1c27d', '#e0ac69', '#c68642', '#a0663a', '#8d5524', '#5c3a21'];
const List<String> hairColors = ['#2b2d42', '#4a3222', '#6f4e37', '#e9c46a', '#c1440e', '#d9d9d9', '#d62828', '#ff8fab', '#9d4edd', '#264653'];
const List<String> hairColorNames = ['Black', 'Dark brown', 'Brown', 'Blonde', 'Ginger', 'Silver', 'Red', 'Pink', 'Purple', 'Teal'];
const List<String> hairStyles = ['Short', 'Long', 'Bun', 'Spiky', 'Curly', 'Ponytail', 'Bald'];

class Look {
  const Look({required this.skin, required this.hair, required this.style});

  final int skin;
  final int hair;
  final int style;

  /// Reads a look off the wire; anything out of range falls back to look 0 (see [sanitizeLook]).
  factory Look.fromJson(Object? json) => sanitizeLook(json, const Look(skin: 0, hair: 0, style: 0));

  Map<String, dynamic> toJson() => {'skin': skin, 'hair': hair, 'style': style};

  @override
  bool operator ==(Object other) => other is Look && sameLook(this, other);

  @override
  int get hashCode => Object.hash(skin, hair, style);

  @override
  String toString() => 'Look(skin: $skin, hair: $hair, style: $style)';
}

/// `Math.imul`: the low 32 bits of a * b, done in 16-bit halves so it stays exact on the web,
/// where Dart ints are doubles.
int _imul(int a, int b) {
  a &= 0xffffffff;
  b &= 0xffffffff;
  final aHi = (a >> 16) & 0xffff;
  final aLo = a & 0xffff;
  final bHi = (b >> 16) & 0xffff;
  final bLo = b & 0xffff;
  final mid = ((aHi * bLo + aLo * bHi) & 0xffff) * 65536;
  return (aLo * bLo + mid) & 0xffffffff;
}

/// 32-bit FNV-1a over UTF-16 code units, as an unsigned 32-bit int (same as the TS `hash`).
int _hash(String s) {
  var h = 2166136261;
  for (var i = 0; i < s.length; i++) {
    h = _imul(h ^ s.codeUnitAt(i), 16777619);
  }
  return h & 0xffffffff;
}

/// A look picked from a seed, for people who haven't chosen one.
Look lookFromSeed(String seed) {
  final h = _hash(seed);
  return Look(skin: h % skinTones.length, hair: (h >> 3) % hairColors.length, style: (h >> 7) % hairStyles.length);
}

Look randomLook([math.Random? random]) {
  final r = random ?? math.Random();
  return Look(skin: r.nextInt(skinTones.length), hair: r.nextInt(hairColors.length), style: r.nextInt(hairStyles.length));
}

/// Coerces anything into a valid look, keeping each part of `fallback` that `x` gets wrong.
Look sanitizeLook(Object? x, Look fallback) {
  final o = x is Map ? x : const <String, dynamic>{};
  int idx(Object? v, int n, int d) => v is num && v.isFinite && v == v.truncate() && v >= 0 && v < n ? v.toInt() : d;
  return Look(
    skin: idx(o['skin'], skinTones.length, fallback.skin),
    hair: idx(o['hair'], hairColors.length, fallback.hair),
    style: idx(o['style'], hairStyles.length, fallback.style),
  );
}

bool sameLook(Look a, Look b) => a.skin == b.skin && a.hair == b.hair && a.style == b.style;
