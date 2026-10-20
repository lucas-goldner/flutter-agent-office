// Codemagic: starting builds of a floor's app and following them, through Codemagic's
// REST API (v3, https://codemagic.io/api/v3/schema) with the office's own token (CODEMAGIC_TOKEN,
// never sent anywhere but Codemagic). A floor picks its app in ⚙️ Settings; workers start builds
// with `agent-office codemagic build`, people at the 🏗️ build tower. Kept in the project's
// .agent-office/codemagic.json: the app and the last builds started from the office.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/codemagic.dart';
import 'package:office_shared/json_util.dart';
import 'package:path/path.dart' as p;

class CodemagicError implements Exception {
  CodemagicError(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// Codemagic's REST API, with a token.
class CodemagicApi {
  CodemagicApi(this.token, {this.base = 'https://codemagic.io', HttpClient? client}) : _client = client ?? HttpClient();

  final String token;
  final String base;
  final HttpClient _client;

  Future<Map<String, dynamic>> _call(String method, String path, [Object? body]) async {
    try {
      final req = await _client.openUrl(method, Uri.parse('$base$path')).timeout(const Duration(seconds: 20));
      req.headers.set('x-auth-token', token);
      req.headers.set('accept', 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(res).join();
      Object? j;
      try {
        j = text.isEmpty ? const {} : jsonDecode(text);
      } catch (_) {
        j = null;
      }
      if (res.statusCode >= 200 && res.statusCode < 300) return asMap(j);
      final detail = asString(
        asMap(j)['detail'],
        asString(asMap(j)['error'], text.length > 200 ? text.substring(0, 200) : text),
      );
      throw CodemagicError(switch (res.statusCode) {
        401 =>
          'Codemagic turned the token down: check CODEMAGIC_TOKEN (Codemagic → Teams/User settings → Integrations → Codemagic API)',
        402 => 'Codemagic says the plan has run out of build minutes: $detail',
        403 => "The token can't do that on Codemagic: $detail",
        404 => 'Codemagic has no such app, workflow or build: $detail',
        429 => 'Codemagic is busy (rate limited): try again in a moment',
        _ => 'Codemagic said no (${res.statusCode}): $detail',
      }, res.statusCode);
    } on TimeoutException {
      throw CodemagicError("Codemagic didn't answer in time");
    } on IOException catch (e) {
      throw CodemagicError("Couldn't reach Codemagic (${e.runtimeType})");
    }
  }

  /// The apps the token's owner can build whose name has [name] in it (all of them: no [name]): the
  /// teams' apps, then their personal account's. Archived ones are left out.
  Future<List<CodemagicApp>> apps({String name = ''}) async {
    final q = name.trim().isEmpty ? '' : '&name=${Uri.encodeQueryComponent(name.trim())}';
    List<Map<String, dynamic>> rows(Map<String, dynamic> j) => [
      for (final a in j['data'] is List ? j['data'] as List : const [])
        if (a is Map) Map<String, dynamic>.from(a),
    ];
    // Every page (of 50) of [path], up to a few hundred.
    Future<List<Map<String, dynamic>>> all(String path, [String query = '']) async {
      final out = <Map<String, dynamic>>[];
      for (var page = 1; page <= 6; page++) {
        final j = await _call('GET', '$path?page_size=50&page=$page$query');
        out.addAll(rows(j));
        if (page >= asInt(j['total_pages'], 1)) break;
      }
      return out;
    }

    final teams = await all('/api/v3/user/teams');
    final seen = <String>{};
    final apps = <CodemagicApp>[];
    void add(Map<String, dynamic> a, String team) {
      final app = CodemagicApp(id: asString(a['id']), name: asString(a['name']), team: team);
      if (a['archived'] != true && app.id.isNotEmpty && seen.add(app.id)) apps.add(app);
    }

    for (final t in teams) {
      final id = asString(t['id']);
      if (id.isEmpty) continue;
      for (final a in await all('/api/v3/teams/${Uri.encodeComponent(id)}/apps', q)) {
        add(a, asString(t['name']));
      }
    }
    for (final a in await all('/api/v3/user/apps', q)) {
      add(a, '');
    }
    return apps;
  }

  Future<List<CodemagicWorkflow>> workflows(String appId) async {
    final j = await _call('GET', '/api/v3/apps/${Uri.encodeComponent(appId)}/workflows');
    return [
      for (final w in j['data'] is List ? j['data'] as List : const [])
        if (w is Map) CodemagicWorkflow.fromJson(Map<String, dynamic>.from(w)),
    ];
  }

  /// Starts [workflowId] on [branch]; returns the build's id.
  Future<String> start(
    String appId,
    String workflowId,
    String branch, {
    Map<String, String> variables = const {},
  }) async {
    final j = await _call('POST', '/api/v3/apps/${Uri.encodeComponent(appId)}/builds', {
      'workflow_id': workflowId,
      'branch': branch,
      if (variables.isNotEmpty) 'environment': {'variables': variables},
    });
    final id = asString(asMap(j['data'])['id']);
    if (id.isEmpty) throw CodemagicError("Codemagic started it but didn't say which build it is");
    return id;
  }

  /// A build as it is now: its status, number and artifacts (each with a short-lived download link).
  Future<({CodemagicStatus status, int index, List<({CodemagicArtifact artifact, String url})> artifacts})> build(
    String id,
  ) async {
    final d = asMap((await _call('GET', '/api/v3/builds/${Uri.encodeComponent(id)}'))['data']);
    return (
      status: CodemagicStatus.parse(d['status']),
      index: asInt(d['index']),
      artifacts: [
        for (final a in d['artifacts'] is List ? d['artifacts'] as List : const [])
          if (a is Map)
            (
              artifact: CodemagicArtifact(
                name: asString(a['name']),
                type: asString(a['type']),
                size: asInt(a['size_in_bytes']),
              ),
              url: asString(a['short_lived_download_url']),
            ),
      ],
    );
  }

  void close() => _client.close(force: true);
}

/// A floor's app on Codemagic and the builds started from the office.
class FloorCodemagic {
  FloorCodemagic(String dataDir, this.api, {int Function()? now})
    : _path = p.join(dataDir, 'codemagic.json'),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _load();
  }

  final String _path;
  final int Function() _now;

  /// Null without CODEMAGIC_TOKEN.
  final CodemagicApi? api;

  String _appId = '';
  String _appName = '';
  List<CodemagicWorkflow> _workflows = [];
  List<CodemagicBuild> _builds = [];
  String? _error;

  /// How many builds it remembers.
  static const keep = 20;

  void _load() {
    try {
      final j = asMap(jsonDecode(File(_path).readAsStringSync()));
      _appId = asString(j['appId']);
      _appName = asString(j['appName']);
      _workflows = asList(j['workflows'], CodemagicWorkflow.fromJson);
      _builds = asList(j['builds'], CodemagicBuild.fromJson);
    } catch (_) {
      // none set up yet
    }
  }

  void _save() {
    try {
      File(_path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            if (_appId.isNotEmpty) 'appId': _appId,
            if (_appName.isNotEmpty) 'appName': _appName,
            if (_workflows.isNotEmpty) 'workflows': [for (final w in _workflows) w.toJson()],
            if (_builds.isNotEmpty) 'builds': [for (final b in _builds) b.toJson()],
          }),
        );
    } catch (_) {
      // a read-only data folder: it lasts until the office restarts
    }
  }

  CodemagicState state() => CodemagicState(
    token: api != null,
    appId: _appId,
    appName: _appName,
    workflows: _workflows,
    builds: _builds,
    error: _error,
  );

  CodemagicApi _api() =>
      api ??
      (throw CodemagicError(
        'The office has no Codemagic token: start it with CODEMAGIC_TOKEN set (or --codemagic-token)',
      ));

  /// Sets the floor's app (empty: none), reading its name and workflows. Returns why not, or null.
  Future<String?> setApp(String appId) async {
    final id = appId.trim();
    if (id.isEmpty) {
      _appId = _appName = '';
      _workflows = [];
      _save();
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(id)) return "That isn't a Codemagic app id";
    try {
      final apps = await _api().apps();
      final app = apps.where((a) => a.id == id).firstOrNull;
      _workflows = await _api().workflows(id);
      _appId = id;
      _appName = app?.label ?? id;
      _error = null;
      _save();
      return null;
    } on CodemagicError catch (e) {
      return e.message;
    }
  }

  /// Reads the app's workflows again.
  Future<void> refreshWorkflows() async {
    if (_appId.isEmpty || api == null) return;
    try {
      _workflows = await api!.workflows(_appId);
      _error = null;
      _save();
    } on CodemagicError catch (e) {
      _error = e.message;
    }
  }

  /// The workflow [name] names: its id, or its name (any case).
  CodemagicWorkflow? findWorkflow(String name) {
    final n = name.trim().toLowerCase();
    return _workflows.where((w) => w.id.toLowerCase() == n).firstOrNull ??
        _workflows.where((w) => w.name.toLowerCase() == n).firstOrNull;
  }

  /// Starts [workflow] on [branch] for [by]; returns the build, or throws a [CodemagicError].
  Future<CodemagicBuild> start(
    String workflow,
    String branch, {
    required String by,
    Map<String, String> variables = const {},
  }) async {
    if (_appId.isEmpty) {
      throw CodemagicError('No Codemagic app for this floor: pick one in ⚙️ Settings → 🏗️ Codemagic');
    }
    final b = branch.trim();
    if (b.isEmpty || b.contains('..') || !RegExp(r'^[\w./+-]{1,200}$').hasMatch(b)) {
      throw CodemagicError('Say which branch to build: --branch <name>');
    }
    var w = findWorkflow(workflow);
    if (w == null) {
      await refreshWorkflows();
      w = findWorkflow(workflow);
    }
    if (w == null) {
      throw CodemagicError(
        'No workflow “$workflow” in $_appName: ${_workflows.isEmpty ? 'it has none' : 'its workflows are ${_workflows.map((x) => x.label).join(', ')}'}',
      );
    }
    final id = await _api().start(_appId, w.id, b, variables: variables);
    final build = CodemagicBuild(
      id: id,
      workflow: w.label,
      branch: b,
      by: by,
      at: _now(),
      link: codemagicBuildLink(_appId, id),
    );
    _builds = [build, ..._builds].take(keep).toList();
    _save();
    return build;
  }

  /// Asks Codemagic how the running builds are doing: whether any moved on, and the ones that ended.
  Future<({bool changed, List<CodemagicBuild> ended})> poll() async {
    if (api == null) return (changed: false, ended: const <CodemagicBuild>[]);
    final ended = <CodemagicBuild>[];
    var changed = false;
    for (final b in _builds.where((b) => !b.status.done).toList()) {
      try {
        final now = await api!.build(b.id);
        if (now.status == b.status && now.index == b.index) continue;
        final next = b.copyWith(
          status: now.status,
          index: now.index,
          artifacts: [for (final a in now.artifacts) a.artifact],
          finishedAt: now.status.done ? _now() : 0,
        );
        _builds = [for (final x in _builds) x.id == b.id ? next : x];
        changed = true;
        if (now.status.done) ended.add(next);
      } on CodemagicError catch (e) {
        // A build Codemagic no longer knows: stop asking about it.
        if (e.status == 404) {
          _builds = [
            for (final x in _builds)
              x.id == b.id ? x.copyWith(status: CodemagicStatus.canceled, finishedAt: _now()) : x,
          ];
          changed = true;
        }
      }
    }
    if (changed) _save();
    return (changed: changed, ended: ended);
  }

  /// A build as it is now, with its artifacts' download links (short-lived: hand them on soon).
  Future<({CodemagicBuild build, List<({CodemagicArtifact artifact, String url})> downloads})> status(String id) async {
    final known = _builds.where((b) => b.id == id || '${b.index}' == id).firstOrNull;
    final buildId = known?.id ?? id;
    final now = await _api().build(buildId);
    final build = (known ?? CodemagicBuild(id: buildId, workflow: '?', link: codemagicBuildLink(_appId, buildId)))
        .copyWith(status: now.status, index: now.index, artifacts: [for (final a in now.artifacts) a.artifact]);
    if (known != null && (known.status != now.status || known.index != now.index)) {
      _builds = [
        for (final x in _builds) x.id == buildId ? build.copyWith(finishedAt: now.status.done ? _now() : 0) : x,
      ];
      _save();
    }
    return (build: build, downloads: now.artifacts);
  }
}
