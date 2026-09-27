import 'package:office_shared/shared.dart';

const _maxSafeInteger = 9007199254740991;

/// A token or call count as JavaScript's Number.isSafeInteger(n) && n >= 0 would accept it.
bool isCount(Object? n) {
  if (n is int) return n >= 0 && n <= _maxSafeInteger;
  if (n is double) return n.isFinite && n == n.truncateToDouble() && n >= 0 && n <= _maxSafeInteger;
  return false;
}

/// Validate a provider snapshot before displaying or restoring it. Never turn invalid data into zero.
Usage? reportedUsage(Object? value) {
  if (value is! Map) return null;
  final v = value;
  if (!['input', 'output', 'cacheWrite', 'cacheRead', 'calls'].every((k) => isCount(v[k]))) return null;
  final cost = v['cost'];
  if (cost is! num || !cost.isFinite || cost < 0) return null;
  if (v['reasoning'] != null && !isCount(v['reasoning'])) return null;
  if (v['totalTokens'] != null && !isCount(v['totalTokens'])) return null;
  if (v['callsKnown'] != null && v['callsKnown'] is! bool) return null;
  if (v['incomplete'] != null && v['incomplete'] is! bool) return null;
  if (v['costKnown'] != null && v['costKnown'] is! bool) return null;
  int n(String k) => (v[k] as num).toInt();
  int? opt(String k) => v[k] == null ? null : n(k);
  return Usage(
    input: n('input'),
    output: n('output'),
    cacheWrite: n('cacheWrite'),
    cacheRead: n('cacheRead'),
    cost: cost.toDouble(),
    calls: n('calls'),
    reasoning: opt('reasoning'),
    totalTokens: opt('totalTokens'),
    callsKnown: v['callsKnown'] as bool?,
    incomplete: v['incomplete'] as bool?,
    costKnown: v['costKnown'] as bool?,
  );
}
