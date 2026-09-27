import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

// Where a worker's numbers come from
// ----------------------------------
// Claude Code hooks carry no usage, but every hook payload names the session's transcript
// (~/.claude/projects/<dir>/<session>.jsonl). Each assistant message in it records the API's
// `usage` (input, output, cache write, cache read) and the model, so tokens are exact and the cost
// is priced here from PRICES. Subagents (the Agent tool) log to <session>/subagents/*.jsonl next to
// it; those are read too. When a session ends, Claude Code appends a `cost-state` line with its own
// tally — that also covers calls that never reach the transcript (titles, summaries) — and the
// worker's figures snap to it; anything logged after (a resume) is estimated on top again.
//
// The transcript format is Claude Code's own and may change: everything below is defensive, and a
// line it does not understand is skipped, never fatal.

Usage zeroUsage() => Usage.zero;

/// [a] + [b] (or [a] - [b] with sign -1), over the six counters the ledger keeps.
Usage addUsage(Usage a, Usage b, [int sign = 1]) => Usage(
  input: a.input + sign * b.input,
  output: a.output + sign * b.output,
  cacheWrite: a.cacheWrite + sign * b.cacheWrite,
  cacheRead: a.cacheRead + sign * b.cacheRead,
  cost: a.cost + sign * b.cost,
  calls: a.calls + sign * b.calls,
);

bool _isZero(Usage u) =>
    u.input == 0 && u.output == 0 && u.cacheWrite == 0 && u.cacheRead == 0 && u.cost == 0 && u.calls == 0;

/// Just the six counters (what the TS spreads), as JSON.
Map<String, dynamic> _usageJson(Usage u) => {
  'input': u.input,
  'output': u.output,
  'cacheWrite': u.cacheWrite,
  'cacheRead': u.cacheRead,
  'cost': u.cost,
  'calls': u.calls,
};

typedef Price = (double input, double output, double cacheRead);

/// USD per million tokens — [input, output, cache read] — from the Claude pricing page, checked
/// 2026-09-26. A 5-minute cache write costs 1.25x input, a 1-hour write 2x. First match wins, so
/// newer generations come before the family they belong to. A model not listed gets Opus rates:
/// a budget warning that comes early beats one that comes late.
final List<(RegExp, Price)> _prices = [
  (RegExp(r'fable-5-1|mythos-5-1'), (10, 50, 0.25)),
  (RegExp(r'fable|mythos'), (10, 50, 1)),
  (RegExp(r'opus-5-5'), (4, 20, 0.2)),
  (RegExp(r'opus-(5|4-[5-8])'), (5, 25, 0.5)),
  (RegExp(r'opus'), (15, 75, 1.5)),
  (RegExp(r'sonnet-5'), (2, 10, 0.2)),
  (RegExp(r'sonnet'), (3, 15, 0.3)),
  (RegExp(r'haiku-4'), (1, 5, 0.1)),
  (RegExp(r'haiku-3-5'), (0.8, 4, 0.08)),
  (RegExp(r'haiku'), (0.25, 1.25, 0.03)),
];
const Price _opus = (5, 25, 0.5);
const _webSearchUsd = 0.01;

Price priceOf(String model) {
  final m = model.toLowerCase();
  for (final (re, price) in _prices) {
    if (re.hasMatch(m)) return price;
  }
  return _opus;
}

double _num(Object? v) => v is num && v.isFinite && v > 0 ? v.toDouble() : 0;
int _int(Object? v) => _num(v).toInt();
Object? _get(Object? m, String k) => m is Map ? m[k] : null;

/// One assistant message's tokens, priced.
Usage usageOfMessage(String model, Object? u) {
  final input = _int(_get(u, 'input_tokens'));
  final output = _int(_get(u, 'output_tokens'));
  final cacheWrite = _int(_get(u, 'cache_creation_input_tokens'));
  final hour = math.min(cacheWrite, _int(_get(_get(u, 'cache_creation'), 'ephemeral_1h_input_tokens')));
  final cacheRead = _int(_get(u, 'cache_read_input_tokens'));
  final (pin, pout, pread) = priceOf(model);
  final cost =
      (input * pin + output * pout + (cacheWrite - hour) * pin * 1.25 + hour * pin * 2 + cacheRead * pread) / 1e6 +
      _num(_get(_get(u, 'server_tool_use'), 'web_search_requests')) * _webSearchUsd;
  return Usage(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead, cost: cost, calls: 1);
}

// ---------------------------------------------------------------------------------------------
// Per-worker tracking

class FileCursor {
  FileCursor({this.offset = 0, this.lastId, this.lastUsage});

  /// Bytes of the file already read (always at a line boundary).
  int offset;

  /// A message with several content blocks is logged once per block, with the same id and usage.
  String? lastId;
  Usage? lastUsage;

  Map<String, dynamic> toJson() => {
    'offset': offset,
    'lastId': ?lastId,
    if (lastUsage case final u?) 'lastUsage': _usageJson(u),
  };
}

class UsageTracker {
  UsageTracker({this.transcript, Map<String, FileCursor>? files, this.base, this.baseAt = 0, Usage? since, this.at})
    : files = files ?? {},
      since = since ?? Usage.zero;

  /// The session's transcript, from the hook payloads.
  String? transcript;
  final Map<String, FileCursor> files;

  /// Claude Code's own tally from the end of a session; [baseAt] is the transcript time it covers up to.
  Usage? base;
  int baseAt;

  /// Estimated from the messages logged after [base].
  Usage since;

  /// Latest transcript timestamp seen (ms since epoch).
  int? at;

  /// The shape the office saves in workers.json (and [restoreTracker] reads).
  Map<String, dynamic> toJson() => {
    'transcript': ?transcript,
    'files': {for (final e in files.entries) e.key: e.value.toJson()},
    if (base case final b?) 'base': {..._usageJson(b), 'at': baseAt},
    'since': _usageJson(since),
    'at': ?at,
  };
}

UsageTracker newTracker() => UsageTracker();

Usage trackerUsage(UsageTracker t) {
  final base = t.base;
  if (base == null) return t.since;
  return addUsage(base, t.since);
}

Usage? _asUsage(Object? v) {
  if (v is List) return Usage.zero;
  if (v is! Map) return null;
  return Usage(
    input: _int(v['input']),
    output: _int(v['output']),
    cacheWrite: _int(v['cacheWrite']),
    cacheRead: _int(v['cacheRead']),
    cost: _num(v['cost']),
    calls: _int(v['calls']),
  );
}

/// Rebuilds a tracker saved by a previous run; anything odd falls back to starting over.
UsageTracker restoreTracker(Object? saved) {
  final t = newTracker();
  if (saved is! Map) return t;
  if (saved['transcript'] is String) t.transcript = saved['transcript'] as String;
  final files = saved['files'];
  if (files is Map) {
    for (final MapEntry(:key, value: c) in files.entries) {
      if (c is! Map) continue;
      t.files['$key'] = FileCursor(
        offset: _int(c['offset']),
        lastId: c['lastId'] is String ? c['lastId'] as String : null,
        lastUsage: _asUsage(c['lastUsage']),
      );
    }
  }
  final base = _asUsage(saved['base']);
  if (base != null) {
    t.base = base;
    t.baseAt = _int(_get(saved['base'], 'at'));
  }
  t.since = _asUsage(saved['since']) ?? Usage.zero;
  if (_num(saved['at']) != 0) t.at = _int(saved['at']);
  return t;
}

/// Subagent transcripts live in `<transcript dir>/<session id>/subagents/`.
List<String> _subagentFiles(String transcript) {
  var session = p.basename(transcript);
  if (session.endsWith('.jsonl')) session = session.substring(0, session.length - '.jsonl'.length);
  return _listJsonl(p.join(p.dirname(transcript), session, 'subagents'));
}

List<String> _listJsonl(String dir) {
  try {
    final names = [
      for (final e in Directory(dir).listSync(followLinks: false))
        if (p.basename(e.path).endsWith('.jsonl')) p.basename(e.path),
    ]..sort();
    return [for (final n in names) p.join(dir, n)];
  } catch (_) {
    return [];
  }
}

/// Reads whatever was appended to the session's transcripts. True when the totals changed.
bool scanTracker(UsageTracker t) {
  final transcript = t.transcript;
  if (transcript == null) return false;
  var changed = false;
  for (final file in [transcript, ..._subagentFiles(transcript)]) {
    final cur = t.files.putIfAbsent(file, FileCursor.new);
    for (final line in _readNewLines(file, cur)) {
      Object? obj;
      try {
        obj = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (_applyLine(t, cur, obj)) changed = true;
    }
  }
  return changed;
}

bool _applyLine(UsageTracker t, FileCursor cur, Object? line) {
  if (line is! Map) return false;
  final ts = line['timestamp'];
  final at = ts is String ? DateTime.tryParse(ts)?.millisecondsSinceEpoch : null;
  if (at != null && at > (t.at ?? 0)) t.at = at;
  if (line['type'] == 'assistant') {
    final msg = line['message'];
    if (msg is! Map || msg['id'] is! String || msg['usage'] == null || msg['usage'] == false) return false;
    // Already inside Claude Code's own tally.
    if (t.base != null && at != null && at <= t.baseAt) return false;
    final model = msg['model'];
    final u = usageOfMessage(model is String ? model : '', msg['usage']);
    final lastUsage = cur.lastUsage;
    final delta = cur.lastId == msg['id'] && lastUsage != null ? addUsage(u, lastUsage, -1) : u;
    cur.lastId = msg['id'] as String;
    cur.lastUsage = u;
    if (_isZero(delta)) return false;
    t.since = addUsage(t.since, delta);
    return true;
  }
  final modelUsage = line['modelUsage'];
  final unknownCost = line['hasUnknownModelCost'];
  if (line['type'] == 'cost-state' &&
      line['totalCostUSD'] is num &&
      (modelUsage is Map || modelUsage is List) &&
      (unknownCost == null || unknownCost == false || unknownCost == 0 || unknownCost == '')) {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0;
    for (final m in modelUsage is Map ? modelUsage.values : modelUsage as List) {
      if (m is! Map) continue;
      input += _int(m['inputTokens']);
      output += _int(m['outputTokens']);
      cacheWrite += _int(m['cacheCreationInputTokens']);
      cacheRead += _int(m['cacheReadInputTokens']);
    }
    t.base = Usage(
      input: input,
      output: output,
      cacheWrite: cacheWrite,
      cacheRead: cacheRead,
      cost: _num(line['totalCostUSD']),
      calls: trackerUsage(t).calls,
    );
    t.baseAt = t.at ?? 0;
    t.since = Usage.zero;
    return true;
  }
  return false;
}

const _chunk = 4 * 1024 * 1024;

/// Complete lines appended since the cursor; a half-written last line waits for the next read.
List<String> _readNewLines(String file, FileCursor cur) {
  RandomAccessFile raf;
  try {
    raf = File(file).openSync();
  } catch (_) {
    return const [];
  }
  final lines = <String>[];
  try {
    final size = raf.lengthSync();
    if (size < cur.offset) {
      // Shorter than last time: not the file we knew. Start over.
      cur.offset = 0;
      cur.lastId = null;
      cur.lastUsage = null;
    }
    var want = _chunk;
    while (cur.offset < size) {
      final len = math.min(want, size - cur.offset);
      final buf = Uint8List(len);
      raf.setPositionSync(cur.offset);
      var got = 0;
      while (got < len) {
        final n = raf.readIntoSync(buf, got, len);
        if (n <= 0) break;
        got += n;
      }
      if (got == 0) break;
      final end = buf.lastIndexOf(10, got - 1);
      if (end < 0) {
        if (got < size - cur.offset) {
          want *= 2; // one line longer than the chunk: read more of it
          continue;
        }
        break; // the tail is still being written
      }
      final text = utf8.decode(Uint8List.sublistView(buf, 0, end), allowMalformed: true);
      cur.offset += end + 1;
      want = _chunk;
      for (final line in text.split('\n')) {
        if (line.isNotEmpty) lines.add(line);
      }
    }
  } catch (_) {
    // A read error leaves the cursor where it got to.
  } finally {
    raf.closeSync();
  }
  return lines;
}

// ---------------------------------------------------------------------------------------------
// Office-wide ledger

class LedgerOptions {
  LedgerOptions({this.budget, required this.pauseHiring});

  /// Daily budget in USD.
  double? budget;

  /// Refuse new hires for the rest of the day once the budget is spent.
  bool pauseHiring;
}

const _keepDays = 90;

String _localDay([DateTime? d]) {
  d ??= DateTime.now();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${pad(d.month)}-${pad(d.day)}';
}

String fmtUsd(num n) => '\$${n.toStringAsFixed(2)}';

final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// What the office has spent, all time and per day, so totals survive restarts and outlive the
/// workers they came from. Spend lands on the day it is read, which is the day it happened unless
/// the office was down at the time.
class Ledger {
  Ledger(String dataDir, this._opts, this._onChange, this._toast) : _file = p.join(dataDir, 'usage.json') {
    _load();
    _shownDay = _localDay();
    // Midnight: "today" starts over and a paused office hires again.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_localDay() != _shownDay) _emit();
    });
  }

  final String _file;
  final LedgerOptions _opts;
  final void Function(UsageState state) _onChange;

  /// level is 'info' or 'warn'.
  final void Function(String text, String level) _toast;
  Usage _total = Usage.zero;
  final Map<String, Usage> _days = {};
  String _warnedDay = '';
  String _shownDay = '';
  Timer? _saveTimer;
  Timer? _emitTimer;
  late final Timer _tick;

  UsageState state() {
    final day = _localDay();
    return UsageState(
      total: _total,
      today: _days[day] ?? Usage.zero,
      day: day,
      budget: _opts.budget,
      pauseHiring: _opts.pauseHiring,
    );
  }

  bool get overBudget {
    final budget = _opts.budget;
    return budget != null && (_days[_localDay()]?.cost ?? 0) >= budget;
  }

  /// Why a new agent can't be hired right now, when it can't.
  String? get hiringPaused {
    if (!_opts.pauseHiring || !overBudget) return null;
    return "Today's ${fmtUsd(_opts.budget!)} budget is spent — no new hires until tomorrow";
  }

  void add(Usage delta) {
    if (_isZero(delta)) return;
    final day = _localDay();
    _total = addUsage(_total, delta);
    _days[day] = addUsage(_days[day] ?? Usage.zero, delta);
    final keys = _days.keys.toList()..sort();
    if (keys.length > _keepDays) {
      for (final d in keys.sublist(0, keys.length - _keepDays)) {
        _days.remove(d);
      }
    }
    _save();
    _emit();
    final budget = _opts.budget;
    if (budget != null && overBudget && _warnedDay != day) {
      _warnedDay = day;
      final spent = fmtUsd(_days[day]!.cost);
      _toast(
        "💸 Today's spend passed the ${fmtUsd(budget)} budget ($spent)${_opts.pauseHiring ? ' — no new hires until tomorrow' : ''}",
        'warn',
      );
    }
  }

  void flush() {
    _tick.cancel();
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
      _write();
    }
  }

  void _emit() {
    if (_emitTimer != null) return;
    _emitTimer = Timer(const Duration(milliseconds: 200), () {
      _emitTimer = null;
      _shownDay = _localDay();
      _onChange(state());
    });
  }

  void _save() {
    if (_saveTimer != null) return;
    _saveTimer = Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      _write();
    });
  }

  void _write() {
    try {
      final json = const JsonEncoder.withIndent('  ').convert({
        'total': _usageJson(_total),
        'days': {for (final e in _days.entries) e.key: _usageJson(e.value)},
      });
      final tmp = File('$_file.tmp');
      tmp.writeAsStringSync(json);
      if (!Platform.isWindows) Process.runSync('chmod', ['600', tmp.path]);
      tmp.renameSync(_file);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _load() {
    final f = File(_file);
    if (!f.existsSync()) return;
    try {
      final saved = jsonDecode(f.readAsStringSync());
      _total = _asUsage(_get(saved, 'total')) ?? Usage.zero;
      final days = _get(saved, 'days');
      if (days is Map) {
        for (final MapEntry(:key, :value) in days.entries) {
          final usage = _asUsage(value);
          if (usage != null && key is String && _dayPattern.hasMatch(key)) _days[key] = usage;
        }
      }
    } catch (_) {
      // corrupt file: start fresh
    }
  }
}
