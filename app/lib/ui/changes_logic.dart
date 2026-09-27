// The Changes window's words and its diff reader (see changes.dart), apart so they are tested on the VM.

import '../shared/protocol.dart';

const Map<ChangeStatus, String> kStatusWord = {
  ChangeStatus.modified: 'modified',
  ChangeStatus.added: 'added',
  ChangeStatus.deleted: 'deleted',
  ChangeStatus.renamed: 'renamed',
  ChangeStatus.typeChanged: 'type changed',
  ChangeStatus.untracked: 'new file',
};

/// The letter in a file's badge: a new, untracked file shows as A.
String statusLetter(ChangeStatus s) => s == ChangeStatus.untracked ? 'A' : s.wire;

enum DiffKind { ctx, hunk, meta, add, del }

/// One row of a rendered diff: its kind, old and new line numbers ('' when none) and the code.
typedef DiffLine = ({DiffKind kind, String old, String now, String code});

final _hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
final _fileMeta = RegExp(r'^(diff --git|index |--- |\+\+\+ |similarity index)');

/// Reads a unified diff into rows: hunk headers, added and removed lines, with line numbers.
List<DiffLine> parseDiff(String text, bool truncated) {
  final out = <DiffLine>[];
  var oldN = 0;
  var newN = 0;
  var inHunk = false;
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  for (final raw in lines) {
    var kind = DiffKind.ctx;
    var o = '';
    var n = '';
    var code = raw;
    if (raw.startsWith('@@')) {
      inHunk = true;
      kind = DiffKind.hunk;
      final m = _hunk.firstMatch(raw);
      if (m != null) {
        oldN = int.parse(m[1]!);
        newN = int.parse(m[2]!);
      }
    } else if (!inHunk || raw.startsWith('diff --git')) {
      inHunk = false;
      // The file names are already in the header; keep only the lines that say something else.
      if (_fileMeta.hasMatch(raw)) continue;
      kind = DiffKind.meta;
    } else if (raw.startsWith('+')) {
      kind = DiffKind.add;
      n = '${newN++}';
      code = raw.substring(1);
    } else if (raw.startsWith('-')) {
      kind = DiffKind.del;
      o = '${oldN++}';
      code = raw.substring(1);
    } else if (raw.startsWith(r'\')) {
      kind = DiffKind.meta;
    } else {
      o = '${oldN++}';
      n = '${newN++}';
      code = raw.isEmpty ? '' : raw.substring(1);
    }
    out.add((kind: kind, old: o, now: n, code: code));
  }
  if (truncated) out.add((kind: DiffKind.meta, old: '', now: '', code: '… the rest of this diff is too long to show here'));
  return out;
}

/// The files list's heading, e.g. "3 changed files" or "50+ changed files".
String filesHeading(ChangesState? s) {
  if (s == null) return 'Changed files';
  final n = s.files.length;
  if (n == 0) return 'Changed files';
  return '$n${s.more > 0 ? '+' : ''} changed file${n > 1 || s.more > 0 ? 's' : ''}';
}

/// The header's branch line.
String branchLine(ChangesState? s) {
  if (s == null || s.error != null) return '';
  return s.base == 'HEAD' ? '🌿 ${s.branch} · uncommitted changes' : '🌿 ${s.branch} · vs ${s.base}';
}

String whereText(ChangesState? s) => s != null && s.dir.isNotEmpty ? s.dir : 'the project folder';

int uncommittedCount(ChangesState? s) => s?.files.where((f) => f.uncommitted).length ?? 0;

String commitLabel(int uncommitted) => uncommitted > 0 ? '✅ Commit $uncommitted file${uncommitted > 1 ? 's' : ''}…' : '✅ Commit…';

/// Why the Open PR button is off ('' when it is on).
String prBlocked(ChangesState s) {
  if (s.busy != null) return '';
  if (uncommittedCount(s) > 0) return 'Commit first';
  if (s.ahead == 0) return 'Nothing on ${s.branch} that ${s.prBase} lacks yet';
  return '';
}

/// The footer's summary when the office isn't busy: the pieces after the +/− counts.
List<({String text, String? tip})> summaryBits(ChangesState s) {
  final uncommitted = uncommittedCount(s);
  final bits = <({String text, String? tip})>[];
  final state = uncommitted > 0
      ? '$uncommitted uncommitted'
      : s.files.isNotEmpty
      ? 'all committed'
      : '';
  if (state.isNotEmpty) bits.add((text: state, tip: null));
  if (s.ahead > 0) bits.add((text: '${s.ahead} commit${s.ahead > 1 ? 's' : ''} ahead of ${s.base}', tip: null));
  if (s.dir.isEmpty) {
    bits.add((
      text: '📁 shared project folder',
      tip: "This worker works in the project folder itself, so this is everything uncommitted there — everyone's edits, not just its own.",
    ));
  } else {
    bits.add((text: '📁 ${s.dir}', tip: 'Its own worktree at ${s.dir}'));
  }
  return bits;
}
