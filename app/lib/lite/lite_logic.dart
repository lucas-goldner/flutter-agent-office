// What the 2D view (/lite) says about the floors and the workers on them, without any widgets: the
// lines on each worker's card and the floor switcher's. The pure half of lite.ts.

import 'package:office_shared/floors.dart' show cloneLabel;
import 'package:office_shared/layout.dart' show deskById;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;
import 'package:office_shared/status.dart' show isAsleep;

import '../notify.dart' show waitingOnSomeone;
import '../ui/modal.dart' show clip, timeAgo;
import '../ui/provider.dart' show modelBadge, providerLabel;

/// A floor in the switcher: "api", "api (⏳ Receiving objects 40%)", "web · 🙋 2".
String liteFloorLabel(FloorInfo f) => f.cloning == true
    ? '${f.name} (${cloneLabel(f.clone)})'
    : f.waiting > 0
    ? '${f.name} · 🙋 ${f.waiting}'
    : f.name;

/// The line under the floor switcher: its branch, repository and who's there; or what to do with no floors.
String liteFloorMeta({ProjectInfo? project, FloorInfo? floor, required bool anyFloors}) {
  if (project == null) return anyFloors ? '' : 'Add a project from the elevator in the 3D office.';
  final b = project.branch;
  return [
    if (b != null && b.isNotEmpty) '⎇ $b',
    floor?.repo ?? project.dir,
    if (floor != null) '👥 ${floor.people} here',
  ].join(' · ');
}

/// Other floors with someone waiting there: a way straight to each.
List<FloorInfo> waitingElsewhere(List<FloorInfo> floors, String? here) =>
    floors.where((o) => o.id != here && o.waiting > 0 && o.cloning != true).toList();

/// Where to go from the roof (nothing to see up there from the 2D view): the first floor that's been cloned.
String? offTheRoof(String? floor, List<FloorInfo> floors) =>
    floor == roof ? floors.where((f) => f.cloning != true).firstOrNull?.id : null;

/// What it's on: its task, its title, or the start of its prompt.
String? liteTask(WorkerInfo w) => w.task?.name ?? w.title ?? (w.prompt == null ? null : clip(w.prompt!, 90));

/// What it's asking, doing or did, in a line.
String? liteNow(WorkerInfo w) {
  if (w.lost != null) return '🌿 Its worktree was deleted outside agent-office: open it to fix it';
  if (w.status == WorkerStatus.needsInput) return '🙋 ${w.activity ?? 'Waiting on an answer'}';
  if (isAsleep(w.status)) return '💤 Asleep: open it to wake it up';
  if (w.status == WorkerStatus.done) {
    final s = w.task?.summary;
    return s == null || s.isEmpty ? null : '✅ $s';
  }
  final s = w.task?.summary;
  return s != null && s.isNotEmpty ? s : w.activity;
}

/// Its engine, desk, branch, PR and who typed last: "⚙️ Claude Code · Opus 5.5 · Desk 3 · 🌿 fix-login".
String liteSub(WorkerInfo w, ProjectInfo? project, {int? now}) {
  final desk = deskById[w.deskId];
  final badge = w.kind == WorkerKind.agent ? modelBadge(w.provider, w.model, w.effort, w.usage?.model) : null;
  final last = w.lastInput;
  return [
    w.kind == WorkerKind.agent
        ? '⚙️ ${providerLabel(w.provider, project)}${badge != null ? ' · $badge' : ''}'
        : '🐚 shell',
    if (desk != null) desk.station != null ? '📌 ${desk.label}' : desk.label,
    if (w.worktree != null) '🌿 ${w.worktree!.branch}',
    if (w.pr != null) '🔀 PR #${w.pr!.number}',
    if (last != null) '⌨️ ${last.by} ${timeAgo(last.at)}',
  ].join(' · ');
}

/// Whether the card has a ✍️ for a prompt: not asleep, not lost, and not asking something (that one's
/// answered in its terminal, where the question is).
bool liteCanPrompt(WorkerInfo w) => !isAsleep(w.status) && w.lost == null && w.status != WorkerStatus.needsInput;

/// The workers that just started waiting on someone, since [last] (what each was then, updated here): a
/// notification and, for one that needs you, a buzz.
List<WorkerInfo> newlyWaiting(Iterable<WorkerInfo> workers, Map<String, WorkerStatus> last) {
  final out = <WorkerInfo>[];
  for (final w in workers) {
    final before = last[w.id];
    last[w.id] = w.status;
    if (before == null || before == w.status || !waitingOnSomeone(w)) continue;
    out.add(w);
  }
  return out;
}
