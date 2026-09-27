// The Claude plan limits of the account the workers run on (the 5-hour session and the week) for
// the meter under the workers in the sidebar. Claude Code answers a `get_usage` control request on
// its stream-json protocol with the numbers its /usage screen shows. Asking starts no conversation
// and costs nothing, and Claude Code deals with the sign-in (keychain, token refresh) itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';

const _pollMs = 2 * 60000;

/// Someone walking in, or clicking the meter, reads again, at most this often.
const _minGapMs = 20000;
const _timeoutMs = 30000;

/// No plan limits to show (an API key, Bedrock, Vertex, signed out): look again much later.
const _noPlanMs = 30 * 60000;

/// After this many failed reads in a row (no network, a `claude` too old to answer), wait longer.
const _failsBeforeBackoff = 3;
const _backoffMs = 10 * 60000;
const _labelMax = 24;

String _cut(String s, int max) => s.length > max ? s.substring(0, max) : s;

class PlanLimitsReader {
  /// [claude] is the `claude` binary, or null when it isn't installed (nothing is ever shown);
  /// [env] the environment for it (the office's own, minus anything that marks a child session);
  /// [wanted] whether anyone is in the office to see the numbers; polls are skipped when not.
  PlanLimitsReader(this._claude, this._env, this._wanted, this._onChange) {
    _schedule(0);
  }

  final String? _claude;
  final Map<String, String> _env;
  final bool Function() _wanted;
  final void Function(PlanLimits limits) _onChange;

  PlanLimits _limits = const PlanLimits(windows: [], at: 0);

  /// Per-model weeks from the last answer that listed them; an answer from Claude Code's cache may not.
  List<PlanWindow> _modelWeeks = [];
  Timer? _timer;
  bool _running = false;
  int _lastRead = 0;
  int _fails = 0;
  bool _closed = false;

  PlanLimits get state => _limits;

  /// Reads now, unless a read is running or one just finished.
  void refresh() {
    if (_running || DateTime.now().millisecondsSinceEpoch - _lastRead < _minGapMs) return;
    _schedule(0);
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }

  void _schedule(int ms) {
    if (_closed || _claude == null) return;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: ms), () => unawaited(_read()));
  }

  Future<void> _read() async {
    if (!_wanted()) return _schedule(_pollMs);
    _running = true;
    final answer = await _ask(_claude!, _env);
    _running = false;
    _lastRead = DateTime.now().millisecondsSinceEpoch;
    if (_closed) return;
    var next = _pollMs;
    if (answer == null) {
      if (++_fails >= _failsBeforeBackoff) {
        _fails = 0;
        next = _backoffMs;
      }
    } else {
      _fails = 0;
      _limits = parse(answer);
      if (_limits.windows.isEmpty) next = _noPlanMs;
      _onChange(_limits);
    }
    _schedule(next);
  }

  /// Claude Code's answer as the meter's windows. Visible for tests.
  PlanLimits parse(Object? answer) {
    final a = answer is Map ? answer : const {};
    final rl = a['rate_limits'];
    final sub = a['subscription_type'];
    final plan = sub is String ? _cut(sub, _labelMax) : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (a['rate_limits_available'] == false || rl is! Map) {
      _modelWeeks = [];
      return PlanLimits(plan: plan, windows: const [], at: now);
    }
    final windows = [_toWindow('5h session', rl['five_hour']), _toWindow('Week', rl['seven_day'])];
    final scoped = rl['model_scoped'];
    if (scoped is List) {
      _modelWeeks = [
        for (final m in scoped)
          if (m is Map && m['display_name'] is String && (m['display_name'] as String).trim().isNotEmpty)
            ?_toWindow('${_cut((m['display_name'] as String).trim(), _labelMax)} week', m),
      ];
    } else if (_truthy(rl['seven_day_opus']) || _truthy(rl['seven_day_sonnet'])) {
      // Claude Code before per-model buckets
      _modelWeeks = [?_toWindow('Opus week', rl['seven_day_opus']), ?_toWindow('Sonnet week', rl['seven_day_sonnet'])];
    }
    return PlanLimits(plan: plan, windows: [...windows.nonNulls, ..._modelWeeks], at: now);
  }
}

bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '';

PlanWindow? _toWindow(String label, Object? w) {
  if (w is! Map) return null;
  final u = w['utilization'];
  if (u is! num || !u.isFinite) return null;
  final r = w['resets_at'];
  final resetsAt = r is String ? DateTime.tryParse(r)?.millisecondsSinceEpoch : null;
  return PlanWindow(label: label, pct: u.toDouble().clamp(0, 100).toDouble(), resetsAt: resetsAt);
}

/// Claude Code's structured /usage answer, or null when it couldn't give one.
Future<Object?> _ask(String claude, Map<String, String> env) async {
  final args = [
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--tools', '',
    // Not the user's or the project's settings: no hooks, no MCP servers, no plugins, no transcript.
    '--setting-sources', '',
    '--strict-mcp-config',
    '--disable-slash-commands',
    '--no-session-persistence',
  ];
  Process child;
  try {
    child = await Process.start(
      claude,
      args,
      workingDirectory: Directory.systemTemp.path,
      environment: env,
      includeParentEnvironment: false,
    );
  } catch (_) {
    return null;
  }
  final done = Completer<Object?>();
  late final Timer timer;
  void finish(Object? v) {
    if (done.isCompleted) return;
    timer.cancel();
    done.complete(v);
    // No prompt was sent, so a closed stdin ends the session; a stuck one is killed.
    child.stdin.close().catchError((_) {});
    var exited = false;
    child.exitCode.then((_) => exited = true);
    Timer(const Duration(seconds: 10), () {
      if (!exited) child.kill(ProcessSignal.sigkill);
    });
  }

  timer = Timer(const Duration(milliseconds: _timeoutMs), () => finish(null));
  child.stderr.drain<void>().catchError((_) {});
  child.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          Object? msg;
          try {
            msg = jsonDecode(line);
          } catch (_) {
            return;
          }
          final res = msg is Map && msg['type'] == 'control_response' ? msg['response'] : null;
          if (res is Map && res['request_id'] == 'usage') finish(res['subtype'] == 'success' ? res['response'] : null);
        },
        onError: (_) => finish(null),
        onDone: () => finish(null),
      );
  child.stdin.done.catchError((_) {});
  child.stdin.writeln(
    jsonEncode({
      'type': 'control_request',
      'request_id': 'usage',
      'request': {'subtype': 'get_usage', 'skip_behaviors': true},
    }),
  );
  return done.future;
}
