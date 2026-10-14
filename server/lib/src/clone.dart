// One `gh repo clone`, run so the office can see how it's getting on. git's progress goes to a log
// file, which the office reads every second: that says how far along it is, and a log that stops
// growing is a clone that's stuck. The clone runs in its own session with no terminal
// (ProcessStartMode.detached, stdin from /dev/null), so an ssh host-key question or a password prompt
// fails it straight away instead of waiting, unseen, on the terminal the office was started in.
// Writing to a file (not a pipe) and being its own process group lets it outlive an office restart,
// for the next office to pick up (see CloneRun.adopt). Port of upstream's src/server/clone.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:office_shared/shared.dart' show CloneProgress;
import 'package:path/path.dart' as p;

/// How long git can go without a word before the clone is given up on as stuck.
const cloneStallTime = Duration(minutes: 3);
const _tailBytes = 16 * 1024;

/// What git says it's doing, in words for the elevator.
const _steps = {
  'Enumerating objects': 'GitHub is packing it up',
  'Counting objects': 'GitHub is packing it up',
  'Compressing objects': 'GitHub is packing it up',
  'Receiving objects': 'Downloading',
  'Resolving deltas': 'Unpacking',
  'Checking connectivity': 'Checking it over',
  'Updating files': 'Checking out files',
  'Filtering content': 'Downloading LFS files',
};

final _progress = RegExp(
  r'^(?:remote: )?([A-Z][a-z]+ [a-z]+):\s+(?:(\d{1,3})%(?: \(\d+/\d+\))?|\d+)(?:, ([\d.]+ [KMGT]?i?B)(?: \| ([\d.]+ [KMGT]?i?B/s))?)?',
);

/// How far a clone has got, from the latest progress line in git's output (lines end in \r or \n).
CloneProgress? parseProgress(String output) {
  final lines = output.split(RegExp(r'[\r\n]+'));
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    final m = _progress.firstMatch(line);
    final step = m == null ? null : _steps[m.group(1)];
    if (m != null && step != null) {
      final detail = [m.group(3), m.group(4)].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
      final pct = m.group(2);
      return CloneProgress(
        step: step,
        percent: pct != null ? min(100, int.parse(pct)) : null,
        detail: detail.isNotEmpty ? detail : null,
      );
    }
    if (line.startsWith('Cloning into ')) return const CloneProgress(step: 'Connecting to GitHub');
  }
  return null;
}

/// Why a clone failed, from what gh and git said, in terms of what to do about it on the office's machine.
String whyCloneFailed(String output) {
  final said = [
    for (final l in output.split(RegExp(r'[\r\n]+')).map((l) => l.trim()))
      if (l.isNotEmpty && !_progress.hasMatch(l) && !l.startsWith('Cloning into ')) l,
  ];
  final all = said.join('\n');
  bool has(String re) => RegExp(re, caseSensitive: false).hasMatch(all);
  if (has('Host key verification failed')) {
    return "ssh on the office's machine hasn't accepted github.com's host key yet. Run `ssh -T git@github.com` there once, or clone over https with `gh config set git_protocol https`";
  }
  if (has('passphrase')) {
    return "the office's ssh key needs its passphrase. Add it to the ssh agent (`ssh-add`), or clone over https with `gh config set git_protocol https`";
  }
  if (has(r'Permission denied \(publickey')) {
    return "GitHub didn't take the office's ssh key. Add it with `gh ssh-key add`, or clone over https with `gh config set git_protocol https`";
  }
  if (has('terminal prompts disabled|could not read (Username|Password)|Authentication failed')) {
    return "git wanted a GitHub password. Run `gh auth setup-git` on the office's machine so git uses gh's login";
  }
  final last = said.length > 2 ? said.sublist(said.length - 2) : said;
  return last.isNotEmpty ? last.join(' ') : 'gh failed';
}

/// How a clone ended: stopped (and why), or not; and the end of what gh and git said. (Started
/// detached, its exit code isn't known: whether its checkout is there is the word on it.)
typedef CloneEnd = ({String? stopped, String output});

/// A clone the office is watching, whether it started it or an office before it did.
class CloneRun {
  CloneRun._(this.pid, this.group, this.log, this._changed, this._stall, Duration tick, {this.adopted = false}) {
    _timer = Timer.periodic(tick, (_) => _tick());
  }

  /// The clone's own process (gh), and the process group everything it started is in.
  final int pid;
  final int group;

  /// Where gh and git write; the office reads it.
  final String log;

  /// An office before this one started it.
  final bool adopted;
  final void Function()? _changed;
  final Duration _stall;
  CloneProgress? progress;
  final _done = Completer<CloneEnd>();
  Future<CloneEnd> get done => _done.future;
  String? _stopped;
  bool _ended = false;
  int _size = -1;
  DateTime _grewAt = DateTime.now();
  late final Timer _timer;
  Timer? _killTimer;

  /// Starts `gh repo clone repo dest`, writing to [log]. Resolves once it's running, or to why it
  /// couldn't start as `error`. [gh] stands in for the GitHub CLI (tests).
  static Future<({CloneRun? run, String? error})> start(
    String repo,
    String dest,
    String log, {
    void Function()? changed,
    Duration stall = cloneStallTime,
    Duration tick = const Duration(seconds: 1),
    String gh = 'gh',
  }) async {
    ({CloneRun? run, String? error}) fail(String e) => (run: null, error: e);
    try {
      File(log).writeAsStringSync('');
      if (!Platform.isWindows) Process.runSync('chmod', ['600', log]);
    } catch (err) {
      return fail("Couldn't write $log: ${err is FileSystemException ? err.message : err}");
    }
    final ghPath = _which(gh);
    if (ghPath == null) return fail("The GitHub CLI (gh) isn't installed on the office's machine");
    // No prompts: nobody would see them. What would have asked says so and fails instead.
    final line = ['exec', ghPath, 'repo', 'clone', repo, dest, '--', '--progress'].map(_shq).join(' ');
    Process proc;
    try {
      proc = await Process.start(
        '/bin/sh',
        ['-c', '$line >${_shq(log)} 2>&1 </dev/null'],
        workingDirectory: p.dirname(dest),
        environment: {'GIT_TERMINAL_PROMPT': '0', 'GH_PROMPT_DISABLED': '1'},
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (e) {
      return fail("Couldn't run gh: ${e.message}");
    }
    final group = _groupOf(proc.pid) ?? proc.pid;
    return (run: CloneRun._(proc.pid, group, log, changed, stall, tick), error: null);
  }

  /// Picks up a clone an office before this one started, if it's still going: its log is still being
  /// written, so it goes on like any other. Null if that process is gone (or isn't a clone).
  static CloneRun? adopt(
    int pid,
    String log, {
    int? group,
    void Function()? changed,
    Duration stall = cloneStallTime,
    Duration tick = const Duration(seconds: 1),
  }) {
    if (Platform.isWindows || !_isClone(pid)) return null;
    return CloneRun._(pid, group ?? _groupOf(pid) ?? pid, log, changed, stall, tick, adopted: true);
  }

  /// Stops the clone (git tidies away what it had cloned). [done] says [why].
  void stop(String why) {
    if (_ended) return;
    _stopped ??= why;
    _signal('TERM');
    _killTimer ??= Timer(const Duration(seconds: 10), () => _signal('KILL'));
  }

  /// Stops watching and leaves the clone running, for the next office to pick up.
  void release() {
    _timer.cancel();
    _killTimer?.cancel();
    _ended = true;
  }

  void _signal(String sig) {
    // An adopted clone's pid was only checked when it was picked up: make sure it hasn't been handed
    // to something else since, so a stall or a Stop never signals a stranger's process group.
    if (adopted ? !_isClone(pid) : !_alive(pid)) return;
    try {
      Process.runSync('kill', ['-$sig', '--', '-$group']);
    } catch (_) {
      // gone already
    }
  }

  void _tick() {
    if (_ended) return;
    // Started detached: nothing says when it exits but its pid going away.
    if (!_alive(pid)) return _end();
    final r = _read();
    if (r.size != _size) {
      _size = r.size;
      _grewAt = DateTime.now();
      final now = parseProgress(r.text);
      if (jsonEncode(now?.toJson()) != jsonEncode(progress?.toJson())) {
        progress = now;
        _changed?.call();
      }
    } else if (DateTime.now().difference(_grewAt) > _stall) {
      final mins = max(1, (_stall.inMilliseconds / 60000).round());
      stop(
        "Cloning stalled: nothing new from GitHub in $mins minute${mins == 1 ? '' : 's'}. Try again, or check the office machine's connection",
      );
    }
  }

  /// The end of the log, and how long it is.
  ({String text, int size}) _read() {
    RandomAccessFile? f;
    try {
      f = File(log).openSync();
      final size = f.lengthSync();
      final len = min(_tailBytes, size);
      f.setPositionSync(size - len);
      final Uint8List bytes = f.readSync(len);
      return (text: utf8.decode(bytes, allowMalformed: true), size: size);
    } catch (_) {
      return (text: '', size: 0);
    } finally {
      f?.closeSync();
    }
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _timer.cancel();
    _killTimer?.cancel();
    // gh goes at once on SIGTERM; a git, ssh or index-pack still hanging in its group goes with it.
    if (_stopped != null) {
      try {
        Process.runSync('kill', ['-KILL', '--', '-$group']);
      } catch (_) {
        // nothing left in it
      }
    }
    _done.complete((stopped: _stopped, output: _read().text));
  }
}

/// Deletes a clone's log.
void dropLog(String log) {
  try {
    File(log).deleteSync();
  } catch (_) {
    // gone, or in use
  }
}

String _shq(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// [cmd]'s full path on the office's PATH (a detached process gets no help finding it), or null.
String? _which(String cmd) {
  if (cmd.contains('/')) return File(cmd).existsSync() ? cmd : null;
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final file = p.join(dir, cmd);
    if (File(file).existsSync()) return file;
  }
  return null;
}

/// What `ps` says of a process: its state and command line; null when it's gone.
({String stat, String command})? _ps(int pid) {
  try {
    final r = Process.runSync('ps', ['-o', 'stat=', '-o', 'command=', '-p', '$pid']);
    final out = '${r.stdout}'.trim();
    if (r.exitCode != 0 || out.isEmpty) return null;
    final at = out.indexOf(RegExp(r'\s'));
    return at < 0 ? (stat: out, command: '') : (stat: out.substring(0, at), command: out.substring(at).trim());
  } catch (_) {
    return null;
  }
}

/// The process is still there (a zombie nobody reaped yet has gone).
bool _alive(int pid) {
  final ps = _ps(pid);
  return ps != null && !ps.stat.startsWith('Z');
}

/// The process is a live `gh repo clone` (the pid wasn't handed to something else since).
bool _isClone(int pid) {
  final ps = _ps(pid);
  return ps != null && !ps.stat.startsWith('Z') && RegExp(r'\brepo clone\b').hasMatch(ps.command);
}

/// The process group [pid] is in.
int? _groupOf(int pid) {
  try {
    final r = Process.runSync('ps', ['-o', 'pgid=', '-p', '$pid']);
    return int.tryParse('${r.stdout}'.trim());
  } catch (_) {
    return null;
  }
}
