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
  int pr,

  /// The merged PR's head commit, when GitHub said: everything up to it is delivered.
  String? head,
});

/// The workers free to go home because their work landed: a pull request of theirs merged and none
/// is still open (the same call as the purple bubble, see workerPr), they're at rest, and nobody has
/// their terminal open. Board agents, shells and the meeting table don't come and go by pull request.
List<Landed> landedWorkers(List<WorkerInfo> workers, List<GhPull> pulls, List<QueueTask> tasks) {
  final out = <Landed>[];
  for (final w in workers) {
    if (w.kind != WorkerKind.agent || w.meeting != null || deskById[w.deskId]?.station != null) continue;
    if (isBusy(w.status) || w.prOpening == true || w.viewers.isNotEmpty) continue;
    final pr = workerPr(w, pulls, tasks);
    if (pr == null || pr.state != WorkerPrState.merged) continue;
    out.add((worker: w, pr: pr.number, head: pulls.where((x) => x.number == pr.number).firstOrNull?.headRefOid));
  }
  return out;
}
