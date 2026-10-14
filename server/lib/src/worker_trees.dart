// A worker's own worktree, or its workspace across repositories: making them, keeping each worker's
// branch up to date with the one it's really on, opening its pull requests, and what becomes of them
// when the worker goes home. Upstream's server/workers/worktree.ts and the manager half of pr.ts.

part of 'workers.dart';

/// The folder each checkout gets in a workspace: its folder's name, made safe, with -2, -3… when two
/// checkouts share one (owner-a/api and owner-b/api).
List<String> workspaceNames(List<String> dirs) {
  final used = <String>{};
  return [
    for (final dir in dirs)
      () {
        var base = p
            .basename(p.normalize(p.absolute(dir)))
            .replaceAll(RegExp(r'[^\w.-]+'), '-')
            .replaceFirst(RegExp(r'^[.-]+'), '');
        if (base.isEmpty) base = 'project';
        if (workspaceFiles.contains(base)) base = '$base-repo';
        var name = base;
        for (var n = 2; used.contains(name.toLowerCase()); n++) {
          name = '$base-$n';
        }
        used.add(name.toLowerCase());
        return name;
      }(),
  ];
}

/// Takes a workspace folder away once its worktrees are gone: only the brief the office wrote, never
/// anything else left in it.
void clearWorkspace(String abs) {
  try {
    for (final e in Directory(abs).listSync(followLinks: false)) {
      if (workspaceFiles.contains(p.basename(e.path))) File(e.path).deleteSync();
    }
    Directory(abs).deleteSync();
  } catch (_) {
    // already gone, or something else is in it: it stays
  }
}

/// The other repositories of a worker across repositories, as workers.json kept them.
List<WorkerRepo>? validRepos(Object? raw) {
  if (raw is! List) return null;
  String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
  final repos = <WorkerRepo>[];
  for (final r in raw) {
    if (r is! Map) continue;
    final floor = str(r['floor']), name = str(r['name']), dir = str(r['dir']), rel = str(r['path']);
    final branch = str(r['branch']), base = str(r['base']);
    if (floor == null || name == null || dir == null || rel == null || branch == null || base == null) continue;
    final pr = r['pr'];
    repos.add(
      WorkerRepo(
        floor: floor,
        name: name,
        repo: str(r['repo']),
        dir: dir,
        path: rel,
        branch: branch,
        base: base,
        from: str(r['from']),
        pr: pr is Map && pr['number'] is num && pr['url'] is String
            ? PrRef(number: (pr['number'] as num).toInt(), url: pr['url'] as String)
            : null,
      ),
    );
  }
  return repos.isEmpty ? null : repos;
}

/// [r] with its pull request set.
WorkerRepo _withPr(WorkerRepo r, PrRef pr) => WorkerRepo(
  floor: r.floor,
  name: r.name,
  repo: r.repo,
  dir: r.dir,
  path: r.path,
  branch: r.branch,
  base: r.base,
  from: r.from,
  pr: pr,
);

/// One worktree of a worker (across repositories, one of several): its folder in the workspace, git
/// plumbing for its repository, its worktree in that repository's terms, and the commit its merged
/// pull request delivered, when known.
typedef _Tree = ({String name, String dir, Worktrees trees, WorktreeRef ref, String? landed});

extension _WorkerTrees on WorkerManager {
  /// The workspace of a worker across repositories: `.agent-office/worktrees/<slug>`, with a worktree of
  /// this floor's project and of each of [repos] in it, all on `office/<slug>`, and a brief for the agent
  /// (the 'worker.repos' prompt, as CLAUDE.md and AGENTS.md). All or nothing: when one repository
  /// can't have its worktree, the ones already made are taken out again.
  ({WorkerWorktree? worktree, List<WorkerRepo> repos, List<String> notes, String? error}) _makeWorkspace(
    String slug,
    List<RepoSource> repos,
  ) {
    ({WorkerWorktree? worktree, List<WorkerRepo> repos, List<String> notes, String? error}) failWith(String why) =>
        (worktree: null, repos: const [], notes: const [], error: why);
    // A branch can only be checked out once per repository, and two floors can be checkouts of the same one.
    final seen = <String, String>{};
    final own = _trees.commonDir();
    if (own == null) return failWith("This floor's project isn't a git checkout");
    seen[own] = "this floor's project";
    for (final r in repos) {
      final common = Worktrees(r.dir).commonDir();
      if (common == null) return failWith("${r.name} isn't a git checkout");
      final twin = seen[common];
      if (twin != null) return failWith('${r.name} is the same repository as $twin');
      seen[common] = r.name;
    }
    final names = workspaceNames([_dir, for (final r in repos) r.dir]);
    final made = <({Worktrees trees, WorktreeRef ref})>[];
    ({WorkerWorktree? worktree, List<WorkerRepo> repos, List<String> notes, String? error}) fail(String why) {
      // Fresh branches with nothing on them: nothing is lost taking them out again.
      unawaited(() async {
        for (final m in made.reversed) {
          await m.trees.remove(m.ref, WorktreeCleanup.all);
        }
        clearWorkspace(p.join(_dir, worktreesDir, slug));
      }());
      return failWith(why);
    }

    final first = _trees.create(slug, names[0]);
    final primary = first.worktree;
    if (primary == null) return fail(first.error!);
    final notes = [if (first.note != null) '${names[0]} ${first.note}'];
    made.add((trees: _trees, ref: _ref(primary)));
    final others = <WorkerRepo>[];
    for (var i = 0; i < repos.length; i++) {
      final r = repos[i];
      final trees = Worktrees(r.dir);
      final wt = trees.create(slug, names[i + 1], _dir);
      final tree = wt.worktree;
      if (tree == null) return fail('${r.name}: ${wt.error}');
      if (wt.note != null) notes.add('${names[i + 1]} ${wt.note}');
      made.add((
        trees: trees,
        ref: WorktreeRef(
          path: p.relative(p.join(_dir, tree.path), from: r.dir),
          branch: tree.branch,
          base: tree.base,
        ),
      ));
      others.add(
        WorkerRepo(
          floor: r.floor,
          name: names[i + 1],
          repo: r.repo,
          dir: r.dir,
          path: tree.path,
          branch: tree.branch,
          base: tree.base,
          from: tree.from,
        ),
      );
    }
    try {
      _writeBrief(primary, [
        for (var i = 0; i < repos.length; i++)
          (name: names[i + 1], project: repos[i].repo ?? repos[i].name, from: others[i].from),
      ]);
    } catch (err) {
      return fail("Could not write the workspace's brief: ${_messageOf(err)}");
    }
    return (worktree: primary, repos: others, notes: notes, error: null);
  }

  /// The brief in the workspace of a worker across repositories, which folder is which project (the
  /// 'worker.repos' prompt), as CLAUDE.md and AGENTS.md. [primary] is its own floor's worktree, in the
  /// workspace like [others]. Throws when it can't be written.
  void _writeBrief(WorkerWorktree primary, List<({String name, String project, String? from})> others) {
    final home = originRepo(_dir) ?? p.basename(_dir);
    String line(String name, String project, String? from, [String note = '']) =>
        '- `$name/`: $project${from != null ? ', cut from $from' : ''}$note';
    final brief = officePrompt(_prompts, 'worker.repos', {
      'branch': primary.branch,
      'home': home,
      'repos': [
        line(p.basename(primary.path), home, primary.from, " (this floor's project)"),
        for (final o in others) line(o.name, o.project, o.from),
      ].join('\n'),
    });
    for (final file in workspaceFiles) {
      File(p.join(_dir, p.dirname(primary.path), file)).writeAsStringSync('${brief.trim()}\n');
    }
  }

  /// Each worktree a worker across repositories has, its own floor's first (see [_Tree]).
  List<_Tree> _treesOf(LiveInfo info, [String? landed, Map<String, String?>? landedRepos]) {
    final wt = info.worktree!;
    return [
      (name: p.basename(wt.path), dir: _dir, trees: _trees, ref: _ref(wt), landed: landed),
      for (final r in info.repos ?? const <WorkerRepo>[])
        (
          name: r.name,
          dir: r.dir,
          trees: Worktrees(r.dir),
          ref: WorktreeRef(
            path: p.relative(p.join(_dir, r.path), from: r.dir),
            branch: r.branch,
            base: r.base,
          ),
          landed: landedRepos?[r.floor],
        ),
    ];
  }

  /// Sending home a worker across repositories: what `kill` does with a worktree, for each of its
  /// worktrees, and then its workspace.
  Future<({String? note, String? error})> _clearRepos(
    LiveInfo info,
    WorktreeCleanup? cleanup,
    String? landed,
    Map<String, String?>? landedRepos,
  ) async {
    final trees = _treesOf(info, landed, landedRepos);
    final name = info.name;
    final branch = info.worktree!.branch;
    final where = trees.map((t) => t.name).join(', ');
    if (cleanup == null) {
      final held = [
        for (final t in trees) (name: t.name, work: describeWork(await t.trees.inspect(t.ref, t.landed))),
      ].where((t) => t.work.isNotEmpty).toList();
      if (held.isNotEmpty) {
        return (
          note:
              "Kept $name's worktrees and branch $branch in $where — ${held.map((t) => '${t.name} has ${t.work}').join('; ')}",
          error: null,
        );
      }
      cleanup = WorktreeCleanup.all;
    }
    if (cleanup == WorktreeCleanup.keep)
      return (note: "Kept $name's worktrees and branch $branch in $where", error: null);
    final how = cleanup;
    final errors = [
      for (final e in await Future.wait([
        for (final t in trees) t.trees.remove(t.ref, how).then((error) => error != null ? '${t.name}: $error' : null),
      ]))
        ?e,
    ];
    if (errors.isNotEmpty) {
      return (note: null, error: "Couldn't delete all of $name's worktrees: ${errors.join('; ')}");
    }
    clearWorkspace(p.join(_dir, workspaceOf(info.worktree, info.repos)!));
    return (
      note: how == WorktreeCleanup.all
          ? "Deleted $name's worktrees and branch $branch in $where"
          : "Deleted $name's worktrees in $where and kept branch $branch",
      error: null,
    );
  }

  /// Whether any worktree of a worker across repositories holds work its merged pull requests didn't
  /// deliver ([landed] and [landedRepos], as for kill): then it doesn't go home by itself yet.
  Future<bool> _holdsWork(String id, String? landed, Map<String, String?>? landedRepos) async {
    final info = _workers[id]?.info;
    if (info?.worktree == null) return false;
    for (final t in _treesOf(info!, landed, landedRepos)) {
      if (describeWork(await t.trees.inspect(t.ref, t.landed)).isNotEmpty) return true;
    }
    return false;
  }

  /// What a worker's worktree holds, so whoever sends it home knows what deleting it would lose.
  Future<WorktreeState?> _inspectTrees(String id) async {
    final w = _workers[id];
    final info = w?.info;
    if (w == null || info?.worktree == null) return null;
    if (info!.repos?.isNotEmpty != true) {
      await _syncBranch(w);
      final wt = w.info.worktree;
      return wt == null ? null : _trees.inspect(_ref(wt));
    }
    final repos = [for (final t in _treesOf(info)) (name: t.name, state: await t.trees.inspect(t.ref))];
    int sum(int Function(WorktreeState s) k) => repos.fold(0, (n, r) => n + k(r.state));
    final errors = [
      for (final r in repos)
        if (r.state.error != null) '${r.name}: ${r.state.error}',
    ];
    return WorktreeState(
      exists: repos.every((r) => r.state.exists),
      dirty: sum((s) => s.dirty),
      ahead: sum((s) => s.ahead),
      unpushed: sum((s) => s.unpushed),
      error: errors.isEmpty ? null : errors.join('; '),
      repos: repos,
    );
  }

  /// Keeps `worktree.branch` on the branch the worktree is actually on. Agents often make their own
  /// (`git checkout -b fix-x`, because the task or the repo's CLAUDE.md says to) and open the pull
  /// request from there with gh, and the PR badge, O at the desk and sending it home go by it. A
  /// meeting's worktree stays the meeting's, and a worker across repositories keeps the branch it was
  /// given in each (see [_openPrs]).
  Future<void> _syncBranch(_Worker w) async {
    final wt = w.info.worktree;
    if (wt == null || w.info.meeting != null || (w.info.repos?.isNotEmpty ?? false)) return;
    final now = await _current(wt);
    // Sent home meanwhile, or another look got there first.
    if (identical(now, wt) || _workers[w.info.id] != w || !identical(w.info.worktree, wt)) return;
    w.info.worktree = now;
    _emitUpdate(w);
    _persist();
  }

  /// A worktree on the branch it's on now, with the office's own branch kept in `made`; the same one
  /// when nothing moved.
  Future<WorkerWorktree> _current(WorkerWorktree wt) async {
    final live = await _trees.branchOf(_ref(wt));
    if (live == null) return wt;
    var made = wt.made ?? (live == wt.branch ? null : wt.branch);
    // Back on it, or renamed it (`git branch -m fix-x`): the branch it's on is the office's own.
    if (made == live || (made != null && await _trees.renamedTo(made, live))) made = null;
    if (live == wt.branch && made == wt.made) return wt;
    return WorkerWorktree(path: wt.path, branch: live, base: wt.base, from: wt.from, made: made);
  }

  /// What becomes of the worktree of a worker just sent home (see [WorkerManager.kill]): [cleanup], or
  /// with no choice given, the worktree and branch go only when they hold no work, where [landed] (its
  /// merged pull request's head commit) is work delivered. Resolves with a line for the team about it.
  Future<({String? note, String? error})> _sendHome(
    LiveInfo info,
    WorktreeCleanup? cleanup,
    String? landed,
    Map<String, String?>? landedRepos,
  ) async {
    const none = (note: null, error: null);
    final saved = info.worktree;
    // A meeting's worktree is everyone at the table's: the meeting tidies it away once they've all gone.
    if (saved == null || info.meeting != null) return none;
    if (info.repos?.isNotEmpty ?? false) return _clearRepos(info, cleanup, landed, landedRepos);
    // On the branch its work is on, should it have switched since it last came to rest.
    final wt = _ref(await _current(saved));
    final name = info.name;
    if (cleanup == null) {
      final work = describeWork(await _trees.inspect(wt, landed));
      if (work.isNotEmpty) return (note: "Kept $name's worktree and branch ${wt.branch} — it has $work", error: null);
      cleanup = WorktreeCleanup.all;
    }
    if (cleanup == WorktreeCleanup.keep) return (note: "Kept $name's worktree and branch ${wt.branch}", error: null);
    var gone = wt;
    var kept = '';
    final made = wt.made;
    if (cleanup == WorktreeCleanup.all && made != null) {
      if (!await _trees.hasBranch(made)) {
        // The agent deleted the office's branch (a rename is followed, see _current), so git can't say
        // whether the one it's on is its own or was there before it: that one stays.
        cleanup = WorktreeCleanup.worktree;
      } else {
        // The office's own branch stays while it has commits that no remote, the project's checkout
        // or the branch it's on has.
        final work = await _trees.wouldLose(made, [wt.branch]);
        if (work.isNotEmpty) kept = ' and kept branch $made — it has $work';
        // A branch it made itself goes with it; one that was there before it (main, say) isn't the office's to delete.
        if (await _trees.madeSince(wt.branch, made)) {
          if (work.isNotEmpty) gone = WorktreeRef(path: wt.path, branch: wt.branch, base: wt.base);
        } else if (work.isNotEmpty) {
          cleanup = WorktreeCleanup.worktree;
        } else {
          gone = WorktreeRef(path: wt.path, branch: made, base: wt.base);
        }
      }
    }
    final error = await _trees.remove(gone, cleanup);
    if (error != null) return (note: null, error: "Couldn't delete $name's worktree: $error");
    if (cleanup == WorktreeCleanup.worktree) {
      return (note: "Deleted $name's worktree${kept.isNotEmpty ? kept : ' and kept branch ${wt.branch}'}", error: null);
    }
    return (note: "Deleted $name's worktree and branch ${gone.branch}${kept.isNotEmpty ? ',$kept' : ''}", error: null);
  }

  // --- pull requests ------------------------------------------------------------------------------

  Future<({List<OpenedPr> prs, List<String> failed, String? error})> _openPr(String id, String by) async {
    ({List<OpenedPr> prs, List<String> failed, String? error}) fail(String error) =>
        (prs: const [], failed: const [], error: error);
    final w = _workers[id];
    if (w == null) return fail('No such worker');
    final info = w.info;
    final wt = info.worktree;
    if (wt == null) {
      return fail('${info.name} works in the main checkout — only workers with their own worktree can open a PR');
    }
    if (info.prOpening == true) return fail("${info.name}'s pull request is already being opened");
    if (isBusy(info.status)) {
      final what = info.status == WorkerStatus.needsInput ? 'waiting on input' : info.status.wire;
      return fail("${info.name} is still $what — wait until it's done");
    }
    if (info.repos?.isNotEmpty ?? false) return _openPrs(w, by);
    final cwd = p.join(_dir, wt.path);
    if (!Directory(cwd).existsSync()) return fail("${info.name}'s worktree is gone (${wt.path})");
    info.prOpening = true;
    _emitUpdate(w);
    try {
      // The PR comes from the branch its work is on, which may be one it made itself.
      await _syncBranch(w);
      final branch = info.worktree?.branch ?? wt.branch;
      final commits = (await _run('git', [
        'log',
        '--reverse',
        '--format=%h %s',
        '${wt.base}..$branch',
      ], cwd)).split('\n').where((l) => l.isNotEmpty).toList();
      final dirty = (await _run('git', ['status', '--porcelain'], cwd)) != '';
      if (commits.isEmpty) {
        return fail(
          dirty
              ? "${info.name} hasn't committed anything yet — ask it to commit first"
              : '${info.name} has no commits on $branch yet',
        );
      }
      final open = await findOpenPr(branch, cwd);
      if (open != null) {
        info.pr = open;
        _persist();
        return (
          prs: [OpenedPr(number: open.number, url: open.url, existed: true, dirty: dirty)],
          failed: const <String>[],
          error: null,
        );
      }
      await _run('git', ['push', '-u', 'origin', branch], cwd, 90000);
      final base = await _pushedBranch([wt.from, _trees.currentBranch()], branch);
      final draft = draftPr(info, commits, by);
      final pr = await createPr(branch, base, draft.title, draft.body, cwd);
      info.pr = pr;
      _persist();
      return (
        prs: [OpenedPr(number: pr.number, url: pr.url, existed: false, dirty: dirty)],
        failed: const <String>[],
        error: null,
      );
    } catch (err) {
      return fail("Couldn't open a PR for ${info.name}: ${_messageOf(err)}");
    } finally {
      info.prOpening = false;
      // The worker may have been sent home meanwhile; an update would bring it back as a ghost.
      if (_workers[id] == w) _emitUpdate(w);
    }
  }

  /// 'worker.pr' for a worker across repositories: a pull request in each repository it committed to
  /// (or the one its branch already has there), with every one of them listed in each one's
  /// description, so they're reviewed and merged together. The issue its task came from is closed by
  /// its own floor's pull request; the others only mention it.
  Future<({List<OpenedPr> prs, List<String> failed, String? error})> _openPrs(_Worker w, String by) async {
    ({List<OpenedPr> prs, List<String> failed, String? error}) fail(String error) =>
        (prs: const [], failed: const [], error: error);
    final info = w.info;
    final wt = info.worktree!;
    final home = originRepo(_dir);
    final repos = info.repos!;
    final parts =
        <({String name, String dir, String path, String branch, String base, String? from, PrRef? pr, int? index})>[
          (
            name: p.basename(wt.path),
            dir: _dir,
            path: wt.path,
            branch: wt.branch,
            base: wt.base,
            from: wt.from,
            pr: info.pr,
            index: null,
          ),
          for (var i = 0; i < repos.length; i++)
            (
              name: repos[i].name,
              dir: repos[i].dir,
              path: repos[i].path,
              branch: repos[i].branch,
              base: repos[i].base,
              from: repos[i].from,
              pr: repos[i].pr,
              index: i,
            ),
        ];
    void set(int? index, PrRef pr) {
      if (index == null) {
        info.pr = pr;
      } else {
        final list = List.of(info.repos!);
        list[index] = _withPr(list[index], pr);
        info.repos = list;
      }
    }

    final gone = parts.where((x) => !Directory(p.join(_dir, x.path)).existsSync()).toList();
    if (gone.isNotEmpty) {
      return fail(
        "${info.name}'s worktree${gone.length > 1 ? 's' : ''} of ${gone.map((x) => x.name).join(', ')} "
        '${gone.length > 1 ? 'are' : 'is'} gone',
      );
    }
    info.prOpening = true;
    _emitUpdate(w);
    final prs = <({OpenedPr pr, String cwd})>[];
    final failed = <String>[];
    final uncommitted = <String>[];
    try {
      for (final x in parts) {
        final cwd = p.join(_dir, x.path);
        try {
          final dirty = (await _run('git', ['status', '--porcelain'], cwd)) != '';
          final known = x.pr ?? await findOpenPr(x.branch, cwd);
          if (known != null) {
            set(x.index, known);
            prs.add((
              pr: OpenedPr(repo: x.name, number: known.number, url: known.url, existed: true, dirty: dirty),
              cwd: cwd,
            ));
            continue;
          }
          final commits = (await _run('git', [
            'log',
            '--reverse',
            '--format=%h %s',
            '${x.base}..${x.branch}',
          ], cwd)).split('\n').where((l) => l.isNotEmpty).toList();
          if (commits.isEmpty) {
            if (dirty) uncommitted.add(x.name);
            continue;
          }
          await _run('git', ['push', '-u', 'origin', x.branch], cwd, 90000);
          final base = await _pushedBranch([x.from, Worktrees(x.dir).currentBranch()], x.branch, x.dir);
          final draft = draftPr(info, commits, by, other: x.index == null ? null : (home: home));
          final pr = await createPr(x.branch, base, draft.title, draft.body, cwd);
          set(x.index, pr);
          _persist();
          prs.add((pr: OpenedPr(repo: x.name, number: pr.number, url: pr.url, existed: false, dirty: dirty), cwd: cwd));
        } catch (err) {
          failed.add("Couldn't open a PR in ${x.name}: ${_messageOf(err)}");
        }
      }
      if (prs.isEmpty) {
        if (failed.isNotEmpty) return fail(failed.join('; '));
        return fail(
          uncommitted.isNotEmpty
              ? "${info.name} hasn't committed anything yet in ${uncommitted.join(', ')} — ask it to commit first"
              : '${info.name} has no commits on ${wt.branch} yet in any of its repositories',
        );
      }
      if (prs.length > 1 && prs.any((x) => !x.pr.existed)) {
        final list = [for (final x in prs) (repo: x.pr.repo, url: x.pr.url)];
        for (final x in prs) {
          try {
            final body = await gh(['pr', 'view', x.pr.url, '--json', 'body', '--jq', '.body'], x.cwd, 30000);
            final next = withRelated(body, relatedBlock(list, x.pr.url, wt.branch));
            if (next != body) await gh(['pr', 'edit', x.pr.url, '--body', next], x.cwd, 60000);
          } catch (err) {
            failed.add("Couldn't list the other pull requests on ${x.pr.repo} #${x.pr.number}: ${_messageOf(err)}");
          }
        }
      }
      _persist();
      return (prs: [for (final x in prs) x.pr], failed: failed, error: null);
    } finally {
      info.prOpening = false;
      if (_workers[info.id] == w) _emitUpdate(w);
    }
  }

  /// The first of these branches that exists on origin (of [dir]'s repository), for a PR base. None:
  /// gh picks the default branch.
  Future<String?> _pushedBranch(List<String?> candidates, String not, [String? dir]) async {
    for (final c in candidates) {
      if (c == null || c.isEmpty || c == not) continue;
      try {
        await _run('git', ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/$c'], dir ?? _dir);
        return c;
      } catch (_) {
        // not on the remote (or never fetched)
      }
    }
    return null;
  }
}
