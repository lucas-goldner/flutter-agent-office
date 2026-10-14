// Checking what a map's file says (see planMap in maps.dart): nothing in it is taken on trust, and
// whatever's wrong is said in words for Settings. Ported from src/shared/maps/check.ts.

/// A map that can't be used: why, in words for Settings.
class MapError implements Exception {
  const MapError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether [v] is a JSON object (not a list, not null).
bool isObj(Object? v) => v is Map;

/// [v] as a JSON object, keyed by strings.
Map<String, dynamic> objOf(Object? v) => Map<String, dynamic>.from(v! as Map);

/// JS's `String(n)` for a bound in an error message: whole numbers without ".0".
String jsNum(num n) => n == n.truncate() && n.abs() < 1e21 ? '${n.truncate()}' : '$n';

/// [v] as a number between [min] and [max], or a [MapError] saying what [what] should be (TS num).
double checkNum(Object? v, String what, [num min = -1e4, num max = 1e4]) {
  if (v is! num || !v.isFinite) throw MapError('$what should be a number');
  if (v < min || v > max) throw MapError('$what should be between ${jsNum(min)} and ${jsNum(max)}');
  return v.toDouble();
}

/// [v] as some text, trimmed to [max] characters, or a [MapError] (TS str).
String checkStr(Object? v, String what, [int max = 80]) {
  if (v is! String || v.trim().isEmpty) throw MapError('$what should be some text');
  final t = v.trim();
  return t.length > max ? t.substring(0, max) : t;
}

/// `n.toFixed(1)`, as error messages print a position.
String fixed1(double n) => n.toStringAsFixed(1);
