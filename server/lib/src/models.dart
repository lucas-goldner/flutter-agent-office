// The models a provider's own CLI lists, for the hire dialog: what each is called and which
// reasoning efforts it takes, where the CLI says. Each is asked without a shell, and only what
// looks like a model gets through. Ported from upstream's src/server/models.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:office_shared/shared.dart';

/// A CLI that lists its models in a second or two takes ten times that on a busy machine.
const modelCommandTimeoutMs = 30000;
const modelCommandMaxBuffer = 1024 * 1024;

/// A catalogue with every model's details in it (Codex's, OpenCode's --verbose) runs to several hundred KB.
const modelDetailsMaxBuffer = 16 * 1024 * 1024;
const modelCacheTtlMs = 60000;
const _nameMax = 80;

class ModelCommandOptions {
  const ModelCommandOptions({required this.cwd, required this.timeout, required this.maxBuffer});

  final String cwd;

  /// Milliseconds before the command is killed.
  final int timeout;

  /// Bytes of output before the command is given up on.
  final int maxBuffer;

  @override
  bool operator ==(Object other) =>
      other is ModelCommandOptions && other.cwd == cwd && other.timeout == timeout && other.maxBuffer == maxBuffer;

  @override
  int get hashCode => Object.hash(cwd, timeout, maxBuffer);

  @override
  String toString() => 'ModelCommandOptions(cwd: $cwd, timeout: $timeout, maxBuffer: $maxBuffer)';
}

typedef ModelCommandResult = ({String stdout, String stderr});

typedef ModelCommandRunner =
    Future<ModelCommandResult> Function(String file, List<String> args, ModelCommandOptions options);

/// Runs a command without a shell, reading its output to the end (upstream writes it to a file, as a
/// Node child that exits with output still in a pipe loses the end of it): fails on a non-zero exit,
/// a timeout, or output past maxBuffer.
Future<ModelCommandResult> _runModelCommand(String file, List<String> args, ModelCommandOptions options) async {
  final proc = await Process.start(file, args, workingDirectory: options.cwd);
  proc.stdin.close().ignore();
  proc.stderr.drain<void>().ignore();
  var failed = false;
  void fail() {
    if (failed) return;
    failed = true;
    proc.kill(ProcessSignal.sigkill);
  }

  final timer = Timer(Duration(milliseconds: options.timeout), fail);
  try {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in proc.stdout) {
      if (failed) continue;
      bytes.add(chunk);
      if (bytes.length > options.maxBuffer) fail();
    }
    final code = await proc.exitCode;
    if (failed || code != 0) throw ProcessException(file, args, 'command failed', code);
    return (stdout: utf8.decode(bytes.takeBytes(), allowMalformed: true), stderr: '');
  } finally {
    timer.cancel();
  }
}

final _ansi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
String _plain(String text) => text.replaceAll(_ansi, '');
final _lines = RegExp(r'\r?\n');
final _bullet = RegExp(r'^[-*]\s+');

/// A model's name as its catalogue gives it, when it's one a window can show and says more than the id.
String? _shownName(Object? value, String id) {
  if (value is! String) return null;
  final name = value.replaceAll(RegExp(r'[\p{Cc}\p{Cf}]', unicode: true), '').trim();
  return name.isNotEmpty && name != id && name.length <= _nameMax ? name : null;
}

/// The office's efforts among [levels] (a catalogue may know others: "none", "ultra"), in the office's order.
List<AgentEffort> _knownEfforts(Iterable<Object?> levels) {
  final set = levels.toSet();
  return [
    for (final e in agentEfforts)
      if (set.contains(e.wire)) e,
  ];
}

/// Each model once, in the order the catalogue gave them.
List<ModelOption> _unique(Iterable<ModelOption> models) {
  final seen = <String>{};
  return [
    for (final m in models)
      if (seen.add(m.id)) m,
  ];
}

/// `opencode models --verbose`: each model's id on a line of its own, then its details as JSON, of
/// which the office takes its name and its variants (OpenCode's reasoning efforts).
List<ModelOption> _openCodeDetails(String stdout) {
  final models = <ModelOption>[];
  String? id;
  var json = <String>[];
  void close() {
    final at = id;
    if (at == null) return;
    Object? details;
    try {
      details = jsonDecode(json.join('\n'));
    } catch (_) {
      details = null;
    }
    final variants = details is Map && details['variants'] is Map ? (details['variants'] as Map).keys.toList() : null;
    final name = _shownName(details is Map ? details['name'] : null, at);
    models.add(ModelOption(id: at, name: name, efforts: variants != null ? _knownEfforts(variants) : null));
  }

  for (final line in _plain(stdout).split(_lines)) {
    // Its JSON is indented, but for the braces around it: anything else at the margin is the next id.
    if (line.isEmpty || RegExp(r'^[{}\s]').hasMatch(line)) {
      json.add(line);
      continue;
    }
    close();
    id = isValidOpenCodeModel(line.trim()) ? line.trim() : null;
    json = [];
  }
  close();
  return _unique(models);
}

/// Run `opencode models` without a shell and return only safe, model-shaped lines: with their
/// details, from an OpenCode that gives them.
Future<List<ModelOption>> fetchOpenCodeModels(String command, String cwd, [ModelCommandRunner? runner]) async {
  final run = runner ?? _runModelCommand;
  try {
    List<ModelOption> detailed;
    try {
      final result = await run(command, [
        'models',
        '--verbose',
      ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelDetailsMaxBuffer));
      detailed = _openCodeDetails(result.stdout);
    } catch (_) {
      detailed = const [];
    }
    if (detailed.isNotEmpty) return detailed;
    final result = await run(command, [
      'models',
    ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelCommandMaxBuffer));
    return _unique([
      for (final raw in _plain(result.stdout).split(_lines))
        if (raw.trim().replaceFirst(_bullet, '') case final id when isValidOpenCodeModel(id)) ModelOption(id: id),
    ]);
  } catch (_) {
    throw StateError('OpenCode model catalogue unavailable');
  }
}

/// Run `grok models` without a shell and return only safe model ids.
Future<List<ModelOption>> fetchGrokModels(String command, String cwd, [ModelCommandRunner? runner]) async {
  try {
    final result = await (runner ?? _runModelCommand)(command, [
      'models',
    ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelCommandMaxBuffer));
    return _unique([
      for (final raw in _plain(result.stdout).split(_lines))
        if (raw
                .trim()
                .replaceFirst(_bullet, '')
                .replaceFirst(RegExp(r'\s*\(default\)\s*$', caseSensitive: false), '')
                .trim()
            case final id when isValidGrokModel(id))
          ModelOption(id: id),
    ]);
  } catch (_) {
    throw StateError('Grok model catalogue unavailable');
  }
}

/// Run `codex debug models` without a shell: Codex's catalogue as JSON, of which the office takes
/// the models its own picker lists, what each is called and the reasoning efforts it supports.
Future<List<ModelOption>> fetchCodexModels(String command, String cwd, [ModelCommandRunner? runner]) async {
  try {
    final result = await (runner ?? _runModelCommand)(command, [
      'debug',
      'models',
    ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelDetailsMaxBuffer));
    final parsed = jsonDecode(result.stdout);
    final listed = parsed is Map ? parsed['models'] : null;
    if (listed is! List) throw const FormatException('no models');
    final models = <ModelOption>[];
    for (final m in listed) {
      if (m is! Map || !isValidCodexModel(m['slug'])) continue;
      if (m.containsKey('visibility') && m['visibility'] != 'list') continue;
      final slug = m['slug'] as String;
      final levels = m['supported_reasoning_levels'];
      models.add(
        ModelOption(
          id: slug,
          name: _shownName(m['display_name'], slug),
          efforts: levels is List ? _knownEfforts([for (final l in levels) l is Map ? l['effort'] : null]) : null,
        ),
      );
    }
    return _unique(models);
  } catch (_) {
    throw StateError('Codex model catalogue unavailable');
  }
}

/// Run `cursor-agent models` without a shell and return only safe model ids, each with its name. It
/// prints one model a line, `<id> - <name>`, with `(current)` or `(default)` after some, under a
/// heading and over a tip.
Future<List<ModelOption>> fetchCursorModels(String command, String cwd, [ModelCommandRunner? runner]) async {
  try {
    final result = await (runner ?? _runModelCommand)(command, [
      'models',
    ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelCommandMaxBuffer));
    final models = <ModelOption>[];
    final row = RegExp(r'^\S+(?: - (.*?))?(?: \((?:current|default)[^)]*\))?$');
    for (final raw in _plain(result.stdout).split(_lines)) {
      final line = raw.trim();
      final id = line.split(RegExp(r'\s')).first;
      // The heading, the tip and "No models available" are sentences: a model's line is its id
      // alone, or its id, " - " and its name.
      final listed = row.firstMatch(line);
      if (listed == null || !isValidCursorModel(id)) continue;
      models.add(ModelOption(id: id, name: _shownName(listed.group(1), id)));
    }
    return _unique(models);
  } catch (_) {
    throw StateError('Cursor model catalogue unavailable');
  }
}

typedef ModelLister = Future<List<ModelOption>> Function(String command, String cwd, [ModelCommandRunner? runner]);

/// The providers whose CLI lists its models (ModelField.catalog), and how each is asked.
const Map<AgentProvider, ModelLister> modelListers = {
  AgentProvider.opencode: fetchOpenCodeModels,
  AgentProvider.codex: fetchCodexModels,
  AgentProvider.grok: fetchGrokModels,
  AgentProvider.cursor: fetchCursorModels,
};

abstract interface class ModelCatalogue {
  Future<List<ModelOption>> get();
}

/// One provider's models: asked for once however many ask at the same time, and kept. A list older
/// than a minute is still what the next asker gets, at once, while the CLI is asked again for the
/// one after: the models seldom change, and the CLI can take its time.
ModelCatalogue createModelCatalogue(Future<List<ModelOption>> Function() list, [int Function()? now]) =>
    _Catalogue(list, now ?? () => DateTime.now().millisecondsSinceEpoch);

class _Catalogue implements ModelCatalogue {
  _Catalogue(this.list, this.now);

  final Future<List<ModelOption>> Function() list;
  final int Function() now;
  List<ModelOption>? _cached;
  int _expiresAt = 0;
  Future<List<ModelOption>>? _pending;

  Future<List<ModelOption>> _refresh() => _pending ??= list()
      .then((models) {
        _cached = models;
        _expiresAt = now() + modelCacheTtlMs;
        return [...models];
      })
      .whenComplete(() => _pending = null);

  @override
  Future<List<ModelOption>> get() {
    final cached = _cached;
    if (cached == null) return _refresh();
    // One that can't be listed any more leaves the last list standing.
    if (now() >= _expiresAt) _refresh().ignore();
    return Future.value([...cached]);
  }
}

/// Every provider's catalogue, for an office whose [command] runs that provider's CLI in [cwd].
Map<AgentProvider, ModelCatalogue> createModelCatalogues(String Function(AgentProvider provider) command, String cwd) =>
    {for (final e in modelListers.entries) e.key: createModelCatalogue(() => e.value(command(e.key), cwd))};
