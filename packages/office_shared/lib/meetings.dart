// The meeting room's patterns: how 2–5 workers at the table work on one question or task together.
// The server runs them (server/meetings.ts); the client offers them when a meeting is called.
// Port of src/shared/meetings.ts. The wire types (Meeting, MeetingPattern…) are in protocol.dart.

import 'protocol.dart';

/// The fewest, the most, and the default.
typedef MeetingRange = ({int min, int max, int defaultValue});

/// What a pattern needs besides a prompt: a pull request (the review panel) or a list of parts (map-reduce).
enum PatternNeeds { pr, parts }

class PatternDef {
  const PatternDef({
    required this.icon,
    required this.label,
    required this.blurb,
    required this.roles,
    required this.seats,
    required this.rounds,
    required this.roundsNote,
    required this.output,
    this.needs,
  });

  final String icon;
  final String label;

  /// What happens, in a line.
  final String blurb;

  /// A role per chair, the head of the table first; a meeting takes the first few.
  final List<String> roles;

  /// How many workers sit down: the fewest, the most, and how many by default.
  final MeetingRange seats;

  /// The round limit: the fewest, the most, and the default. Fixed when min equals max.
  final MeetingRange rounds;

  /// What a round is, for the dialog.
  final String roundsNote;

  /// Where the output goes when whoever calls the meeting doesn't say (`slug` is the meeting's title as a file name).
  final String Function(String slug, int? pr) output;

  /// Needs a pull request (the review panel) or a list of parts (map-reduce).
  final PatternNeeds? needs;
}

final Map<MeetingPattern, PatternDef> meetingPatterns = Map.unmodifiable({
  MeetingPattern.debate: PatternDef(
    icon: '🗣️',
    label: 'Debate',
    blurb:
        'Each worker proposes, then critiques the others; in the last round the head of the table writes the decision.',
    roles: const ['Chair', 'Pragmatist', 'Skeptic', 'Simplifier', 'User advocate'],
    seats: (min: 2, max: 5, defaultValue: 3),
    rounds: (min: 2, max: 4, defaultValue: 3),
    roundsNote: 'Proposals, then a round of critique per extra round, then the decision.',
    output: (slug, _) => 'docs/decisions/$slug.md',
  ),
  MeetingPattern.lead: PatternDef(
    icon: '🧭',
    label: 'Lead & team',
    blurb:
        'The lead splits the task into parts, the team each do one, and the lead merges their work and writes it up.',
    roles: const ['Lead', 'Engineer', 'Engineer', 'Engineer', 'Engineer'],
    seats: (min: 2, max: 5, defaultValue: 3),
    rounds: (min: 3, max: 3, defaultValue: 3),
    roundsNote: 'Plan, work, merge.',
    output: (slug, _) => 'docs/meetings/$slug.md',
  ),
  MeetingPattern.mapreduce: PatternDef(
    icon: '🗂️',
    label: 'Map-reduce',
    blurb:
        'The same task over each part (files, modules, issues) in parallel; the head of the table combines the results.',
    roles: const ['Reducer', 'Mapper', 'Mapper', 'Mapper', 'Mapper'],
    seats: (min: 2, max: 5, defaultValue: 3),
    rounds: (min: 2, max: 2, defaultValue: 2),
    roundsNote: 'Map, then reduce.',
    output: (slug, _) => 'docs/meetings/$slug.md',
    needs: PatternNeeds.parts,
  ),
  MeetingPattern.redblue: PatternDef(
    icon: '🛡️',
    label: 'Red / blue',
    blurb: 'Red attacks the change (bugs, security), blue fixes what holds up, round after round; blue writes it up.',
    roles: const ['Blue team', 'Red team'],
    seats: (min: 2, max: 2, defaultValue: 2),
    rounds: (min: 1, max: 5, defaultValue: 3),
    roundsNote: 'An attack and a fix per round; it ends early when red finds nothing more.',
    output: (slug, _) => 'docs/reviews/$slug.md',
  ),
  MeetingPattern.review: PatternDef(
    icon: '🔍',
    label: 'Review panel',
    blurb:
        'Reviewers read a pull request through their own lens; the head of the table merges them into one review, posted on the PR.',
    roles: const ['Correctness', 'Security', 'Performance & simplicity', 'Tests', 'API design'],
    seats: (min: 2, max: 5, defaultValue: 3),
    rounds: (min: 2, max: 2, defaultValue: 2),
    roundsNote: 'Reviews, then the combined review.',
    output: (_, pr) => 'reviews/pr-${pr ?? 'n'}.md',
    needs: PatternNeeds.pr,
  ),
});

/// Every pattern, in the dialog's order.
const List<MeetingPattern> meetingPatternIds = MeetingPattern.values;

/// Whether [v] is a pattern's id on the wire (only the real ones, not what every object inherits).
bool isMeetingPattern(Object? v) => MeetingPattern.tryParse(v) != null;

/// Tokens a meeting may use by default: a million per worker at the table.
const int tokensPerSeat = 1000000;

/// The most a meeting may be given, however many workers sit down.
const int maxMeetingBudget = 50000000;

/// The round notes' folder at the top of a meeting's worktree. It's left out of the meeting's commit and
/// cleared away with the room (a copy stays in the floor's .agent-office/meetings/). Not under
/// .agent-office/: Claude Code asks before writing there in a worktree nested in the project.
const String meetingNotesDir = '.meeting';

/// What JS's `normalize('NFKD')` makes of the accented Latin letters, near enough: the letter, then
/// its combining mark, which slugify turns into a dash like anything else that isn't a-z0-9 ("naïve"
/// is "nai-ve"). Dart has no normalize.
const Map<String, String> _accented = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', //
  'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c', 'ď': 'd', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', //
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g', 'ĥ': 'h', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i', 'ĵ': 'j', 'ķ': 'k', //
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ō': 'o', 'ŏ': 'o', 'ő': 'o', //
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r', 'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ţ': 't', 'ť': 't', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u', //
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z', //
};

/// Compatibility forms NFKD takes apart, with no mark left over.
const Map<String, String> _compat = {'ﬁ': 'fi', 'ﬂ': 'fl', '½': '1/2', '²': '2', '³': '3', '¹': '1'};

final RegExp _notSlug = RegExp('[^a-z0-9]+');
final RegExp _edgeDashes = RegExp(r'^-+|-+$');
final RegExp _trailingDashes = RegExp(r'-+$');

/// A title as a file or branch name: "Pick a cache!" → "pick-a-cache".
String slugify(String s, [int max = 40]) {
  final folded = s
      .toLowerCase()
      .split('')
      .map((c) => _accented.containsKey(c) ? '${_accented[c]}\u0301' : (_compat[c] ?? c))
      .join();
  final slug = folded.replaceAll(_notSlug, '-').replaceAll(_edgeDashes, '');
  final cut = (slug.length > max ? slug.substring(0, max) : slug).replaceFirst(_trailingDashes, '');
  return cut.isEmpty ? 'meeting' : cut;
}

final RegExp _absolute = RegExp(r'^[/\\]|^[a-zA-Z]:');
final RegExp _sep = RegExp(r'[/\\]');
final RegExp _control = RegExp('[\x00-\x1f]');

/// Why an output path can't be used, or null when it's fine: a file inside the checkout, not in
/// the office's own folder or git's.
String? outputProblem(String p) {
  if (p.trim().isEmpty) return 'Say which file the meeting writes';
  if (p.length > 200) return 'That output path is too long';
  if (_absolute.hasMatch(p)) return 'The output file goes inside the project: give a path relative to it';
  final parts = p.split(_sep);
  if (parts.any((x) => x == '..' || x == '.' || x == '')) return 'The output path can’t have empty, . or .. parts';
  if (parts[0] == '.git' || parts[0] == '.agent-office' || parts[0] == meetingNotesDir)
    return 'The output can’t go in ${parts[0]}/';
  if (_control.hasMatch(p)) return 'The output path has control characters in it';
  return null;
}

/// "3 rounds" / "round 2 of 3".
String _rounds(int n) => '$n round${n == 1 ? '' : 's'}';

/// The spend, e.g. "1.2M tokens · $2.40" (or without the cost when a provider doesn't report it).
String meetingSpend({required int tokens, required double cost, required bool costKnown}) =>
    '${fmtTokens(tokens)} tokens${costKnown ? ' · ${fmtCost(cost)}' : (cost > 0 ? ' · ${fmtCost(cost)}+' : '')}';

/// The line on the room's door once a meeting is over: pattern, rounds, tokens, cost, and the output
/// file it wrote (and where), or why it stopped.
String meetingSummary(Meeting m) {
  final p = meetingPatterns[m.pattern]!;
  final ran = m.status == MeetingStatus.done
      ? _rounds(m.round)
      : '${m.status == MeetingStatus.stopped ? 'in ' : ''}round ${m.round} of ${m.rounds}';
  final head = '${p.icon} ${p.label} · $ran · ${meetingSpend(tokens: m.tokens, cost: m.cost, costKnown: m.costKnown)}';
  if (m.status == MeetingStatus.stopped) return '$head · ⛔ ${m.reason ?? 'stopped'}';
  if (m.status == MeetingStatus.running) return head;
  final review = m.review;
  final where = review?.url != null && review!.url!.isNotEmpty
      ? ' · posted on the PR'
      : review?.error != null && review!.error!.isNotEmpty
      ? " · couldn't post it: ${review.error}"
      : m.commit != null && m.commit!.isNotEmpty
      ? ' on ${m.worktree?.branch}'
      : m.worktree != null
      ? " in ${m.worktree!.branch}'s worktree"
      : '';
  return '$head · ✅ ${m.output}$where';
}

/// A meeting that's over, in a line. [now] (ms) stands in for its finishing time when it has none.
MeetingRecord meetingRecord(Meeting m, [int? now]) => MeetingRecord(
  id: m.id,
  pattern: m.pattern,
  title: m.title,
  status: m.status,
  summary: meetingSummary(m),
  calledBy: m.calledBy,
  finishedAt: m.finishedAt ?? now ?? DateTime.now().millisecondsSinceEpoch,
  branch: m.worktree?.branch,
  output: m.output,
);
