import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/json_util.dart';
import 'package:office_shared/shared.dart';

const Duration _refreshEvery = Duration(milliseconds: 90000);

/// How long the repo's list of labels is kept before the label picker asks GitHub again.
const _labelsMs = 60000;

/// Turns gh's stderr into something a person standing at the board can act on.
String _friendly(String raw) {
  if (RegExp(r'no git remotes found|none of the git remotes', caseSensitive: false).hasMatch(raw)) {
    return 'This project has no GitHub remote yet. Push it to GitHub (git remote add origin <url>) to fill the boards.';
  }
  if (RegExp(r'not a git repository', caseSensitive: false).hasMatch(raw)) return "This folder isn't a git repository";
  if (RegExp(r'auth login|not logged in|authentication', caseSensitive: false).hasMatch(raw)) {
    return "gh isn't logged in on the server — run `gh auth login`";
  }
  if (RegExp(r'could not resolve to a repository|not found', caseSensitive: false).hasMatch(raw)) {
    return "gh can't find this repository on GitHub (check the remote and access)";
  }
  return raw;
}

/// What a finished (or stopped) child process left behind.
class _Ran {
  _Ran(this.code, this.out, this.err, this.killed);
  final int code;
  final String out;
  final String err;

  /// Stopped for taking longer than its timeout.
  final bool killed;
}

/// Runs a command like Node's execFile: collects its output and kills it once [timeout] passes.
/// Throws a [ProcessException] when it can't be run at all.
Future<_Ran> _exec(String cmd, List<String> args, String cwd, Duration timeout) async {
  final proc = await Process.start(cmd, args, workingDirectory: cwd);
  var killed = false;
  final timer = Timer(timeout, () {
    killed = true;
    proc.kill();
  });
  final out = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final code = await proc.exitCode;
  timer.cancel();
  return _Ran(code, await out, await err, killed);
}

/// Runs the GitHub CLI in [cwd] and resolves to its stdout; a failure throws a message worth showing.
Future<String> gh(List<String> args, String cwd, [int timeout = 30000]) async {
  _Ran r;
  try {
    r = await _exec('gh', args, cwd, Duration(milliseconds: timeout));
  } on ProcessException catch (e) {
    if (e.errorCode == 2) throw GhError('GitHub CLI (gh) is not installed on the server');
    throw GhError(_friendly(e.message));
  }
  if (r.code == 0 && !r.killed) return r.out;
  final raw = r.err.isNotEmpty ? r.err : 'Command failed: gh ${args.join(' ')}';
  final lines = raw.trim().split('\n');
  final msg = lines.sublist(lines.length > 2 ? lines.length - 2 : 0).join(' ');
  throw GhError(_friendly(msg));
}

/// Why a gh command failed, in words for the person at the board.
class GhError implements Exception {
  GhError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _messageOf(Object err) => err is GhError ? err.message : '$err';

List<GhLabel> _labels(Object? raw) => [
  if (raw is List)
    for (final l in raw)
      if (l is Map) GhLabel(name: '${l['name']}', color: '#${l['color'] ?? '888888'}'),
];

String _upper(Object? v) => (v == null ? '' : '$v').toUpperCase();

GhChecks _checksOf(Object? rollup) {
  if (rollup is! List || rollup.isEmpty) return GhChecks.none;
  var pending = false;
  for (final c in rollup) {
    final m = c is Map ? c : const {};
    final concl = _upper(m['conclusion'] ?? m['state']);
    final status = _upper(m['status']);
    if (const ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED'].contains(concl)) return GhChecks.fail;
    if (status.isNotEmpty && status != 'COMPLETED') pending = true;
    if (concl == 'PENDING' || concl == 'EXPECTED') pending = true;
  }
  return pending ? GhChecks.pending : GhChecks.pass;
}

const List<String> _failed = ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE'];

/// One entry of statusCheckRollup: a CheckRun (Actions) or a StatusContext (other CI).
GhCheck _checkOf(Object? raw) {
  final c = raw is Map ? raw : const {};
  final concl = _upper(c['conclusion'] ?? c['state']);
  final status = _upper(c['status']);
  var state = GhCheckState.pass;
  if (_failed.contains(concl)) {
    state = GhCheckState.fail;
  } else if ((status.isNotEmpty && status != 'COMPLETED') ||
      concl.isEmpty ||
      concl == 'PENDING' ||
      concl == 'EXPECTED') {
    state = GhCheckState.pending;
  } else if (const ['SKIPPED', 'NEUTRAL', 'STALE'].contains(concl)) {
    state = GhCheckState.skip;
  }
  final name = '${c['name'] ?? c['context'] ?? 'check'}';
  final workflow = c['workflowName'];
  final url = c['detailsUrl'] ?? c['targetUrl'];
  return GhCheck(
    name: workflow is String && workflow.isNotEmpty ? '$workflow / $name' : name,
    state: state,
    url: url is String ? url : null,
  );
}

String? _str(Object? v) => v is String ? v : null;

List<GhComment> _commentsOf(Object? raw) => [
  if (raw is List)
    for (final c in raw.whereType<Map>())
      GhComment(
        id: '${c['id'] ?? 'undefined'}',
        author: _str(c['author'] is Map ? (c['author'] as Map)['login'] : null) ?? 'ghost',
        body: '${c['body'] ?? ''}',
        createdAt: _str(c['createdAt']) ?? _str(c['submittedAt']) ?? '',
        url: _str(c['url']),
        state: _str(c['state']),
      ),
];

String _loginOf(Object? v) => v is Map && v['login'] is String ? v['login'] as String : '';

String _cut(Object? v, int n) {
  final s = '${v ?? ''}';
  return s.length > n ? s.substring(0, n) : s;
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Spots pull requests that merged between two looks at the list, so the gong rings however they
/// merged: from the PR window, by a worker's `gh pr merge`, by auto-merge, or on GitHub itself.
class MergeWatch {
  /// Open at the last look; unset until the first, so starting the office up rings for nothing.
  Set<int>? _open;

  /// Rang for already (merged from the PR window), so the next look doesn't ring them again.
  final Set<int> _rang = {};

  /// The gong rings for `n`: false if it already has.
  bool ring(int n) => _rang.add(n);

  /// A fresh list from GitHub: the pull requests that merged since the last look and haven't rung yet.
  List<GhPull> look(List<GhPull> pulls) {
    final open = _open;
    final merged = open == null
        ? <GhPull>[]
        : pulls.where((p) => p.state == 'MERGED' && open.contains(p.number) && !_rang.contains(p.number)).toList();
    // Once GitHub says it merged, it never shows as open again to ring twice.
    for (final p in pulls) {
      if (p.state == 'MERGED') _rang.remove(p.number);
    }
    _open = {
      for (final p in pulls)
        if (p.state == 'OPEN') p.number,
    };
    return merged;
  }
}

class GitHub {
  GitHub(this._dir, this._onIssues, this._onPulls);

  final String _dir;
  final void Function(GhState<GhIssue> s) _onIssues;
  final void Function(GhState<GhPull> s) _onPulls;

  GhState<GhIssue> issues = const GhState(items: [], fetchedAt: 0, loading: false);
  GhState<GhPull> pulls = const GhState(items: [], fetchedAt: 0, loading: false);
  Timer? _timer;
  Future<GhRepoInfo>? _repo;
  Future<String>? _login;
  ({int at, Future<List<GhLabel>> list})? _labelList;

  /// Labels just changed from the office, by "issue:N" or "pull:N", and when.
  final _relabeled = <String, ({List<GhLabel> labels, int at})>{};

  void start() {
    unawaited(refresh());
    _timer = Timer.periodic(_refreshEvery, (_) => unawaited(refresh()));
  }

  void stop() {
    _timer?.cancel();
  }

  Future<void> refresh() async {
    await Future.wait([_refreshIssues(), _refreshPulls()]);
  }

  /// The repository's full name and how it lets PRs merge. Asked once (again after a failure).
  Future<GhRepoInfo> repoInfo() {
    final existing = _repo;
    if (existing != null) return existing;
    final f =
        gh([
          'repo',
          'view',
          '--json',
          'nameWithOwner,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed',
        ], _dir).then((out) {
          final r = asMap(jsonDecode(out));
          const keys = {
            GhMergeMethod.squash: 'squashMergeAllowed',
            GhMergeMethod.merge: 'mergeCommitAllowed',
            GhMergeMethod.rebase: 'rebaseMergeAllowed',
          };
          final methods = [
            for (final m in GhMergeMethod.values)
              if (_truthy(r[keys[m]])) m,
          ];
          return GhRepoInfo(
            nameWithOwner: '${r['nameWithOwner']}',
            methods: methods.isNotEmpty ? methods : GhMergeMethod.values,
          );
        });
    _repo = f;
    f.then(
      (_) {},
      onError: (Object _) {
        if (identical(_repo, f)) _repo = null;
      },
    );
    return f;
  }

  /// Who gh is signed in as, which is who the office comments as. Asked once; '' when gh can't say.
  Future<String> viewer() {
    var f = _login;
    if (f == null) {
      final asked = gh(['api', 'user', '--jq', '.login'], _dir).then((out) => out.trim());
      _login = f = asked;
      asked.then(
        (_) {},
        onError: (Object _) {
          if (identical(_login, asked)) _login = null;
        },
      );
    }
    return f.catchError((Object _) => '');
  }

  /// A PR's description, conversation, line comments, checks and whether it can merge.
  Future<GhPullDetail> pullDetail(int n) async {
    const fields =
        'number,body,state,isDraft,reviewDecision,headRefName,baseRefName,mergeable,mergeStateStatus,commits,comments,reviews,statusCheckRollup';
    const jq = '.[] | {id, in_reply_to_id, path, line, side, body, user: .user.login, created_at, html_url}';
    final viewF = gh(['pr', 'view', '$n', '--json', fields], _dir);
    final linesF = gh(['api', 'repos/{owner}/{repo}/pulls/$n/comments?per_page=100', '--paginate', '--jq', jq], _dir);
    final repoF = repoInfo();
    final viewerF = viewer();
    // Like Promise.all: every one is awaited, and the first failure is what's thrown.
    await Future.wait<Object?>([viewF, linesF, repoF, viewerF], eagerError: true);
    final view = await viewF;
    final lines = await linesF;
    final repo = await repoF;
    final who = await viewerF;
    final p = asMap(jsonDecode(view));
    final reviewComments =
        [
              for (final l in lines.split('\n'))
                if (l.trim().isNotEmpty) asMap(jsonDecode(l)),
            ]
            .map(
              (c) => GhReviewComment(
                id: asInt(c['id']),
                replyTo: asIntOrNull(c['in_reply_to_id']),
                author: _str(c['user']) ?? 'ghost',
                body: '${c['body'] ?? ''}',
                createdAt: asString(c['created_at']),
                url: asString(c['html_url']),
                path: asString(c['path']),
                line: asIntOrNull(c['line']),
                side: c['side'] == 'LEFT' ? GhReviewSide.left : GhReviewSide.right,
              ),
            )
            .toList();
    return GhPullDetail(
      number: asInt(p['number']),
      body: '${p['body'] ?? ''}',
      state: asString(p['state']),
      isDraft: _truthy(p['isDraft']),
      reviewDecision: _str(p['reviewDecision']) ?? '',
      headRefName: asString(p['headRefName']),
      baseRefName: asString(p['baseRefName']),
      mergeable: _str(p['mergeable']) ?? 'UNKNOWN',
      mergeStateStatus: _str(p['mergeStateStatus']) ?? 'UNKNOWN',
      commits: p['commits'] is List ? (p['commits'] as List).length : 0,
      comments: _commentsOf(p['comments']),
      // A line comment also makes an empty COMMENTED review; the comment itself is shown instead.
      reviews: _commentsOf(p['reviews']).where((r) => r.body.trim().isNotEmpty || r.state != 'COMMENTED').toList(),
      reviewComments: reviewComments,
      checks: [if (p['statusCheckRollup'] is List) ...(p['statusCheckRollup'] as List).map(_checkOf)],
      repo: repo,
      viewer: who,
    );
  }

  /// The PR's unified diff, as `git diff` prints it.
  Future<String> pullDiff(int n) => gh(['pr', 'diff', '$n', '--color', 'never'], _dir, 60000);

  Future<GhIssueDetail> issueDetail(int n) async {
    final viewF = gh(['issue', 'view', '$n', '--json', 'number,state,body,comments'], _dir);
    final viewerF = viewer();
    await Future.wait<Object?>([viewF, viewerF], eagerError: true);
    final i = asMap(jsonDecode(await viewF));
    return GhIssueDetail(
      number: asInt(i['number']),
      state: asString(i['state']),
      body: '${i['body'] ?? ''}',
      comments: _commentsOf(i['comments']),
      viewer: await viewerF,
    );
  }

  /// Comments on an issue, or on a PR's conversation (to GitHub a PR is an issue too), as whoever gh
  /// is signed in as. Returns the comment as GitHub saved it, or why it couldn't.
  Future<({GhComment? comment, String? error})> comment(GhKind kind, int n, String body) async {
    GhComment comment;
    try {
      // -f sends the body as a plain string: no @file reading, no {owner} filling in.
      const jq = '{id: .node_id, author: {login: .user.login}, body, createdAt: .created_at, url: .html_url}';
      final out = await gh([
        'api',
        '--method',
        'POST',
        'repos/{owner}/{repo}/issues/$n/comments',
        '-f',
        'body=$body',
        '--jq',
        jq,
      ], _dir);
      comment = _commentsOf([jsonDecode(out)]).first;
    } catch (err) {
      return (comment: null, error: _messageOf(err));
    }
    // The issue board counts comments; a PR's card shows when it was last updated.
    unawaited(kind == GhKind.issue ? _refreshIssues() : _refreshPulls());
    return (comment: comment, error: null);
  }

  /// Merges a PR, or with `auto` has GitHub merge it once its requirements pass. Returns an error.
  Future<String?> merge(int n, GhMergeMethod method, bool deleteBranch, bool auto) async {
    try {
      final repo = await repoInfo();
      // --repo keeps gh out of the office's own checkout: without it, --delete-branch also deletes
      // the local branch and switches the project folder over to the base branch.
      final args = ['pr', 'merge', '$n', '--${method.wire}', '--repo', repo.nameWithOwner];
      if (deleteBranch) args.add('--delete-branch');
      if (auto) args.add('--auto');
      await gh(args, _dir, 90000);
    } catch (err) {
      return _messageOf(err);
    }
    unawaited(_refreshPulls());
    return null;
  }

  /// Closes an issue, or a pull request without merging it, optionally saying why. Returns an error.
  Future<String?> close(GhKind kind, int n, {String? comment, GhCloseReason? reason, bool deleteBranch = false}) async {
    try {
      final repo = await repoInfo();
      // --repo for the same reason as merge: --delete-branch must leave the office's checkout alone.
      final args = [kind == GhKind.issue ? 'issue' : 'pr', 'close', '$n', '--repo', repo.nameWithOwner];
      // --flag=value, so a comment starting with "-" isn't read as a flag.
      if (comment != null && comment.isNotEmpty) args.add('--comment=$comment');
      if (kind == GhKind.issue && reason != null) args.add('--reason=${reason.wire}');
      if (kind == GhKind.pull && deleteBranch) args.add('--delete-branch');
      await gh(args, _dir);
    } catch (err) {
      return _messageOf(err);
    }
    Future<void> again() => kind == GhKind.issue ? _refreshIssues() : _refreshPulls();
    // A refresh already in flight returns at once and can still list it as open, so look again shortly after.
    unawaited(
      again().then((_) {
        final items = kind == GhKind.issue
            ? issues.items.map((i) => (i.number, i.state))
            : pulls.items.map((p) => (p.number, p.state));
        if (items.any((i) => i.$1 == n && i.$2 == 'OPEN')) Timer(const Duration(seconds: 3), () => unawaited(again()));
      }),
    );
    return null;
  }

  /// Every label the repository has, for the label picker. Asked again after a minute (or a failure).
  Future<List<GhLabel>> repoLabels() {
    final known = _labelList;
    if (known != null && _now() - known.at <= _labelsMs) return known.list;
    final list =
        gh([
          'api',
          'repos/{owner}/{repo}/labels?per_page=100',
          '--paginate',
          '--jq',
          '.[] | {name, color, description}',
        ], _dir).then(
          (out) => [
            for (final line in out.split('\n'))
              if (line.trim().isNotEmpty)
                if (jsonDecode(line) case final Map l)
                  GhLabel(
                    name: '${l['name']}',
                    color: '#${l['color'] ?? '888888'}',
                    description: l['description'] is String && (l['description'] as String).isNotEmpty
                        ? l['description'] as String
                        : null,
                  ),
          ],
        );
    _labelList = (at: _now(), list: list);
    list.catchError((Object _) {
      if (identical(_labelList?.list, list)) _labelList = null;
      return const <GhLabel>[];
    });
    return list;
  }

  /// Puts labels on an issue or PR and takes others off (to GitHub a PR is an issue too), as whoever
  /// gh is signed in as. Returns the labels it has now, or why they didn't change.
  Future<({List<GhLabel>? labels, String? error})> setLabels(
    GhKind kind,
    int n,
    List<String> add,
    List<String> remove,
  ) async {
    final path = 'repos/{owner}/{repo}/issues/$n/labels';
    const jq = '[.[] | {name, color}]';
    List<GhLabel>? now;
    try {
      // -f labels[]=… sends a JSON array of plain strings: no @file reading, no {owner} filling in.
      if (add.isNotEmpty) {
        now = _labels(
          jsonDecode(
            await gh([
              'api',
              '--method',
              'POST',
              path,
              for (final l in add) ...['-f', 'labels[]=$l'],
              '--jq',
              jq,
            ], _dir),
          ),
        );
      }
      for (final l in remove) {
        try {
          now = _labels(
            jsonDecode(await gh(['api', '--method', 'DELETE', '$path/${Uri.encodeComponent(l)}', '--jq', jq], _dir)),
          );
        } catch (err) {
          // Someone took it off already, which is what was asked for.
          if (!RegExp('label does not exist', caseSensitive: false).hasMatch(_messageOf(err))) rethrow;
        }
      }
      now ??= _labels(jsonDecode(await gh(['api', '$path?per_page=100', '--jq', jq], _dir)));
    } catch (err) {
      // Some may have changed before it failed.
      unawaited(kind == GhKind.issue ? _refreshIssues() : _refreshPulls());
      return (labels: null, error: _messageOf(err));
    }
    // The board shows them at once, before the next look at GitHub (see _relabel).
    final at = _now();
    _relabeled['${kind.wire}:$n'] = (labels: now, at: at);
    if (kind == GhKind.issue) {
      issues = GhState(
        items: _relabel(GhKind.issue, issues.items, at),
        error: issues.error,
        fetchedAt: issues.fetchedAt,
        loading: issues.loading,
      );
      _onIssues(issues);
      unawaited(_refreshIssues());
    } else {
      pulls = GhState(
        items: _relabel(GhKind.pull, pulls.items, at),
        error: pulls.error,
        fetchedAt: pulls.fetchedAt,
        loading: pulls.loading,
      );
      _onPulls(pulls);
      unawaited(_refreshPulls());
    }
    return (labels: now, error: null);
  }

  /// A list asked for before a label change made here still has the old labels, so the new ones are
  /// kept over it; a list asked for after the change is believed, and the change forgotten.
  List<T> _relabel<T extends JsonObject>(GhKind kind, List<T> items, int asked) => [
    for (final it in items) _relabelOne(kind, it, asked),
  ];

  T _relabelOne<T extends JsonObject>(GhKind kind, T it, int asked) {
    final number = switch (it) {
      GhIssue(:final number) => number,
      GhPull(:final number) => number,
      _ => 0,
    };
    final key = '${kind.wire}:$number';
    final r = _relabeled[key];
    if (r == null) return it;
    if (r.at < asked) {
      _relabeled.remove(key);
      return it;
    }
    final json = {
      ...it.toJson(),
      'labels': [for (final l in r.labels) l.toJson()],
    };
    return (it is GhIssue ? GhIssue.fromJson(json) : GhPull.fromJson(json)) as T;
  }

  /// Assigns the issue to whoever gh is signed in as, which moves it to In progress on the board.
  Future<String?> claim(int issue) async {
    try {
      await gh(['issue', 'edit', '$issue', '--add-assignee', '@me'], _dir);
    } catch (err) {
      return _messageOf(err);
    }
    unawaited(_refreshIssues());
    return null;
  }

  Future<void> _refreshIssues() async {
    if (issues.loading) return;
    issues = GhState(items: issues.items, error: issues.error, fetchedAt: issues.fetchedAt, loading: true);
    _onIssues(issues);
    final asked = _now();
    try {
      // Open and closed separately, so old open issues are never crowded out by recent closed ones.
      const fields = 'number,title,state,url,author,labels,assignees,createdAt,updatedAt,body,comments';
      final lists = await Future.wait([
        gh(['issue', 'list', '--state', 'open', '--limit', '300', '--json', fields], _dir),
        gh(['issue', 'list', '--state', 'closed', '--limit', '40', '--json', fields], _dir),
      ]);
      final items = <GhIssue>[
        for (final out in lists)
          for (final i in (jsonDecode(out) as List).whereType<Map>())
            GhIssue(
              number: asInt(i['number']),
              title: asString(i['title']),
              state: asString(i['state']),
              url: asString(i['url']),
              author: _loginOf(i['author']),
              labels: _labels(i['labels']),
              assignees: [
                if (i['assignees'] is List)
                  for (final a in i['assignees'] as List) '${a is Map ? a['login'] : null}',
              ],
              createdAt: asString(i['createdAt']),
              updatedAt: asString(i['updatedAt']),
              body: _cut(i['body'], 4000),
              comments: i['comments'] is List ? (i['comments'] as List).length : asInt(i['comments']),
            ),
      ];
      issues = GhState(items: _relabel(GhKind.issue, items, asked), fetchedAt: _now(), loading: false);
    } catch (err) {
      issues = GhState(items: issues.items, loading: false, error: _messageOf(err), fetchedAt: _now());
    }
    _onIssues(issues);
  }

  Future<void> _refreshPulls() async {
    if (pulls.loading) return;
    pulls = GhState(items: pulls.items, error: pulls.error, fetchedAt: pulls.fetchedAt, loading: true);
    _onPulls(pulls);
    final asked = _now();
    try {
      const fields =
          'number,title,state,isDraft,url,author,labels,reviewDecision,headRefName,baseRefName,createdAt,updatedAt,additions,deletions,statusCheckRollup,body,closingIssuesReferences';
      final lists = await Future.wait([
        gh(['pr', 'list', '--state', 'open', '--limit', '150', '--json', fields], _dir),
        gh(['pr', 'list', '--state', 'merged', '--limit', '30', '--json', fields], _dir),
        gh(['pr', 'list', '--state', 'closed', '--limit', '40', '--json', fields], _dir),
      ]);
      // `--state closed` includes merged PRs; keep only the ones closed without merging.
      final seen = <Object?>{};
      final all = [
        for (final out in lists)
          for (final p in (jsonDecode(out) as List).whereType<Map>())
            if (seen.add(p['number'])) p,
      ];
      final items = [
        for (final p in all)
          GhPull(
            number: asInt(p['number']),
            title: asString(p['title']),
            state: asString(p['state']),
            isDraft: _truthy(p['isDraft']),
            url: asString(p['url']),
            author: _loginOf(p['author']),
            labels: _labels(p['labels']),
            reviewDecision: _str(p['reviewDecision']) ?? '',
            headRefName: asString(p['headRefName']),
            baseRefName: asString(p['baseRefName']),
            createdAt: asString(p['createdAt']),
            updatedAt: asString(p['updatedAt']),
            additions: asInt(p['additions']),
            deletions: asInt(p['deletions']),
            checks: _checksOf(p['statusCheckRollup']),
            body: _cut(p['body'], 4000),
            closes: [
              if (p['closingIssuesReferences'] is List)
                for (final r in p['closingIssuesReferences'] as List)
                  if (r is Map &&
                      r['number'] is num &&
                      (r['number'] as num) == (r['number'] as num).truncate() &&
                      (r['number'] as num) > 0)
                    (r['number'] as num).toInt(),
            ],
          ),
      ];
      pulls = GhState(items: _relabel(GhKind.pull, items, asked), fetchedAt: _now(), loading: false);
    } catch (err) {
      pulls = GhState(items: pulls.items, loading: false, error: _messageOf(err), fetchedAt: _now());
    }
    _onPulls(pulls);
  }
}

/// JavaScript's truthiness, for the flags gh hands back.
bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '';
