// Codemagic: a floor's app on Codemagic, its workflows, and the builds started from the
// office (`agent-office codemagic build`, the 🏗️ build tower), with their status and artifacts. The
// API token stays on the office's server (CODEMAGIC_TOKEN); this is what everyone on the floor sees.

import 'json_util.dart';
import 'protocol.dart' show JsonObject;

/// A build's status, as Codemagic says it.
enum CodemagicStatus implements WireEnum {
  initializing('initializing'),
  queued('queued'),
  preparing('preparing'),
  fetching('fetching'),
  testing('testing'),
  building('building'),
  publishing('publishing'),
  finishing('finishing'),
  finished('finished'),
  failed('failed'),
  canceled('canceled'),
  timeout('timeout'),
  skipped('skipped');

  const CodemagicStatus(this.wire);
  @override
  final String wire;

  static CodemagicStatus parse(Object? v) => parseWire(values, v, queued);

  /// Over: it won't change again.
  bool get done => index >= finished.index;

  /// Over, and not well.
  bool get bad => this == failed || this == timeout || this == canceled;

  /// What it shows as, with its light: 🟡 running, 🟢 done, 🔴 failed.
  String get label => switch (this) {
    finished => '🟢 finished',
    failed => '🔴 failed',
    timeout => '🔴 timed out',
    canceled => '⚪ canceled',
    skipped => '⚪ skipped',
    _ => '🟡 $wire',
  };
}

/// A workflow of the app (from its codemagic.yaml, or the workflow editor).
class CodemagicWorkflow implements JsonObject {
  const CodemagicWorkflow({required this.id, this.name = ''});

  factory CodemagicWorkflow.fromJson(Map<String, dynamic> j) =>
      CodemagicWorkflow(id: asString(j['id']), name: asString(j['name']));

  final String id;
  final String name;

  /// What to call it: its name, else its id.
  String get label => name.isNotEmpty ? name : id;

  @override
  Map<String, dynamic> toJson() => {'id': id, if (name.isNotEmpty) 'name': name};
}

/// A file a build made (an .ipa, an .apk, …), by name; its download link is short-lived, so the
/// office hands one out when asked (`agent-office codemagic status`).
class CodemagicArtifact implements JsonObject {
  const CodemagicArtifact({required this.name, this.type = '', this.size = 0});

  factory CodemagicArtifact.fromJson(Map<String, dynamic> j) =>
      CodemagicArtifact(name: asString(j['name']), type: asString(j['type']), size: asInt(j['size']));

  final String name;
  final String type;
  final int size;

  @override
  Map<String, dynamic> toJson() => {'name': name, if (type.isNotEmpty) 'type': type, if (size > 0) 'size': size};
}

/// A build started from the office.
class CodemagicBuild implements JsonObject {
  const CodemagicBuild({
    required this.id,
    required this.workflow,
    this.branch = '',
    this.status = CodemagicStatus.queued,
    this.by = '',
    this.at = 0,
    this.finishedAt = 0,
    this.artifacts = const [],
    this.link = '',
    this.index = 0,
  });

  factory CodemagicBuild.fromJson(Map<String, dynamic> j) => CodemagicBuild(
    id: asString(j['id']),
    workflow: asString(j['workflow']),
    branch: asString(j['branch']),
    status: CodemagicStatus.parse(j['status']),
    by: asString(j['by']),
    at: asInt(j['at']),
    finishedAt: asInt(j['finishedAt']),
    artifacts: asList(j['artifacts'], CodemagicArtifact.fromJson),
    link: asString(j['link']),
    index: asInt(j['index']),
  );

  final String id;

  /// The workflow's name (or id) and the branch it builds.
  final String workflow;
  final String branch;
  final CodemagicStatus status;

  /// Who started it (a person or a worker), when, and when it ended (ms since 1970, 0: not yet).
  final String by;
  final int at;
  final int finishedAt;
  final List<CodemagicArtifact> artifacts;

  /// The build's page on Codemagic, and its number there.
  final String link;
  final int index;

  CodemagicBuild copyWith({CodemagicStatus? status, int? finishedAt, List<CodemagicArtifact>? artifacts, int? index}) =>
      CodemagicBuild(
        id: id,
        workflow: workflow,
        branch: branch,
        status: status ?? this.status,
        by: by,
        at: at,
        finishedAt: finishedAt ?? this.finishedAt,
        artifacts: artifacts ?? this.artifacts,
        link: link,
        index: index ?? this.index,
      );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'workflow': workflow,
    if (branch.isNotEmpty) 'branch': branch,
    'status': status.wire,
    if (by.isNotEmpty) 'by': by,
    if (at > 0) 'at': at,
    if (finishedAt > 0) 'finishedAt': finishedAt,
    if (artifacts.isNotEmpty) 'artifacts': [for (final a in artifacts) a.toJson()],
    if (link.isNotEmpty) 'link': link,
    if (index > 0) 'index': index,
  };
}

/// A floor's Codemagic: whether the office has a token, the app, its workflows, recent builds.
class CodemagicState implements JsonObject {
  const CodemagicState({
    this.token = false,
    this.appId = '',
    this.appName = '',
    this.workflows = const [],
    this.builds = const [],
    this.error,
  });

  factory CodemagicState.fromJson(Map<String, dynamic> j) => CodemagicState(
    token: asBool(j['token']),
    appId: asString(j['appId']),
    appName: asString(j['appName']),
    workflows: asList(j['workflows'], CodemagicWorkflow.fromJson),
    builds: asList(j['builds'], CodemagicBuild.fromJson),
    error: asStringOrNull(j['error']),
  );

  /// The server has CODEMAGIC_TOKEN: without it nothing here works.
  final bool token;
  final String appId;
  final String appName;
  final List<CodemagicWorkflow> workflows;

  /// Newest first.
  final List<CodemagicBuild> builds;
  final String? error;

  bool get ready => token && appId.isNotEmpty;

  /// Builds still going.
  Iterable<CodemagicBuild> get running => builds.where((b) => !b.status.done);

  @override
  Map<String, dynamic> toJson() => {
    if (token) 'token': true,
    if (appId.isNotEmpty) 'appId': appId,
    if (appName.isNotEmpty) 'appName': appName,
    if (workflows.isNotEmpty) 'workflows': [for (final w in workflows) w.toJson()],
    if (builds.isNotEmpty) 'builds': [for (final b in builds) b.toJson()],
    'error': ?error,
  };
}

/// An app on Codemagic, to pick for a floor in ⚙️ Settings.
class CodemagicApp implements JsonObject {
  const CodemagicApp({required this.id, required this.name, this.team = ''});

  factory CodemagicApp.fromJson(Map<String, dynamic> j) =>
      CodemagicApp(id: asString(j['id']), name: asString(j['name']), team: asString(j['team']));

  final String id;
  final String name;

  /// The Codemagic team it belongs to ('': your personal account's).
  final String team;

  /// "Acme · acme-app", or just its name.
  String get label => team.isEmpty ? name : '$team · $name';

  @override
  Map<String, dynamic> toJson() => {'id': id, 'name': name, if (team.isNotEmpty) 'team': team};
}

/// A build's page on Codemagic.
String codemagicBuildLink(String appId, String buildId) => 'https://codemagic.io/app/$appId/build/$buildId';
