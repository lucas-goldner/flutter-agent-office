// Names what each worker is on: a few words and a one-line summary for the card above its head.
// A small model (Claude Haiku, through the `claude` CLI the office already needs) writes them from
// the worker's prompts and recent tool calls, told how by the 'office.namer' prompt (office_shared's
// prompts.dart). Without it, the card falls back to the prompt itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';

/// What a worker has been asked and has been doing lately.
class TaskContext {
  TaskContext({required this.prompts, required this.tools, this.previous, required this.epoch});

  List<String> prompts;
  List<String> tools;
  WorkerTask? previous;

  /// Bumped when the conversation starts over (/clear), so late answers about the old one are dropped.
  int epoch;
}

const _nameMax = 40;
const _summaryMax = 110;
const _promptMax = 600;
const _concurrency = 2;
const _debounce = Duration(milliseconds: 800);
const _timeout = Duration(seconds: 45);

/// After this many failures in a row (not signed in, no network), stop asking for a while.
const _failsBeforeBackoff = 3;
const _backoffMs = 10 * 60000;

final _schema = jsonEncode({
  'type': 'object',
  'properties': {
    'name': {'type': 'string'},
    'summary': {'type': 'string'},
  },
  'required': ['name', 'summary'],
  'additionalProperties': false,
});

class TaskNamer {
  /// [claude] is the `claude` binary, or null to only ever use the prompt as the label; [env] is
  /// the environment for it (the office's own, minus anything that marks a child session);
  /// [system] its instructions, as the office has them now (the 'office.namer' prompt).
  TaskNamer(this._claude, this._env, this._done, {String Function()? system})
    : _system = system ?? (() => prompts['office.namer']!.text);

  final String? _claude;
  final Map<String, String> _env;
  final String Function() _system;
  final void Function(String workerId, WorkerTask task, TaskContext ctx) _done;
  final _pending = <String, TaskContext>{};
  final _timers = <String, Timer>{};
  final _running = <String>{};
  var _queue = <String>[];
  var _fails = 0;
  var _pausedUntil = 0;

  bool get enabled => _claude != null && DateTime.now().millisecondsSinceEpoch >= _pausedUntil;

  /// Asks for a fresh label. Calls for the same worker close together collapse into one.
  void request(String workerId, TaskContext ctx) {
    if (!enabled || ctx.prompts.isEmpty) return;
    _pending[workerId] = ctx;
    _timers[workerId]?.cancel();
    _timers[workerId] = Timer(_debounce, () {
      _timers.remove(workerId);
      if (!_queue.contains(workerId)) _queue.add(workerId);
      _pump();
    });
  }

  void forget(String workerId) {
    _timers.remove(workerId)?.cancel();
    _pending.remove(workerId);
    _queue = _queue.where((id) => id != workerId).toList();
  }

  void _pump() {
    while (_running.length < _concurrency) {
      // One call per worker at a time; a newer request waits for it and runs after.
      final i = _queue.indexWhere((id) => !_running.contains(id));
      if (i < 0) return;
      final id = _queue.removeAt(i);
      final ctx = _pending.remove(id);
      if (ctx == null) continue;
      _running.add(id);
      _generate(ctx).then((task) {
        _running.remove(id);
        if (task != null) _done(id, task, ctx);
        _pump();
      });
    }
  }

  Future<WorkerTask?> _generate(TaskContext ctx) async {
    if (!enabled) return null;
    final out = await _run(_claude!, _env, _system(), _describe(ctx));
    final task = out == null ? null : _parse(out);
    if (task != null) {
      _fails = 0;
    } else if (++_fails >= _failsBeforeBackoff) {
      _fails = 0;
      _pausedUntil = DateTime.now().millisecondsSinceEpoch + _backoffMs;
    }
    return task;
  }
}

final _space = RegExp(r'\s+');

/// The label to show while the model is still thinking, or when there is no model: the prompt.
WorkerTask fallbackTask(String prompt) {
  final one = prompt.replaceAll(_space, ' ').trim();
  final words = one.replaceFirst(RegExp(r'^(please|can you|could you|hey|ok|so)\b[\s,]*', caseSensitive: false), '');
  final name = words.split(' ').take(4).join(' ').replaceFirst(RegExp(r'[\s,.;:!?-]+$'), '');
  return WorkerTask(name: _cap(_clip(name, _nameMax)), summary: _cap(_clip(one, _summaryMax)));
}

String _describe(TaskContext ctx) {
  final parts = <String>[];
  final previous = ctx.previous;
  if (previous != null) parts.add('Current label:\nName: ${previous.name}\nSummary: ${previous.summary}');
  final prompts = [for (var i = 0; i < ctx.prompts.length; i++) '${i + 1}. ${_clip(ctx.prompts[i], _promptMax)}'];
  parts.add('What it was asked, oldest first:\n${prompts.join('\n')}');
  if (ctx.tools.isNotEmpty) {
    parts.add('What it did most recently, oldest first:\n${ctx.tools.map((t) => '- $t').join('\n')}');
  }
  return parts.join('\n\n');
}

Future<String?> _run(String claude, Map<String, String> env, String system, String input) async {
  final args = [
    '-p',
    '--model', 'haiku',
    '--output-format', 'json',
    '--json-schema', _schema,
    '--system-prompt', system,
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
      // A neutral directory, so it doesn't pick up the project's CLAUDE.md.
      workingDirectory: Directory.systemTemp.path,
      environment: {...env, 'MAX_THINKING_TOKENS': '0'},
      includeParentEnvironment: false,
    );
  } catch (_) {
    return null;
  }
  var timedOut = false;
  final timer = Timer(_timeout, () {
    timedOut = true;
    child.kill(ProcessSignal.sigkill);
  });
  try {
    child.stderr.drain<void>().ignore();
    final out = child.stdout.transform(utf8.decoder).join();
    try {
      child.stdin.add(utf8.encode(input));
      await child.stdin.close();
    } catch (_) {
      // It may have exited without reading its input.
    }
    final text = await out;
    final code = await child.exitCode;
    return code == 0 && !timedOut ? text : null;
  } catch (_) {
    return null;
  } finally {
    timer.cancel();
  }
}

final _fence = RegExp(r'^```(json)?|```$');

WorkerTask? _parse(String out) {
  try {
    final res = jsonDecode(out);
    if (res is! Map) return null;
    final isError = res['is_error'];
    if (isError != null && isError != false) return null;
    Object? v = res['structured_output'];
    if ((v == null || v == false) && res['result'] is String) {
      v = jsonDecode((res['result'] as String).replaceAll(_fence, ''));
    }
    String field(String k) => v is Map ? '${v[k] ?? ''}' : '';
    final name = _clip(field('name').replaceAll(RegExp(r'''^["'\s]+|["'.\s]+$'''), ''), _nameMax);
    final summary = _clip(
      field('summary').replaceAll(RegExp(r'''^["'\s]+|["'\s]+$'''), '').replaceFirst(RegExp(r'\.$'), ''),
      _summaryMax,
    );
    return name.isNotEmpty && summary.isNotEmpty ? WorkerTask(name: name, summary: summary) : null;
  } catch (_) {
    return null;
  }
}

String _clip(String s, int n) {
  final one = s.replaceAll(_space, ' ').trim();
  return one.length > n ? '${one.substring(0, n - 1).trimRight()}…' : one;
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
