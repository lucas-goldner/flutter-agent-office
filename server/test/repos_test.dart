// Port of tests/repos.test.ts (upstream #173). A worker across repositories (WorkerInfo.repos): hired
// on one floor with other floors' projects, it works in a workspace holding a worktree of each, all on
// one branch, and opens a PR in each.
@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/changes.dart';
import 'package:agent_office_server/src/config.dart' show excludeFromGit;
import 'package:agent_office_server/src/github.dart' show ghCommand;
import 'package:agent_office_server/src/leave_on_merge.dart';
import 'package:agent_office_server/src/usage.dart';
import 'package:agent_office_server/src/workers.dart';
import 'package:agent_office_server/src/worker_pr.dart' show relatedBlock, withRelated;
import 'package:agent_office_server/src/worktrees.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String git(String cwd, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: cwd);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

/// A checkout of `github.com/acme/<name>` whose pushes land in a local bare repository instead.
String project(String root, String name) {
  final bare = p.join(root, 'remotes', '$name.git');
  Directory(bare).createSync(recursive: true);
  git(bare, ['init', '-q', '--bare', '-b', 'main']);
  final dir = p.join(root, 'projects', name);
  Directory(dir).createSync(recursive: true);
  git(dir, ['init', '-q', '-b', 'main']);
  git(dir, ['config', 'user.email', 'test@example.com']);
  git(dir, ['config', 'user.name', 'Test']);
  git(dir, ['config', 'commit.gpgsign', 'false']);
  File(p.join(dir, 'README.md')).writeAsStringSync('# $name\n');
  git(dir, ['add', '-A']);
  git(dir, ['commit', '-q', '-m', 'first']);
  git(dir, ['remote', 'add', 'origin', 'https://github.com/acme/$name.git']);
  git(dir, ['config', 'url.$bare.pushInsteadOf', 'https://github.com/acme/$name.git']);
  git(dir, ['push', '-q', 'origin', 'main']);
  excludeFromGit(dir);
  return dir;
}

/// Records where it was started and whether git finds a repository there, then waits.
const _fakeAgent = r'''#!/bin/bash
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
printf '{"cwd":"%s","ceiling":"%s","top":"%s"}\n' "$PWD" "$GIT_CEILING_DIRECTORIES" "$top" >> "$FAKE_AGENT_LOG"
while true; do sleep 1; done
''';

/// Pull requests kept in a JSON file: list, create, view (the body) and edit (the body).
String _fakeGh(String state) =>
    '''#!/usr/bin/env python3
import json, os, re, subprocess, sys
file = ${jsonEncode(state)}
st = json.load(open(file)) if os.path.exists(file) else {"prs": []}
a = sys.argv[1:]
def opt(n):
    return a[a.index(n) + 1] if n in a else None
def repo():
    url = subprocess.check_output(["git", "remote", "get-url", "origin"], text=True).strip()
    return re.sub(r"\\.git\$", "", re.sub(r"^https://github\\.com/", "", url))
def done(out, code=0):
    json.dump(st, open(file, "w"))
    sys.stdout.write(out)
    sys.exit(code)
if a[:2] == ["pr", "list"]:
    r = repo()
    done(json.dumps([{"number": p["number"], "url": p["url"]} for p in st["prs"] if p["repo"] == r and p["head"] == opt("--head") and p["state"] == "OPEN"][:1]))
if a[:2] == ["pr", "create"]:
    r = repo()
    number = len([p for p in st["prs"] if p["repo"] == r]) + 1
    url = "https://github.com/" + r + "/pull/" + str(number)
    st["prs"].append({"repo": r, "number": number, "url": url, "head": opt("--head"), "base": opt("--base"), "title": opt("--title"), "body": opt("--body"), "state": "OPEN"})
    done(url + "\\n")
pr = next((p for p in st["prs"] if len(a) > 2 and p["url"] == a[2]), None)
if a[:2] == ["pr", "view"] and pr:
    done(pr["body"] + "\\n")
if a[:2] == ["pr", "edit"] and pr:
    pr["body"] = opt("--body")
    done("")
done("", 1)
''';

class Fixture {
  Fixture()
    : root = Directory(Directory.systemTemp.createTempSync('agent-office-repos-').resolveSymbolicLinksSync()).path {
    final bin = p.join(root, 'bin');
    Directory(bin).createSync();
    agent = p.join(bin, 'fake-agent');
    File(agent).writeAsStringSync(_fakeAgent);
    ghState = p.join(root, 'gh.json');
    final gh = p.join(bin, 'gh');
    File(gh).writeAsStringSync(_fakeGh(ghState));
    // The task namer asks `claude -p`: not the real one.
    File(p.join(bin, 'claude')).writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['755', agent, gh, p.join(bin, 'claude')]);
    log = p.join(root, 'starts.jsonl');
    File(log).writeAsStringSync('');
    env = {...Platform.environment, 'PATH': '$bin:${Platform.environment['PATH']}', 'FAKE_AGENT_LOG': log};
    ghCommand = gh;
    a = project(root, 'web');
    b = project(root, 'api');
    c = project(root, 'admin');
  }

  final String root;
  late final String a, b, c, log, agent, ghState;
  late final Map<String, String> env;

  List<Map<String, dynamic>> starts() => [
    for (final l in File(log).readAsStringSync().split('\n'))
      if (l.isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> prs() => File(ghState).existsSync()
      ? [
          for (final x in (jsonDecode(File(ghState).readAsStringSync()) as Map)['prs'] as List)
            x as Map<String, dynamic>,
        ]
      : [];

  void close() {
    ghCommand = 'gh';
    try {
      Directory(root).deleteSync(recursive: true);
    } catch (_) {
      // a worker winding down
    }
  }
}

final _events = WorkerEvents(update: (_) {}, remove: (_) {}, data: (_, _, _) {}, screen: (_, _) {}, toast: (_, _) {});

WorkerManager manager(Fixture f) {
  final data = p.join(f.a, '.agent-office');
  Directory(data).createSync(recursive: true);
  final workers = WorkerManager(
    f.a,
    data,
    f.agent,
    const [],
    const HookEnv(url: 'http://127.0.0.1:1', token: ''),
    _events,
    Ledger(data, LedgerOptions(pauseHiring: false), (_) {}, (_, _) {}),
    env: f.env,
  );
  addTearDown(workers.shutdown);
  return workers;
}

RepoSource source(String floor, String dir) =>
    RepoSource(floor: floor, name: p.basename(dir), repo: 'acme/${p.basename(dir)}', dir: dir);

Future<T> waitFor<T>(T Function() read, bool Function(T v) ok, {int timeout = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: timeout));
  var v = read();
  while (!ok(v) && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    v = read();
  }
  expect(ok(v), isTrue, reason: 'timed out');
  return v;
}

({WorkerInfo? worker, String? error}) hire(
  WorkerManager workers,
  List<RepoSource> repos, {
  bool worktree = true,
  String? prompt,
}) => workers.spawn('desk-1', 'Cody', prompt, worktree, WorkerKind.agent, null, null, null, null, repos);

void main() {
  final python = Process.runSync('sh', ['-c', 'command -v python3']).exitCode == 0;
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.close());

  test(
    'a worker across repositories gets a workspace with a worktree of each on one branch, and starts in it',
    () async {
      final workers = manager(f);
      final r = hire(workers, [source('floor-api', f.b), source('floor-admin', f.c)]);
      expect(r.error, isNull);
      final w = r.worker!;
      final slug = w.worktree!.branch.replaceFirst('office/', '');
      final ws = p.join(f.a, '.agent-office', 'worktrees', slug);
      expect(w.worktree!.path, p.join('.agent-office', 'worktrees', slug, 'web'));
      expect(
        [for (final r in w.repos!) (r.floor, r.name, r.path, r.branch, r.from)],
        [
          ('floor-api', 'api', p.join('.agent-office', 'worktrees', slug, 'api'), w.worktree!.branch, 'main'),
          ('floor-admin', 'admin', p.join('.agent-office', 'worktrees', slug, 'admin'), w.worktree!.branch, 'main'),
        ],
      );
      // Each is a worktree of its own repository, on the worker's branch.
      for (final (name, dir) in [('web', f.a), ('api', f.b), ('admin', f.c)]) {
        final at = p.join(ws, name);
        expect(git(at, ['rev-parse', '--abbrev-ref', 'HEAD']), w.worktree!.branch);
        final common = git(at, ['rev-parse', '--git-common-dir']);
        expect(
          Directory(p.normalize(p.absolute(at, common))).resolveSymbolicLinksSync(),
          Directory(p.join(dir, '.git')).resolveSymbolicLinksSync(),
        );
      }
      // The brief says which folder is which, for Claude (CLAUDE.md) and the others (AGENTS.md).
      final brief = File(p.join(ws, 'CLAUDE.md')).readAsStringSync();
      expect(File(p.join(ws, 'AGENTS.md')).readAsStringSync(), brief);
      for (final line in [
        '`web/`: acme/web, cut from main',
        '`api/`: acme/api, cut from main',
        '`admin/`: acme/admin',
        w.worktree!.branch,
        'acme/web#12',
      ]) {
        expect(brief, contains(line));
      }
      expect(brief, isNot(contains('{{')));

      // It starts in the workspace, where git finds no repository (not the web floor's own checkout).
      final start = (await waitFor(f.starts, (s) => s.length == 1)).first;
      expect(Directory(start['cwd'] as String).resolveSymbolicLinksSync(), ws);
      expect(start['top'], '');
      expect(start['ceiling'], p.dirname(ws));

      // It comes back with them after a restart.
      await workers.shutdown();
      final again = manager(f);
      expect(again.get(w.id)?.repos?.map((r) => r.name), ['api', 'admin']);
    },
  );

  test('hiring across repositories needs its own worktree and different repositories, and leaves nothing behind '
      'when it fails', () async {
    final workers = manager(f);
    expect(hire(workers, [source('floor-api', f.b)], worktree: false).error, contains('own worktree'));
    // Another checkout of the web repository is still the web repository.
    final twin = p.join(f.root, 'web-twin');
    git(f.a, ['worktree', 'add', '-q', twin, '-b', 'twin']);
    expect(hire(workers, [source('floor-twin', twin)]).error, contains('same repository'));
    expect(hire(workers, [source('floor-api', f.b), source('floor-api-2', f.b)]).error, contains('same repository'));
    final plain = p.join(f.root, 'projects', 'notes');
    Directory(plain).createSync();
    expect(hire(workers, [source('floor-notes', plain)]).error, contains("isn't a git checkout"));

    // api can't have the branch (one of that name is there already): web's new worktree and branch are taken out again.
    final before = git(f.a, ['branch', '--list', 'office/*']);
    git(f.b, ['branch', 'office/sprocket-0000']);
    final failed = workers.makeWorkspace('sprocket-0000', [source('floor-api', f.b)]);
    expect(failed.error, startsWith('api: Could not create a git worktree'));
    await waitFor(() => git(f.a, ['branch', '--list', 'office/sprocket-0000']), (out) => out.isEmpty);
    expect(git(f.a, ['branch', '--list', 'office/*']), before);
    await waitFor(
      () => Directory(p.join(f.a, '.agent-office', 'worktrees', 'sprocket-0000')).existsSync(),
      (there) => !there,
    );
    expect(
      git(f.b, ['branch', '--list', 'office/sprocket-0000']),
      'office/sprocket-0000',
      reason: "api's own branch stays",
    );
  });

  test(
    'sending a worker across repositories home checks every worktree, and deletes them all and its workspace',
    () async {
      final workers = manager(f);
      final w = hire(workers, [source('floor-api', f.b)]).worker!;
      final ws = p.join(f.a, '.agent-office', 'worktrees', w.worktree!.branch.substring('office/'.length));
      File(p.join(ws, 'api', 'server.js')).writeAsStringSync('wip\n');
      final state = await workers.inspectWorktree(w.id);
      expect([for (final r in state!.repos!) (r.name, r.state.dirty)], [('web', 0), ('api', 1)]);
      expect(state.dirty, 1);
      // Nobody said what to do, and api holds work: everything stays.
      final kept = await workers.kill(w.id);
      expect(
        kept.note,
        matches(RegExp(r'Kept .*worktrees and branch office/\S+ in web, api — api has 1 uncommitted change')),
      );
      expect(File(p.join(ws, 'api', 'server.js')).existsSync(), isTrue);

      final w2 = hire(workers, [source('floor-api', f.b)]).worker!;
      final ws2 = p.join(f.a, '.agent-office', 'worktrees', w2.worktree!.branch.substring('office/'.length));
      final done = await workers.kill(w2.id, WorktreeCleanup.all);
      expect(done.note, matches(RegExp(r'Deleted .*worktrees and branch office/\S+ in web, api')));
      expect(Directory(ws2).existsSync(), isFalse);
      expect(git(f.a, ['branch', '--list', w2.worktree!.branch]), '');
      expect(git(f.b, ['branch', '--list', w2.worktree!.branch]), '');
    },
  );

  test('O opens a pull request in each repository with commits, and each one lists them all', () async {
    final workers = manager(f);
    final w = hire(workers, [
      source('floor-api', f.b),
      source('floor-admin', f.c),
    ], prompt: 'Work on GitHub issue #12: "Sign in with passkeys".').worker!;
    final ws = p.join(f.a, '.agent-office', 'worktrees', w.worktree!.branch.substring('office/'.length));
    await waitFor(() => workers.get(w.id)?.status, (s) => s != WorkerStatus.starting);
    // Work in web and api; nothing in admin.
    for (final name in ['web', 'api']) {
      File(p.join(ws, name, 'passkeys.js')).writeAsStringSync('// $name\n');
      git(p.join(ws, name), ['add', '-A']);
      git(p.join(ws, name), ['commit', '-q', '-m', 'Passkeys in $name']);
    }
    final r = await workers.openPr(w.id, 'Cody');
    expect(r.error, isNull);
    expect(r.failed, isEmpty);
    expect([for (final x in r.prs) (x.repo, x.number, x.existed)], [('web', 1, false), ('api', 1, false)]);
    final prs = f.prs();
    final web = prs.firstWhere((x) => x['repo'] == 'acme/web');
    final api = prs.firstWhere((x) => x['repo'] == 'acme/api');
    expect(prs.length, 2);
    expect(web['base'], 'main');
    expect(web['title'], 'Sign in with passkeys');
    // The issue is web's: its PR closes it, api's only points at it.
    expect(web['body'], contains('\nCloses #12\n'));
    expect(api['body'], contains('\nPart of acme/web#12\n'));
    expect(api['body'], isNot(contains('Closes')));
    for (final x in [web, api]) {
      final body = x['body'] as String;
      expect(body, contains('One change across 2 repositories'));
      expect(body, contains('**web**: acme/web#1'));
      expect(body, contains('**api**: acme/api#1'));
      expect(body, contains('${x['repo']}#1 (this one)'));
    }
    // Pushed to each repository's origin.
    for (final name in ['web', 'api']) {
      expect(git(p.join(f.root, 'remotes', '$name.git'), ['rev-parse', w.worktree!.branch]), isNotEmpty);
    }
    expect(workers.get(w.id)?.pr?.url, 'https://github.com/acme/web/pull/1');
    expect(workers.get(w.id)?.repos?.map((x) => x.pr?.url), ['https://github.com/acme/api/pull/1', null]);

    // Later, admin gets work too: O again opens its PR and brings every list up to date.
    File(p.join(ws, 'admin', 'passkeys.js')).writeAsStringSync('// admin\n');
    git(p.join(ws, 'admin'), ['add', '-A']);
    git(p.join(ws, 'admin'), ['commit', '-q', '-m', 'Passkeys in admin']);
    final again = await workers.openPr(w.id, 'Cody');
    expect(again.error, isNull);
    expect([for (final x in again.prs) (x.repo, x.existed)], [('web', true), ('api', true), ('admin', false)]);
    for (final x in f.prs()) {
      final body = x['body'] as String;
      expect(body, contains('One change across 3 repositories'));
      expect(body.split('agent-office:related').length, 3, reason: 'one list, replaced rather than added again');
    }
  }, skip: python ? false : 'needs python3 for the fake gh');

  test('the list of related pull requests goes in once and is replaced after', () {
    final block = relatedBlock(
      [
        (repo: 'web', url: 'https://github.com/acme/web/pull/3'),
        (repo: 'api', url: 'https://github.com/acme/api/pull/9'),
      ],
      'https://github.com/acme/api/pull/9',
      'office/pip-1',
    );
    expect(block, contains('- **web**: acme/web#3\n- **api**: acme/api#9 (this one)'));
    final once = withRelated('## Task\n\nDo it\n', block);
    expect(once, '## Task\n\nDo it\n\n$block');
    final newer = relatedBlock([(repo: 'web', url: 'https://github.com/acme/web/pull/3')], 'x', 'office/pip-1');
    expect(withRelated('$once\n\nsigned', newer), '## Task\n\nDo it\n\n$newer\n\nsigned');
    expect(withRelated('', block), block);
  });

  test("each checkout's folder in a workspace is named after it, once", () {
    expect(workspaceNames(['/p/acme/web', '/p/other/web', '/p/acme/api', '/x/.hidden', '/y/AGENTS.md', '/z/my repo']), [
      'web',
      'web-2',
      'api',
      'hidden',
      'AGENTS.md-repo',
      'my-repo',
    ]);
  });

  test('the Changes window follows each repository of a worker across repositories against its own branch', () async {
    final wt = Worktrees(f.b).create('pip-1', 'api', f.a).worktree!;
    final cwd = p.join(f.a, wt.path);
    File(p.join(cwd, 'new.js')).writeAsStringSync('x\n');
    final states = <ChangesState>[];
    // The web floor's office was opened on a branch api doesn't have: api's diff is against its own main.
    final changes = Changes(
      f.a,
      'trunk',
      (id, repo) => id == 'w1' && repo == 'floor-api'
          ? ChangesTarget(
              name: 'Pip',
              cwd: cwd,
              rel: wt.path,
              worktreeBase: wt.base,
              baseBranch: (branch: 'main'),
              openPull: (_) => const PrRef(number: 4, url: 'u'),
            )
          : null,
      (_) => null,
      ChangesEvents(state: (s, _) => states.add(s), toast: (_, _) {}, refreshGitHub: () {}),
    );
    addTearDown(changes.stop);
    changes.watch('w1', 'c1', 'floor-api');
    final s = (await waitFor(() => states, (x) => x.isNotEmpty)).first;
    expect(s.repo, 'floor-api');
    expect(s.branch, 'office/pip-1');
    expect(s.base, 'main');
    expect(s.prBase, 'main');
    expect((s.pr?.number, s.pr?.url), (4, 'u'));
    expect([for (final x in s.files) (x.path, x.status)], [('new.js', ChangeStatus.untracked)]);
    expect(await changes.commit('w1', 'Add new.js', 'Cody', 'floor-api'), isNull);
    expect(git(cwd, ['log', '-1', '--format=%s']), 'Add new.js');
    // Its own floor's checkout is a different target.
    expect((await changes.diff('w1', 'new.js')).error, 'No such worker');
  });

  test("prune leaves a workspace with worktrees in it alone, and lists the other repository's branch as checked "
      'out elsewhere', () async {
    final web = Worktrees(f.a);
    final api = Worktrees(f.b);
    expect(web.create('pip-1', 'web').error, isNull);
    expect(api.create('pip-1', 'api', f.a).error, isNull);
    final listed = await web.list();
    expect(
      [for (final w in listed.worktrees) (w.path, w.branch)],
      [(p.join('.agent-office', 'worktrees', 'pip-1', 'web'), 'office/pip-1')],
    );
    expect(listed.strays, isEmpty);
    final theirs = await api.list();
    expect(theirs.worktrees, isEmpty);
    expect(theirs.elsewhere, {'office/pip-1': p.join(f.a, '.agent-office', 'worktrees', 'pip-1', 'api')});
  });

  test('a worker across repositories goes home once its pull requests have merged and none is open, on any floor', () {
    GhPull pull(int number, String state, String head, [String? oid]) => GhPull.fromJson({
      'number': number,
      'title': 'PR $number',
      'state': state,
      'isDraft': false,
      'url': '',
      'author': '',
      'labels': <String>[],
      'reviewDecision': '',
      'headRefName': head,
      'headRefOid': ?oid,
      'baseRefName': 'main',
      'createdAt': '',
      'updatedAt': '',
      'additions': 0,
      'deletions': 0,
      'checks': 'none',
      'body': '',
      'closes': <int>[],
    });
    final w = WorkerInfo.fromJson({
      'id': 'pip',
      'kind': 'agent',
      'deskId': 'desk-1',
      'name': 'Pip',
      'color': '#fff',
      'status': 'done',
      'acked': true,
      'createdBy': 't',
      'createdAt': 0,
      'cols': 80,
      'rows': 24,
      'viewers': <String>[],
      'worktree': {'path': '.agent-office/worktrees/pip-1/web', 'branch': 'office/pip-1', 'base': 'a'},
      'repos': [
        {
          'floor': 'api',
          'name': 'api',
          'dir': '/api',
          'path': '.agent-office/worktrees/pip-1/api',
          'branch': 'office/pip-1',
          'base': 'b',
          'pr': {'number': 9, 'url': ''},
        },
      ],
    });
    final web = [pull(3, 'MERGED', 'office/pip-1', 'h3')];
    List<GhPull>? Function(String) floors(List<GhPull>? api) =>
        (id) => id == 'api' ? api : null;
    // api's PR still open, or not on api's list (yet): it stays.
    expect(landedWorkers([w], web, [], floors([pull(9, 'OPEN', 'office/pip-1')])), isEmpty);
    expect(landedWorkers([w], web, [], floors([])), isEmpty);
    expect(landedWorkers([w], web, [], floors(null)), isEmpty);
    // Both merged: it goes, with each merged head.
    final both = landedWorkers([w], web, [], floors([pull(9, 'MERGED', 'office/pip-1', 'h9')]));
    expect([for (final l in both) (l.worker.id, l.pr, l.head)], [('pip', 3, 'h3')]);
    expect(both.single.heads, {'api': 'h9'});
    expect(both.single.prs, ['web #3', 'api #9']);
    // Only api had work: its PR merging is enough.
    expect(landedWorkers([w], [], [], floors([pull(9, 'MERGED', 'office/pip-1', 'h9')])).map((l) => l.prs), [
      ['api #9'],
    ]);
    // web's own PR open: it stays.
    expect(
      landedWorkers([w], [pull(3, 'OPEN', 'office/pip-1')], [], floors([pull(9, 'MERGED', 'office/pip-1')])),
      isEmpty,
    );
  });
}
