import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'agents.dart';

const modelCommandTimeoutMs = 10000;
const modelCommandMaxBuffer = 1024 * 1024;
const modelCacheTtlMs = 60000;

class ModelCommandOptions {
  const ModelCommandOptions({required this.cwd, required this.timeout, required this.maxBuffer});

  final String cwd;

  /// Milliseconds before the command is killed.
  final int timeout;

  /// Bytes of output (per stream) before the command is killed.
  final int maxBuffer;
}

typedef ModelCommandResult = ({String stdout, String stderr});

typedef ModelCommandRunner =
    Future<ModelCommandResult> Function(String file, List<String> args, ModelCommandOptions options);

/// Runs a command without a shell, like Node's execFile: fails on a non-zero exit, a timeout, or
/// output past maxBuffer.
Future<ModelCommandResult> _runModelCommand(String file, List<String> args, ModelCommandOptions options) async {
  final proc = await Process.start(file, args, workingDirectory: options.cwd);
  proc.stdin.close().ignore();
  var failed = false;
  void fail() {
    if (failed) return;
    failed = true;
    proc.kill(ProcessSignal.sigkill);
  }

  Future<String> collect(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length > options.maxBuffer) fail();
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  final timer = Timer(Duration(milliseconds: options.timeout), fail);
  try {
    final results = await Future.wait([collect(proc.stdout), collect(proc.stderr)]);
    final code = await proc.exitCode;
    if (failed || code != 0) throw ProcessException(file, args, 'command failed', code);
    return (stdout: results[0], stderr: results[1]);
  } finally {
    timer.cancel();
  }
}

final _ansi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
final _bullet = RegExp(r'^[-*]\s+');

/// Run `opencode models` without a shell and return only safe, model-shaped lines.
Future<List<String>> fetchOpenCodeModels(String command, String cwd, [ModelCommandRunner? runner]) async {
  try {
    final result = await (runner ?? _runModelCommand)(command, [
      'models',
    ], ModelCommandOptions(cwd: cwd, timeout: modelCommandTimeoutMs, maxBuffer: modelCommandMaxBuffer));
    final models = <String>[];
    final seen = <String>{};
    for (final raw in result.stdout.replaceAll(_ansi, '').split(RegExp(r'\r?\n'))) {
      final model = raw.trim().replaceFirst(_bullet, '');
      if (isValidOpenCodeModel(model) && seen.add(model)) models.add(model);
    }
    return models;
  } catch (_) {
    throw StateError('OpenCode model catalogue unavailable');
  }
}

abstract interface class OpenCodeModelCatalogue {
  Future<List<String>> get();
}

OpenCodeModelCatalogue createOpenCodeModelCatalogue(
  String command,
  String cwd, [
  ModelCommandRunner? runner,
  int Function()? now,
]) => _Catalogue(command, cwd, runner, now ?? () => DateTime.now().millisecondsSinceEpoch);

class _Catalogue implements OpenCodeModelCatalogue {
  _Catalogue(this.command, this.cwd, this.runner, this.now);

  final String command;
  final String cwd;
  final ModelCommandRunner? runner;
  final int Function() now;
  List<String>? _cached;
  int _expiresAt = 0;
  Future<List<String>>? _pending;

  @override
  Future<List<String>> get() {
    final cached = _cached;
    if (cached != null && now() < _expiresAt) return Future.value([...cached]);
    final pending = _pending;
    if (pending != null) return pending;
    return _pending = fetchOpenCodeModels(command, cwd, runner)
        .then((models) {
          _cached = models;
          _expiresAt = now() + modelCacheTtlMs;
          return [...models];
        })
        .whenComplete(() => _pending = null);
  }
}
