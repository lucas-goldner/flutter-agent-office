import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'decor.dart' show ImageData, ImageError, ImageResult;

// What a worker changed, for the Changes window at its desk: the files it touched and their diff,
// against the branch the office was opened on. While anyone has the window open, the office polls
// that worker's checkout (its worktree, or the project folder) every couple of seconds and pushes
// the file list whenever it changes. Diffs of single files are fetched on demand.

const Duration _pollEvery = Duration(milliseconds: 2000);
const int _maxFiles = 400;
const int _maxDiff = 200000;

/// Untracked files bigger than this aren't read to count their lines.
const int _maxCountBytes = 8 * 1024 * 1024;

/// Pictures bigger than this aren't previewed.
const int _maxImageBytes = 10 * 1024 * 1024;

class ChangesTarget {
  const ChangesTarget({required this.name, required this.cwd, required this.rel, this.worktreeBase});

  /// The worker's name, for toasts.
  final String name;

  /// Absolute directory it works in.
  final String cwd;

  /// That directory relative to the office dir ('' for the project itself).
  final String rel;

  /// The commit its worktree branched from, when it has one.
  final String? worktreeBase;
}

class ChangesEvents {
  const ChangesEvents({required this.state, required this.toast, required this.refreshGitHub});

  final void Function(ChangesState state, List<String> clients) state;
  final void Function(String text, ToastLevel level) toast;

  /// Something changed on GitHub (a PR was opened): refresh the boards.
  final void Function() refreshGitHub;
}

class _Watch {
  final Set<String> clients = {};
  Timer? timer;
  bool polling = false;
  ChangesState? last;

  /// The last state without its timestamp, to send only real changes.
  String? lastKey;
  String? busy;
}

class _GitError implements Exception {
  _GitError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Result {
  _Result(this.out, this.err, this.code);
  final String out;
  final String err;
  final int code;
}

/// Runs a command; a non-zero exit is a result, not an error. Only "can't run it at all" throws.
Future<_Result> _run(String cmd, List<String> args, String cwd, [int timeout = 30000]) async {
  Process proc;
  try {
    proc = await Process.start(cmd, args, workingDirectory: cwd, environment: {'GIT_OPTIONAL_LOCKS': '0'});
  } on ProcessException catch (e) {
    if (e.errorCode == 2) throw _GitError('$cmd is not installed on the server');
    throw _GitError(e.message);
  }
  var killed = false;
  final timer = Timer(Duration(milliseconds: timeout), () {
    killed = true;
    proc.kill();
  });
  final out = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final code = await proc.exitCode;
  timer.cancel();
  final r = _Result(await out, await err, code);
  if (killed) throw _GitError('$cmd ${args[0]} took more than ${(timeout / 1000).round()}s and was stopped');
  return r;
}

/// Like _run(), for output that isn't text: a file's bytes at some commit. A failing command throws.
Future<Uint8List> _runBytes(String cmd, List<String> args, String cwd, int maxBytes, [int timeout = 30000]) async {
  Process proc;
  try {
    proc = await Process.start(cmd, args, workingDirectory: cwd, environment: {'GIT_OPTIONAL_LOCKS': '0'});
  } on ProcessException catch (e) {
    if (e.errorCode == 2) throw _GitError('$cmd is not installed on the server');
    throw _GitError(e.message);
  }
  var killed = false;
  final timer = Timer(Duration(milliseconds: timeout), () {
    killed = true;
    proc.kill();
  });
  final out = BytesBuilder(copy: false);
  var over = false;
  final reading = proc.stdout.listen((chunk) {
    if (over) return;
    out.add(chunk);
    if (out.length > maxBytes) {
      over = true;
      proc.kill();
    }
  }).asFuture<void>();
  final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final code = await proc.exitCode;
  timer.cancel();
  await reading;
  final r = _Result('', await err, code);
  if (killed) throw _GitError('$cmd ${args[0]} took more than ${(timeout / 1000).round()}s and was stopped');
  if (over) throw _GitError('$cmd ${args[0]}: output too big');
  if (code != 0) throw _GitError(_reason(r, '$cmd ${args[0]} failed'));
  return out.takeBytes();
}

/// Where a file of a checkout really is, or null when it's missing or leads outside the checkout
/// (a symlink pointing elsewhere, a path with `..` in it).
Future<String?> insideCheckout(String cwd, String file) async {
  try {
    final root = await Directory(cwd).resolveSymbolicLinks();
    final abs = await File(p.normalize(p.join(root, file))).resolveSymbolicLinks();
    final rel = p.relative(abs, from: root);
    if (rel == '.' || rel.isEmpty || rel == '..' || rel.startsWith('..${p.separator}') || p.isAbsolute(rel)) {
      return null;
    }
    return abs;
  } catch (_) {
    return null;
  }
}

final RegExp _fatal = RegExp(r'^(fatal|error):', caseSensitive: false);
final RegExp _fatalPrefix = RegExp(r'^(fatal|error):\s*', caseSensitive: false);

/// The line of stderr worth showing a person: git's "fatal:"/"error:" line, else the last one.
String _reason(_Result r, String fallback) {
  final lines = r.err.trim().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  String? line;
  for (final l in lines) {
    if (_fatal.hasMatch(l)) {
      line = l;
      break;
    }
  }
  line ??= lines.isEmpty ? null : lines.last;
  return line != null ? line.replaceFirst(_fatalPrefix, '') : fallback;
}

Future<String> _git(List<String> args, String cwd, [int? timeout]) async {
  final r = await _run('git', args, cwd, timeout ?? 30000);
  if (r.code != 0) throw _GitError(_reason(r, 'git ${args[0]} failed'));
  return r.out.endsWith('\n') ? r.out.substring(0, r.out.length - 1) : r.out;
}

/// Like _git(), but a failing command (a missing ref, no upstream) is just null.
Future<String?> _gitMaybe(List<String> args, String cwd) async {
  try {
    return await _git(args, cwd);
  } catch (_) {
    return null;
  }
}

/// Records of `git ... -z` output: NUL-separated fields.
List<String> _fields(String out) {
  final f = out.split('\u0000');
  if (f.isNotEmpty && f.last == '') f.removeLast();
  return f;
}

Future<({int lines, bool binary})> _countLines(String file) async {
  try {
    final s = await FileStat.stat(file);
    if (s.type != FileSystemEntityType.file || s.size > _maxCountBytes) return (lines: 0, binary: false);
    final buf = await File(file).readAsBytes();
    final head = buf.length > 8000 ? 8000 : buf.length;
    for (var i = 0; i < head; i++) {
      if (buf[i] == 0) return (lines: 0, binary: true);
    }
    var n = 0;
    for (final b in buf) {
      if (b == 10) n++;
    }
    if (buf.isNotEmpty && buf.last != 10) n++;
    return (lines: n, binary: false);
  } catch (_) {
    return (lines: 0, binary: false);
  }
}

Future<String> _signature(String file) async {
  try {
    final s = await FileStat.stat(file);
    if (s.type == FileSystemEntityType.notFound) return '';
    return '${s.size}:${s.modified.millisecondsSinceEpoch}';
  } catch (_) {
    return '';
  }
}

/// Roughly `String.prototype.localeCompare`: letters compare case-insensitively first, and a
/// lower-case letter sorts before its capital.
int _localeCompare(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  if (c != 0) return c;
  return b.compareTo(a);
}

/// A [ChangedFile] while it's being put together.
class _File {
  _File({required this.path, this.from, required this.status, this.uncommitted = false});
  final String path;
  final String? from;
  final ChangeStatus status;
  int additions = 0;
  int deletions = 0;
  bool binary = false;
  bool uncommitted;
  String sig = '';

  ChangedFile done() => ChangedFile(
    path: path,
    from: from,
    status: status,
    additions: additions,
    deletions: deletions,
    binary: binary,
    uncommitted: uncommitted,
    sig: sig,
  );
}

ChangesState _withBusy(ChangesState s, String? busy) => ChangesState(
  workerId: s.workerId,
  dir: s.dir,
  branch: s.branch,
  base: s.base,
  ahead: s.ahead,
  subject: s.subject,
  files: s.files,
  more: s.more,
  prBase: s.prBase,
  pr: s.pr,
  busy: busy,
  error: s.error,
  at: s.at,
);

String _errorText(Object err) => err is _GitError ? err.message : '$err';

class Changes {
  Changes(
    this._dir,

    /// The branch the office was opened on: what diffs are taken against and what PRs target.
    String? baseBranch,
    this._target,

    /// An open pull request whose head is that branch, from the PR board.
    this._openPull,
    this._events,
  ) : _baseBranch = baseBranch == 'HEAD' ? null : baseBranch;

  // ignore: unused_field
  final String _dir;
  final String? _baseBranch;
  final ChangesTarget? Function(String workerId) _target;
  final PrRef? Function(String branch) _openPull;
  final ChangesEvents _events;
  final Map<String, _Watch> _watches = {};

  /// PRs opened from the office, until the GitHub boards catch up.
  final Map<String, PrRef> _opened = {};

  void watch(String workerId, String clientId) {
    final w = _watches.putIfAbsent(workerId, _Watch.new);
    // An entry an action made (see _action()) has no timer yet.
    w.timer ??= Timer.periodic(_pollEvery, (_) => unawaited(_poll(workerId)));
    w.clients.add(clientId);
    final last = w.last;
    if (last != null) _events.state(last, [clientId]);
    unawaited(_poll(workerId, true));
  }

  void unwatch(String workerId, String clientId) {
    final w = _watches[workerId];
    if (w == null) return;
    w.clients.remove(clientId);
    // Keep the entry while an action runs, so its outcome still reaches whoever asked for it.
    if (w.clients.isEmpty && w.busy == null) _drop(workerId);
  }

  void unwatchAll(String clientId) {
    for (final id in [..._watches.keys]) {
      unwatch(id, clientId);
    }
  }

  /// The worker is gone.
  void forget(String workerId) => _drop(workerId);

  void stop() {
    for (final id in [..._watches.keys]) {
      _drop(id);
    }
  }

  /// The diff of one changed file, as `git diff` prints it; `error` says why there's none.
  Future<({String diff, bool truncated, String? error})> diff(String workerId, String filePath) async {
    ({String diff, bool truncated, String? error}) fail(String e) => (diff: '', truncated: false, error: e);
    final t = _target(workerId);
    if (t == null) return fail('No such worker');
    final changed = await _changedFile(workerId, t, filePath);
    if (changed.error != null) return fail(changed.error!);
    final file = changed.file!;
    try {
      String out;
      if (file.status == ChangeStatus.untracked) {
        // Exit code 1 just means the file isn't empty.
        final r = await _run('git', ['diff', '--no-index', '--', '/dev/null', file.path], t.cwd);
        if (r.code > 1) throw _GitError(_reason(r, 'git diff failed'));
        out = r.out;
      } else {
        final base = await _baseCommit(t);
        final r = await _run('git', ['diff', '-M', base.commit, '--', ?file.from, file.path], t.cwd);
        if (r.code != 0) throw _GitError(_reason(r, 'git diff failed'));
        out = r.out;
      }
      final truncated = out.length > _maxDiff;
      return (diff: truncated ? out.substring(0, _maxDiff) : out, truncated: truncated, error: null);
    } catch (err) {
      return fail(_errorText(err));
    }
  }

  /// One side of a changed picture, for the preview in the Changes window: 'old' is the file at the
  /// commit the diff is taken from, 'new' is what's in the checkout now. Only files in the worker's
  /// list of changes are served, and only pictures.
  Future<ImageResult> file(String workerId, String filePath, {required bool old}) async {
    if (changedImageType(filePath) == null) return const ImageError(415, 'Only pictures can be previewed');
    final t = _target(workerId);
    if (t == null) return const ImageError(404, 'No such worker');
    final changed = await _changedFile(workerId, t, filePath);
    if (changed.error != null) return ImageError(404, changed.error!);
    final file = changed.file!;
    // A renamed file was something else before; its old side is only a picture if that name was one.
    final name = old ? file.from ?? file.path : file.path;
    final type = changedImageType(name);
    if (type == null) return const ImageError(415, 'Only pictures can be previewed');
    const tooBig = 'That picture is over ${_maxImageBytes ~/ 1024 ~/ 1024} MB';
    try {
      if (!old) {
        if (file.status == ChangeStatus.deleted) return const ImageError(404, 'That file was deleted');
        final abs = await insideCheckout(t.cwd, name);
        if (abs == null) return const ImageError(404, 'That file is not in the checkout');
        final s = await FileStat.stat(abs);
        if (s.type != FileSystemEntityType.file) return const ImageError(404, 'That is not a file');
        if (s.size > _maxImageBytes) return const ImageError(413, tooBig);
        return ImageData(type, await File(abs).readAsBytes());
      }
      if (file.status == ChangeStatus.untracked || file.status == ChangeStatus.added) {
        return const ImageError(404, 'That file is new');
      }
      // `cat-file`, not `show`: show would run the file through any textconv filter the repo sets.
      final object = '${(await _baseCommit(t)).commit}:$name';
      final size = int.tryParse((await _git(['cat-file', '-s', object], t.cwd)).trim()) ?? 0;
      if (size > _maxImageBytes) return const ImageError(413, tooBig);
      return ImageData(type, await _runBytes('git', ['cat-file', 'blob', object], t.cwd, _maxImageBytes + 1));
    } on PathNotFoundException {
      // It went away between the last poll and this request.
      return const ImageError(404, 'That file is gone');
    } catch (err) {
      return ImageError(500, _errorText(err));
    }
  }

  /// Stages everything in the checkout and commits it.
  Future<String?> commit(String workerId, String message, String who) async {
    final msg = message.trim();
    if (msg.isEmpty) return 'The commit needs a message';
    return _action(workerId, 'Committing…', (t, w) async {
      await _git(['add', '-A'], t.cwd);
      await _git(['commit', '-q', '-m', msg], t.cwd, 120000);
      final subject = msg.split('\n')[0];
      _events.toast(
        '$who committed “${subject.length > 60 ? '${subject.substring(0, 59)}…' : subject}” at ${t.name}\'s desk',
        ToastLevel.info,
      );
      return null;
    });
  }

  /// Throws away uncommitted changes: one file's, or every one in the checkout.
  Future<String?> discard(String workerId, String? filePath, String who) async {
    return _action(workerId, 'Discarding…', (t, w) async {
      if (filePath != null) {
        ChangedFile? file;
        for (final f in w.last?.files ?? const <ChangedFile>[]) {
          if (f.path == filePath) {
            file = f;
            break;
          }
        }
        if (file == null || !file.uncommitted) return 'That file has no uncommitted changes';
        if (file.status == ChangeStatus.untracked) {
          await _git(['clean', '-f', '--', file.path], t.cwd);
        } else {
          await _git(['restore', '--source=HEAD', '--staged', '--worktree', '--', ?file.from, file.path], t.cwd);
        }
        _events.toast('$who discarded the changes to ${p.basename(file.path)} at ${t.name}\'s desk', ToastLevel.info);
      } else {
        final n = w.last?.files.where((f) => f.uncommitted).length ?? 0;
        await _git(['reset', '-q', '--hard'], t.cwd);
        await _git(['clean', '-fd'], t.cwd);
        final what = n > 0 ? '$n uncommitted change${n > 1 ? 's' : ''}' : 'the uncommitted changes';
        _events.toast('$who discarded $what at ${t.name}\'s desk', ToastLevel.info);
      }
      return null;
    });
  }

  /// Pushes the branch and opens a pull request for it with `gh`.
  Future<String?> pullRequest(String workerId, String title, String body, String who) async {
    if (title.trim().isEmpty) return 'The pull request needs a title';
    return _action(workerId, 'Pushing the branch and opening a pull request…', (t, w) async {
      final s = w.last ?? await _compute(workerId, t);
      final branch = s.branch;
      final prBase = s.prBase;
      if (branch == null || branch.isEmpty || prBase == null || prBase.isEmpty) {
        return "This checkout isn't on a branch of its own";
      }
      if (s.pr != null) return "There's already a pull request for $branch: ${s.pr!.url}";
      if (s.files.any((f) => f.uncommitted)) return 'Commit the changes first';
      if (s.ahead == 0) return '$branch has no commits that $prBase lacks';
      final remotes = (await _git(['remote'], t.cwd)).split('\n').where((r) => r.isNotEmpty).toList();
      final remote = remotes.contains('origin') ? 'origin' : (remotes.isEmpty ? null : remotes.first);
      if (remote == null) return 'This project has no git remote to push to';
      await _git(['push', '-u', remote, branch], t.cwd, 120000);
      final r = await _run(
        'gh',
        ['pr', 'create', '--head', branch, '--base', prBase, '--title', title.trim(), '--body', body],
        t.cwd,
        120000,
      );
      final url = r.out.trim().split('\n').last;
      if (r.code != 0 || !RegExp(r'^https?://').hasMatch(url)) {
        throw _GitError(_reason(r, url.isNotEmpty ? url : 'gh pr create failed'));
      }
      final number = int.tryParse(RegExp(r'/(\d+)$').firstMatch(url)?.group(1) ?? '') ?? 0;
      _opened[branch] = PrRef(number: number, url: url);
      _events.toast('$who opened a pull request for ${t.name}: $url', ToastLevel.info);
      _events.refreshGitHub();
      return null;
    });
  }

  // ---------------------------------------------------------------------------

  /// A file in the worker's list of changes, looking again when it isn't in the last one.
  Future<({ChangedFile? file, String? error})> _changedFile(String workerId, ChangesTarget t, String filePath) async {
    var state = _watches[workerId]?.last;
    if (state == null || !state.files.any((f) => f.path == filePath)) state = await _compute(workerId, t);
    for (final f in state.files) {
      if (f.path == filePath) return (file: f, error: null);
    }
    return (file: null, error: state.error ?? 'That file has no changes');
  }

  void _drop(String workerId) {
    final w = _watches.remove(workerId);
    w?.timer?.cancel();
  }

  /// Runs one commit / discard / PR at a time per worker, showing watchers that it's in progress.
  Future<String?> _action(String workerId, String label, Future<String?> Function(ChangesTarget t, _Watch w) fn) async {
    final t = _target(workerId);
    if (t == null) return 'No such worker';
    final w = _watches.putIfAbsent(workerId, _Watch.new);
    final busy = w.busy;
    if (busy != null) return 'Hold on — still ${busy.toLowerCase().replaceFirst(RegExp(r'…$'), '')}';
    w.busy = label;
    final last = w.last;
    if (last != null) _push(w, _withBusy(last, label));
    String? error;
    try {
      error = await fn(t, w);
    } catch (err) {
      error = _errorText(err);
    }
    w.busy = null;
    w.lastKey = null; // the next poll always reaches the watchers, to clear the busy state
    await _poll(workerId, true);
    if (w.clients.isEmpty) _drop(workerId);
    return error;
  }

  Future<void> _poll(String workerId, [bool now = false]) async {
    final w = _watches[workerId];
    if (w == null || w.polling || (!now && w.clients.isEmpty)) return;
    w.polling = true;
    try {
      final t = _target(workerId);
      var state = t != null ? await _compute(workerId, t) : _errorState(workerId, '', 'No such worker');
      if (w.busy != null) state = _withBusy(state, w.busy);
      final key = jsonEncode({...state.toJson(), 'at': 0});
      if (key != w.lastKey) {
        w.lastKey = key;
        _push(w, state);
      }
      w.last = state;
    } finally {
      w.polling = false;
    }
  }

  void _push(_Watch w, ChangesState state) {
    w.last = state;
    if (w.clients.isNotEmpty) _events.state(state, [...w.clients]);
  }

  /// The commit the diff is taken from, and what to call it.
  Future<({String commit, String label, String? branch, String? prBase})> _baseCommit(ChangesTarget t) async {
    String head;
    try {
      head = await _git(['rev-parse', '--verify', '--quiet', 'HEAD'], t.cwd);
    } catch (_) {
      throw _GitError('No commits yet');
    }
    final abbrev = await _gitMaybe(['rev-parse', '--abbrev-ref', 'HEAD'], t.cwd);
    final branch = abbrev == null || abbrev.isEmpty ? 'HEAD' : abbrev;
    final onBranch = branch != 'HEAD';
    final baseBranch = _baseBranch;
    String? ref;
    var label = 'HEAD';
    if (baseBranch != null &&
        baseBranch.isNotEmpty &&
        branch != baseBranch &&
        ((await _gitMaybe(['rev-parse', '--verify', '--quiet', 'refs/heads/$baseBranch'], t.cwd)) ?? '').isNotEmpty) {
      ref = baseBranch;
      label = baseBranch;
    } else if (t.worktreeBase != null && t.worktreeBase!.isNotEmpty && branch != baseBranch) {
      ref = t.worktreeBase;
      label = t.worktreeBase!.length > 7 ? t.worktreeBase!.substring(0, 7) : t.worktreeBase!;
    } else {
      // On the base branch itself: what isn't pushed yet, when it tracks a remote.
      final up = await _gitMaybe(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'], t.cwd);
      if (up != null && up.isNotEmpty) {
        ref = up;
        label = up;
      }
    }
    final mb = ref != null ? await _gitMaybe(['merge-base', ref, 'HEAD'], t.cwd) : null;
    final commit = mb != null && mb.isNotEmpty ? mb : head;
    final prBase = onBranch && baseBranch != null && baseBranch.isNotEmpty && branch != baseBranch ? baseBranch : null;
    return (commit: commit, label: label, branch: onBranch ? branch : null, prBase: prBase);
  }

  Future<ChangesState> _compute(String workerId, ChangesTarget t) async {
    try {
      final base = await _baseCommit(t);
      final outs = await Future.wait([
        _git(['diff', '--numstat', '-M', '-z', base.commit], t.cwd),
        _git(['diff', '--name-status', '-M', '-z', base.commit], t.cwd),
        _git(['status', '--porcelain=v1', '-z', '-uall'], t.cwd),
      ]);
      final [numstat, names, status] = outs;
      final files = <String, _File>{};
      // `--name-status -z`: "M\0path\0", renames "R100\0old\0new\0".
      final ns = _fields(names);
      for (var i = 0; i < ns.length;) {
        final rec = ns[i++];
        final kind = rec.isEmpty ? '' : rec[0];
        final renamed = kind == 'R' || kind == 'C';
        String? from;
        if (renamed) {
          from = i < ns.length ? ns[i] : null;
          i++;
        }
        if (i >= ns.length) break;
        final path = ns[i++];
        final st = renamed
            ? ChangeStatus.renamed
            : switch (kind) {
                'A' => ChangeStatus.added,
                'D' => ChangeStatus.deleted,
                'T' => ChangeStatus.typeChanged,
                _ => ChangeStatus.modified,
              };
        files[path] = _File(path: path, from: from, status: st);
      }
      // `--numstat -z`: "add\tdel\tpath\0", renames "add\tdel\t\0old\0new\0"; binaries count as "-".
      final sts = _fields(numstat);
      for (var i = 0; i < sts.length;) {
        final parts = sts[i++].split('\t');
        final a = parts[0];
        final d = parts.length > 1 ? parts[1] : '';
        final p0 = parts.length > 2 ? parts[2] : null;
        String? path;
        if (p0 == '') {
          i += 2;
          path = i - 1 < sts.length ? sts[i - 1] : null;
        } else {
          path = p0;
        }
        final f = path == null ? null : files[path];
        if (f == null) continue;
        if (a == '-') {
          f.binary = true;
        } else {
          f.additions = int.tryParse(a) ?? 0;
          f.deletions = int.tryParse(d) ?? 0;
        }
      }
      // `status --porcelain -z`: "XY path\0", renames "XY new\0old\0", untracked "?? path\0".
      final untracked = <String>[];
      final sf = _fields(status);
      for (var i = 0; i < sf.length;) {
        final rec = sf[i++];
        final xy = rec.length >= 2 ? rec.substring(0, 2) : rec;
        final path = rec.length > 3 ? rec.substring(3) : '';
        if (xy == '??') {
          untracked.add(path);
          continue;
        }
        files[path]?.uncommitted = true;
        if (RegExp('[RC]').hasMatch(xy)) {
          final old = i < sf.length ? sf[i] : null;
          i++;
          if (old != null) files[old]?.uncommitted = true;
        }
      }
      for (final path in untracked) {
        files.putIfAbsent(path, () => _File(path: path, status: ChangeStatus.untracked, uncommitted: true));
      }
      final all = files.values.toList()..sort((a, b) => _localeCompare(a.path, b.path));
      final list = all.take(_maxFiles).toList();
      await Future.wait(
        list.map((f) async {
          final abs = p.join(t.cwd, f.path);
          if (f.status == ChangeStatus.untracked) {
            final c = await _countLines(abs);
            f.additions = c.lines;
            f.binary = c.binary;
          }
          f.sig = f.status == ChangeStatus.deleted ? '' : await _signature(abs);
        }),
      );
      final ahead =
          int.tryParse((await _gitMaybe(['rev-list', '--count', '${base.commit}..HEAD'], t.cwd) ?? '').trim()) ?? 0;
      final subject = ahead > 0 ? await _gitMaybe(['log', '-1', '--format=%s'], t.cwd) : null;
      final branch = base.branch;
      final pr = branch != null ? _opened[branch] ?? _openPull(branch) : null;
      return ChangesState(
        workerId: workerId,
        dir: t.rel,
        branch: branch ?? 'HEAD',
        base: base.label,
        ahead: ahead,
        subject: subject,
        files: [for (final f in list) f.done()],
        more: all.length - list.length,
        prBase: base.prBase,
        pr: pr,
        at: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (err) {
      return _errorState(workerId, t.rel, _errorText(err));
    }
  }
}

ChangesState _errorState(String workerId, String dir, String error) => ChangesState(
  workerId: workerId,
  dir: dir,
  base: 'HEAD',
  ahead: 0,
  files: const [],
  more: 0,
  error: error,
  at: DateTime.now().millisecondsSinceEpoch,
);
