// Tolerant JSON readers for the wire protocol. The server is the source of truth: a missing or
// mistyped field reads as a default (or null, for optional fields) and never throws.

/// A string-union type on the wire: every such enum carries its wire spelling.
abstract interface class WireEnum {
  String get wire;
}

/// The value of [values] whose `wire` is [v], or [fallback] for anything else.
T parseWire<T extends WireEnum>(List<T> values, Object? v, T fallback) {
  for (final e in values) {
    if (e.wire == v) return e;
  }
  return fallback;
}

/// Like [parseWire], but null when [v] is missing or unknown.
T? parseWireOrNull<T extends WireEnum>(List<T> values, Object? v) {
  for (final e in values) {
    if (e.wire == v) return e;
  }
  return null;
}

double asDouble(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;
double? asDoubleOrNull(Object? v) => v is num ? v.toDouble() : null;

int asInt(Object? v, [int fallback = 0]) => v is num && v.isFinite ? v.toInt() : fallback;
int? asIntOrNull(Object? v) => v is num && v.isFinite ? v.toInt() : null;

String asString(Object? v, [String fallback = '']) => v is String ? v : fallback;
String? asStringOrNull(Object? v) => v is String ? v : null;

bool asBool(Object? v, [bool fallback = false]) => v is bool ? v : fallback;
bool? asBoolOrNull(Object? v) => v is bool ? v : null;

Map<String, dynamic> asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
Map<String, dynamic>? asMapOrNull(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

List<String> asStringList(Object? v) => v is List ? [for (final e in v) if (e is String) e] : <String>[];
List<String>? asStringListOrNull(Object? v) => v is List ? asStringList(v) : null;

List<int> asIntList(Object? v) => v is List ? [for (final e in v) if (e is num && e.isFinite) e.toInt()] : <int>[];

/// Each object in the list [v] read by [read]; entries that aren't objects are skipped.
List<T> asList<T>(Object? v, T Function(Map<String, dynamic>) read) =>
    v is List ? [for (final e in v) if (e is Map) read(Map<String, dynamic>.from(e))] : <T>[];

/// Adds `key: value` to [m] unless [value] is null (JSON.stringify drops undefined the same way).
void putIfNotNull(Map<String, dynamic> m, String key, Object? value) {
  if (value != null) m[key] = value;
}
