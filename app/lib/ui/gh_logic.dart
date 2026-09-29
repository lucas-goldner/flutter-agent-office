// The logic behind the board and PR windows that doesn't draw anything (from boards.ts and
// pull.ts): which column a card goes in, whether a PR can merge, and the prompts workers get.
// Pure Dart, so it is tested on the VM.

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:office_shared/protocol.dart';
import 'markdown.dart' show repoUrlOf;

// ---- Boards ---------------------------------------------------------------------------------------

/// The task a worker gets for an issue, from the board or the queue.
String issuePrompt(GhIssue it) =>
    'Work on GitHub issue #${it.number}: "${it.title}".\n\nRead it first with `gh issue view ${it.number} --comments`. Create a new branch, implement the change, verify it, then open a pull request that closes #${it.number}.';

class BoardColumn<T> {
  const BoardColumn(this.key, this.title, this.items, {this.max});

  /// Names the column in your saved label filters.
  final String key;
  final String title;
  final List<T> items;

  /// Shows at most this many (after the label filter).
  final int? max;
}

final _progress = RegExp('progress|doing|wip|started', caseSensitive: false);

int _byUpdatedDesc(dynamic a, dynamic b) => (b.updatedAt as String).compareTo(a.updatedAt as String);

List<BoardColumn<GhIssue>> issueColumns(List<GhIssue> items, QueueTask? Function(int issue) taskForIssue) {
  final open = items.where((i) => i.state == 'OPEN').toList();
  final inProgress = open
      .where((i) => i.assignees.isNotEmpty || i.labels.any((l) => _progress.hasMatch(l.name)) || taskForIssue(i.number)?.status == TaskStatus.running)
      .toList();
  final todo = open.where((i) => !inProgress.contains(i)).toList();
  final closed = items.where((i) => i.state != 'OPEN').toList()..sort(_byUpdatedDesc);
  return [
    BoardColumn('open', '📥 Open', todo),
    BoardColumn('progress', '🚧 In progress', inProgress),
    BoardColumn('closed', '✅ Closed', closed, max: 40),
  ];
}

List<BoardColumn<GhPull>> pullColumns(List<GhPull> items) {
  final open = items.where((p) => p.state == 'OPEN');
  return [
    BoardColumn('draft', '✏️ Draft', open.where((p) => p.isDraft).toList()),
    BoardColumn('review', '👀 In review', open.where((p) => !p.isDraft && p.reviewDecision != 'APPROVED').toList()),
    BoardColumn('approved', '👍 Approved', open.where((p) => !p.isDraft && p.reviewDecision == 'APPROVED').toList()),
    BoardColumn('merged', '🎉 Merged', items.where((p) => p.state == 'MERGED').toList()..sort(_byUpdatedDesc), max: 30),
    BoardColumn('closed', '🗑️ Closed', items.where((p) => p.state == 'CLOSED').toList()..sort(_byUpdatedDesc), max: 20),
  ];
}

// ---- Label filters ----------------------------------------------------------------------------------

/// The labels an issue or PR carries.
List<GhLabel> labelsOf(Object it) => switch (it) {
      GhIssue i => i.labels,
      GhPull p => p.labels,
      _ => const [],
    };

/// A column's cards after its label filter: the ones with any of [picked] (every one when none
/// is), capped at the column's max, and its count ("shown / total" while a filter is on).
({List<T> shown, String count}) filterColumn<T extends Object>(BoardColumn<T> col, List<String> picked) {
  List<T> cap(List<T> xs) => col.max == null ? xs : xs.take(col.max!).toList();
  final matching = picked.isEmpty ? col.items : col.items.where((it) => labelsOf(it).any((l) => picked.contains(l.name))).toList();
  final shown = cap(matching);
  return (shown: shown, count: picked.isEmpty ? '${shown.length}' : '${shown.length} / ${cap(col.items).length}');
}

/// Every label on the board's cards, by name (first colour seen), for the column filters.
Map<String, String> boardLabels(Iterable<Object> items) {
  final all = <String, String>{};
  for (final it in items) {
    for (final l in labelsOf(it)) {
      all.putIfAbsent(l.name, () => l.color);
    }
  }
  return all;
}

int _byNameCi(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : a.compareTo(b);
}

/// The labels a column's picker offers, A to Z: every one on the board and any picked earlier that
/// no card carries now; with how many of the column's cards carry each.
List<({String name, int count})> pickerLabels<T extends Object>(BoardColumn<T> col, Map<String, String> all, List<String> picked) {
  final names = {...all.keys, ...picked}.toList()..sort(_byNameCi);
  return [
    for (final name in names) (name: name, count: col.items.where((it) => labelsOf(it).any((l) => l.name == name)).length),
  ];
}

/// Where a board's label filters are kept, per floor (or project) and board.
String labelFiltersKey(String? floor, String? projectDir, String kind) => 'agent-office.board-labels.${floor ?? projectDir ?? ''}.$kind';

/// The saved filters (column key → label names), ignoring anything garbled.
Map<String, List<String>> parseLabelFilters(String? saved) {
  final out = <String, List<String>>{};
  try {
    final j = jsonDecode(saved ?? 'null');
    if (j is Map) {
      for (final e in j.entries) {
        final v = e.value;
        if (e.key is String && v is List && v.isNotEmpty) out[e.key as String] = v.whereType<String>().toList();
      }
    }
  } catch (_) {
    // garbled
  }
  return out;
}

// ---- The label picker -------------------------------------------------------------------------------

/// What saving the picker would do: the labels to put on and to take off.
({List<String> add, List<String> remove}) labelChanges(Set<String> had, Set<String> on) =>
    (add: on.where((n) => !had.contains(n)).toList(), remove: had.where((n) => !on.contains(n)).toList());

/// The picker's footer: the changes (+a −b), or how many labels it has.
String labelSummary(Set<String> had, Set<String> on) {
  final c = labelChanges(had, on);
  if (c.add.isEmpty && c.remove.isEmpty) return '${on.length} label${on.length == 1 ? '' : 's'} on it';
  return [...c.add.map((l) => '+$l'), ...c.remove.map((l) => '−$l')].join('  ');
}

/// The picker's rows: the labels it has first, then the rest of the repo's, each A to Z. Worked out
/// once, so a row never jumps away from the pointer.
List<GhLabel> labelRows(List<GhLabel> has, List<GhLabel>? repo) {
  final known = {for (final l in repo ?? const <GhLabel>[]) l.name: l};
  final hadNames = has.map((l) => l.name).toSet();
  int byName(GhLabel a, GhLabel b) => _byNameCi(a.name, b.name);
  final mine = has.map((l) => known[l.name] ?? l).toList()..sort(byName);
  final rest = (repo ?? const <GhLabel>[]).where((l) => !hadNames.contains(l.name)).toList()..sort(byName);
  return [...mine, ...rest];
}

/// Whether a label row matches the picker's filter (its name or description).
bool labelMatches(GhLabel l, String query) {
  final q = query.trim().toLowerCase();
  return q.isEmpty || '${l.name}\n${l.description ?? ''}'.toLowerCase().contains(q);
}

const checkIcon = {GhChecks.pass: '🟢', GhChecks.fail: '🔴', GhChecks.pending: '🟡', GhChecks.none: ''};

const kNoteColors = [Color(0xFFFFF7B0), Color(0xFFFFD6E0), Color(0xFFCAFFBF), Color(0xFFBDE0FE), Color(0xFFFFE5B4)];
const kPins = [Color(0xFFEF476F), Color(0xFF118AB2), Color(0xFF06D6A0), Color(0xFFFFD166)];

/// '#rrggbb' → a Color, or [fallback].
Color parseHex(String hex, [Color fallback = const Color(0xFF888888)]) {
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final n = int.tryParse(h, radix: 16);
  if (n == null || h.length != 6) return fallback;
  return Color(0xFF000000 | n);
}

/// A label's text colour: white on dark labels, ink on light ones.
bool labelIsDark(String color) {
  final n = int.tryParse(color.startsWith('#') ? color.substring(1) : color, radix: 16);
  if (n == null) return false;
  final lum = (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
  return lum < 0.55;
}

// ---- The PR window --------------------------------------------------------------------------------

/// owner/repo from a PR or issue URL.
String nameWithOwner(String url) => repoUrlOf(url).replaceFirst(RegExp(r'^https?://[^/]+/'), '');

const methodLabel = {
  GhMergeMethod.squash: 'Squash and merge',
  GhMergeMethod.merge: 'Create a merge commit',
  GhMergeMethod.rebase: 'Rebase and merge',
};

/// A badge's text and its tone ('ok', 'bad', 'muted' or '').
const reviewBadge = <String, (String, String)>{
  'APPROVED': ('✅ approved', 'ok'),
  'CHANGES_REQUESTED': ('🛠 requested changes', 'bad'),
  'COMMENTED': ('💬 reviewed', ''),
  'DISMISSED': ('review dismissed', 'muted'),
};

const checkStateIcon = {GhCheckState.pass: '✅', GhCheckState.fail: '❌', GhCheckState.pending: '🟡', GhCheckState.skip: '⚪'};

/// The pill for an issue or PR: its word and its CSS class.
(String, String) stateOf(String state, {bool isDraft = false}) {
  if (state == 'MERGED') return ('merged', 'merged');
  if (state == 'CLOSED') return ('closed', 'offline');
  return isDraft ? ('draft', 'idle') : ('open', 'working');
}

enum Tone { ok, warn, bad, muted }

class MergeStatus {
  const MergeStatus(this.icon, this.text, this.tone, {required this.can, required this.auto});
  final String icon;
  final String text;
  final Tone tone;

  /// False when merging can't work at all (draft, conflicts, already merged).
  final bool can;

  /// GitHub could merge it on its own once the requirements pass.
  final bool auto;
}

/// An open PR whose branch can't merge until someone resolves conflicts with the base.
bool conflicted(GhPullDetail d) => d.state == 'OPEN' && !d.isDraft && (d.mergeable == 'CONFLICTING' || d.mergeStateStatus == 'DIRTY');

MergeStatus mergeStatus(GhPullDetail d) {
  final failing = d.checks.where((c) => c.state == GhCheckState.fail).length;
  final pending = d.checks.where((c) => c.state == GhCheckState.pending).length;
  if (d.state == 'MERGED') return const MergeStatus('🎉', 'Merged.', Tone.ok, can: false, auto: false);
  if (d.state == 'CLOSED') return const MergeStatus('🗑️', 'Closed without merging.', Tone.muted, can: false, auto: false);
  if (d.isDraft) {
    return const MergeStatus('📝', 'This is still a draft. Mark it ready for review on GitHub before merging.', Tone.muted, can: false, auto: false);
  }
  if (conflicted(d)) {
    return MergeStatus('⚠️', 'This branch has conflicts with ${d.baseRefName} that must be resolved first.', Tone.bad, can: false, auto: false);
  }
  if (d.mergeStateStatus == 'BEHIND') {
    return MergeStatus('⤵️', 'The branch is behind ${d.baseRefName}, and this repo wants it up to date before merging.', Tone.warn, can: true, auto: true);
  }
  if (d.mergeStateStatus == 'BLOCKED') {
    final why = d.reviewDecision == 'CHANGES_REQUESTED'
        ? 'changes were requested'
        : d.reviewDecision == 'REVIEW_REQUIRED'
            ? 'it needs an approving review'
            : failing > 0
                ? '$failing check${failing > 1 ? 's are' : ' is'} failing'
                : pending > 0
                    ? 'required checks are still running'
                    : 'a branch rule is not met yet';
    return MergeStatus('🚫', 'Merging is blocked: $why.', Tone.bad, can: true, auto: true);
  }
  if (failing > 0) return MergeStatus('❌', '$failing check${failing > 1 ? 's' : ''} failing. It can still be merged.', Tone.warn, can: true, auto: false);
  if (pending > 0 || d.mergeStateStatus == 'UNSTABLE') {
    return const MergeStatus('🟡', 'Checks are still running. It can be merged now, or once they pass.', Tone.warn, can: true, auto: true);
  }
  if (d.mergeStateStatus == 'UNKNOWN' || d.mergeable == 'UNKNOWN') {
    return const MergeStatus('⏳', 'GitHub is still working out whether this can merge. Refresh in a moment.', Tone.muted, can: true, auto: false);
  }
  return MergeStatus('✅', 'Ready to merge: no conflicts with ${d.baseRefName}${d.checks.isNotEmpty ? ' and all checks passed' : ''}.', Tone.ok,
      can: true, auto: false);
}

/// Checks worst first: failing, running, passed, skipped.
List<GhCheck> sortedChecks(List<GhCheck> checks) {
  const order = [GhCheckState.fail, GhCheckState.pending, GhCheckState.pass, GhCheckState.skip];
  return [...checks]..sort((a, b) => order.indexOf(a.state).compareTo(order.indexOf(b.state)));
}

// ---- Prompts for workers --------------------------------------------------------------------------

String reviewPrompt(GhPull it) =>
    'Review pull request #${it.number}: "${it.title}".\n\nUse `gh pr view ${it.number} --comments` and `gh pr diff ${it.number}`. Look for bugs, risky changes and missing tests, then give me a short summary with concrete suggestions. Don\'t push any commits.';

String checkoutStep(GhPull it) =>
    'Get onto its branch: `gh pr checkout ${it.number}`. If git says `${it.headRefName}` is already checked out in another worktree, use `git fetch origin ${it.headRefName} && git checkout --detach FETCH_HEAD` instead and push with `git push origin HEAD:${it.headRefName}`.';

String mergeCommand(GhPull it, GhMergeMethod method, bool deleteBranch) =>
    'gh pr merge ${it.number} --${method.wire}${deleteBranch ? ' --delete-branch' : ''} --repo ${nameWithOwner(it.url)}';

String fixAndMergePrompt(GhPull it, GhMergeMethod method, bool deleteBranch) {
  final n = it.number;
  final repo = nameWithOwner(it.url);
  return [
    'Get pull request #$n "${it.title}" (${it.url}) ready and merge it.',
    '',
    '1. ${checkoutStep(it)}',
    '2. Read all the feedback: `gh pr view $n --comments`, and the comments on lines of code with `gh api repos/$repo/pulls/$n/comments`.',
    '3. Address every review comment that is still open: fix it, or if you disagree, reply on the PR saying why. If the branch conflicts with `${it.baseRefName}`, merge `${it.baseRefName}` in and resolve the conflicts.',
    '4. Verify your changes the way this project does (build, typecheck, tests), then commit and push.',
    '5. Wait for the checks with `gh pr checks $n --watch` and fix anything that fails.',
    '6. When the checks pass and no feedback is left, merge it: `${mergeCommand(it, method, deleteBranch)}`. If something only a person can decide is in the way, stop and tell me instead of merging.',
  ].join('\n');
}

String fixConflictsPrompt(GhPull it, GhMergeMethod method, bool deleteBranch) {
  final n = it.number;
  final base = it.baseRefName;
  return [
    'Pull request #$n "${it.title}" (${it.url}) has merge conflicts with `$base`. Resolve them and merge it.',
    '',
    '1. ${checkoutStep(it)}',
    '2. Bring in the latest `$base`: `git fetch origin $base && git merge origin/$base`.',
    '3. Resolve every conflict so both sides\' changes survive. Read the PR (`gh pr view $n`) and the `$base` commits that touched the same code to see what each side meant; don\'t just take one side.',
    '4. Verify the result the way this project does (build, typecheck, tests), then commit the merge and push.',
    '5. Wait for the checks with `gh pr checks $n --watch` and fix anything that fails.',
    '6. When the checks pass, merge it: `${mergeCommand(it, method, deleteBranch)}`. If a conflict needs a decision only a person can make, stop and tell me instead of merging.',
  ].join('\n');
}

String pullContext(GhPull it) =>
    'This is about pull request #${it.number} "${it.title}" (${it.url}), branch `${it.headRefName}` into `${it.baseRefName}`. Read it with `gh pr view ${it.number} --comments` and see its changes with `gh pr diff ${it.number}`.';

String issueContext(GhIssue it) =>
    'This is about GitHub issue #${it.number} "${it.title}" (${it.url}). Read it with `gh issue view ${it.number} --comments`.';

/// The merge method and branch deletion you last picked, if the repo still allows that method.
({GhMergeMethod method, bool deleteBranch}) mergePrefFrom(Object? saved, List<GhMergeMethod> methods) {
  final m = saved is Map ? GhMergeMethod.values.where((x) => x.wire == saved['method']).firstOrNull : null;
  final del = saved is Map && saved['deleteBranch'] is bool ? saved['deleteBranch'] as bool : true;
  final list = methods.isEmpty ? GhMergeMethod.values : methods;
  return (method: m != null && list.contains(m) ? m : list.first, deleteBranch: del);
}
