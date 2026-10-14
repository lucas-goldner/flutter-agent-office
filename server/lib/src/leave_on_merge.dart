// Whether a worker whose pull request merged goes home by itself (⚙️ Settings), and which workers
// that sends home. Port of src/server/leave-on-merge.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

/// Whether a worker whose pull request merged goes home by itself, picked in ⚙️ Settings by anyone
/// and kept in .agent-office/leave-on-merge.json. The same on every floor; off until someone turns it on.
class LeaveOnMerge {
  LeaveOnMerge(String dataDir, this._onState) : _path = p.join(dataDir, 'leave-on-merge.json') {
    _restore();
  }

  final void Function(LeaveOnMergeState state) _onState;
  final String _path;
  LeaveOnMergeState? _saved;

  bool get on => _saved?.on ?? false;

  LeaveOnMergeState state() => _saved ?? const LeaveOnMergeState();

  void set(bool on, String by) {
    _saved = LeaveOnMergeState(on: on, by: by, at: DateTime.now().millisecondsSinceEpoch);
    _persist();
    _onState(state());
  }

  void _restore() {
    try {
      final s = jsonDecode(File(_path).readAsStringSync());
      if (s is Map && s['on'] is bool) {
        _saved = LeaveOnMergeState(
          on: s['on'] as bool,
          by: s['by'] is String ? s['by'] as String : 'someone',
          at: s['at'] is num ? (s['at'] as num).toInt() : 0,
        );
      }
    } catch (_) {
      // never set: workers wait to be sent home
    }
  }

  void _persist() {
    try {
      final tmp = '$_path.tmp';
      File(tmp).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_saved?.toJson() ?? const {}));
      chmodSync(tmp, 0x180); // 0600
      File(tmp).renameSync(_path);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// A worker whose work has landed, with the pull request that merged.
typedef Landed = ({
  WorkerInfo worker,

  /// Its own floor's merged PR; for a worker across repositories, the first of them that merged.
  int pr,

  /// The merged PR's head commit, when GitHub said: everything up to it is delivered.
  String? head,

  /// A worker across repositories: the head of each other repository's merged PR, by floor.
  Map<String, String?>? heads,

  /// …and every PR of its that merged, as "api #7".
  List<String>? prs,
});

/// The workers free to go home because their work landed: a pull request of theirs merged and none
/// is still open (the same call as the purple bubble, see workerPr), they're at rest, and nobody has
/// their terminal open. Board agents, shells and the meeting table don't come and go by pull request.
/// A worker across repositories has pull requests on other floors too ([pullsOf] has their lists):
/// none of them may be open, or opened from its desk but missing from its floor's list.
List<Landed> landedWorkers(
  List<WorkerInfo> workers,
  List<GhPull> pulls,
  List<QueueTask> tasks, [
  List<GhPull>? Function(String floor)? pullsOf,
]) => [
  for (final w in workers)
    if (notLeaving(w) == null) ?landedWork(w, pulls, tasks, pullsOf),
];

/// Why a worker whose work landed doesn't go home by itself yet (see [landedWorkers]), in a few words;
/// null when nothing keeps it.
String? notLeaving(WorkerInfo w) {
  if (w.kind != WorkerKind.agent) return 'a shell';
  if (w.meeting != null) return 'at the meeting table';
  if (deskById[w.deskId]?.station != null) return 'a board agent';
  if (isBusy(w.status)) return w.status == WorkerStatus.needsInput ? 'waiting on someone' : 'still working';
  if (w.prOpening == true) return 'opening a pull request';
  if (w.viewers.isNotEmpty) {
    return '${w.viewers.join(', ')} ${w.viewers.length == 1 ? 'has' : 'have'} its terminal open';
  }
  return null;
}

/// A worker's work, landed: a pull request of its merged and none is open (see workerPr), with the
/// heads of what merged, whatever the worker is doing now. Null when that isn't so.
Landed? landedWork(
  WorkerInfo w,
  List<GhPull> pulls,
  List<QueueTask> tasks, [
  List<GhPull>? Function(String floor)? pullsOf,
]) {
  final pr = workerPr(w, pulls, tasks);
  if (w.repos?.isNotEmpty ?? false) return _landedAcross(w, pr, pulls, pullsOf);
  if (pr == null || pr.state != WorkerPrState.merged) return null;
  return (
    worker: w,
    pr: pr.number,
    head: pulls.where((x) => x.number == pr.number).firstOrNull?.headRefOid,
    heads: null,
    prs: null,
  );
}

/// [landedWork] for a worker across repositories, whose own floor's PR, if any, is [own].
Landed? _landedAcross(WorkerInfo w, WorkerPr? own, List<GhPull> pulls, List<GhPull>? Function(String floor)? pullsOf) {
  if (own?.state == WorkerPrState.open) return null;
  final heads = <String, String?>{};
  final prs = <String>[];
  final numbers = <int>[];
  if (own != null) {
    prs.add('${w.worktree != null ? w.worktree!.path.split(RegExp(r'[\\/]')).last : 'its own'} #${own.number}');
    numbers.add(own.number);
  }
  for (final r in w.repos ?? const <WorkerRepo>[]) {
    final theirs = (pullsOf?.call(r.floor) ?? const <GhPull>[])
        .where((x) => x.number == r.pr?.number || x.headRefName == r.branch)
        .toList();
    // Opened from its desk, but its floor doesn't list it (yet, or any more): can't tell.
    if (r.pr != null && !theirs.any((x) => x.number == r.pr!.number)) return null;
    if (theirs.any((x) => x.state == 'OPEN' || x.state == 'DRAFT')) return null;
    final merged = theirs.where((x) => x.state == 'MERGED').firstOrNull;
    if (merged == null) continue;
    heads[r.floor] = merged.headRefOid;
    prs.add('${r.name} #${merged.number}');
    numbers.add(merged.number);
  }
  if (numbers.isEmpty) return null;
  return (
    worker: w,
    pr: numbers.first,
    head: own == null ? null : pulls.where((x) => x.number == own.number).firstOrNull?.headRefOid,
    heads: heads,
    prs: prs,
  );
}
