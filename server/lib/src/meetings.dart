// The meeting room: 2–5 agents round a table, run through the rounds of a pattern (debate, lead &
// team, map-reduce, red / blue, review panel). Port of src/server/meetings.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart' hide MeetingRoom;
import 'package:path/path.dart' as p;

import 'agents.dart';
import 'worktrees.dart';

/// What the meeting room needs from the worker manager. Narrow on purpose, so a test can fake it.
abstract interface class MeetingWorkers {
  AgentProvider get defaultProvider;

  /// What a meeting seats when whoever calls it doesn't pick (⚙️ Settings); the default provider without it.
  AgentChoice? get officeDefault;
  List<WorkerInfo> list();

  /// Seats an agent at a chair of the meeting table, for meeting [meeting], in its worktree when it
  /// has one. The worker, or why there's none.
  ({WorkerInfo? worker, String? error}) seat(
    String deskId,
    String by,
    String prompt,
    AgentProvider provider,
    String? model,
    AgentEffort? effort,
    ({String id, WorkerWorktree? worktree}) meeting,
  );

  /// Why it couldn't, or null.
  String? prompt(String id, String text, [String? by]);

  /// Keys into its terminal: Esc, to stop what it's doing.
  void write(String id, String data, String by);
  Future<({String? note, String? error})> kill(String id);
}

/// Git for the meeting's own worktree: made when it starts, tidied away once everyone has gone home.
abstract interface class MeetingTrees {
  ({WorkerWorktree? worktree, String? error}) create(String slug);
  Future<WorktreeState> inspect(WorktreeRef wt);

  /// [cleanup] is worktree or all. Returns what went wrong, if anything.
  Future<String?> remove(WorktreeRef wt, WorktreeCleanup cleanup);
}

/// The project's git worktrees, for a meeting.
class GitMeetingTrees implements MeetingTrees {
  GitMeetingTrees(this._trees);
  final Worktrees _trees;

  @override
  ({WorkerWorktree? worktree, String? error}) create(String slug) => _trees.create(slug);
  @override
  Future<WorktreeState> inspect(WorktreeRef wt) => _trees.inspect(wt);
  @override
  Future<String?> remove(WorktreeRef wt, WorktreeCleanup cleanup) => _trees.remove(wt, cleanup);
}

class MeetingEvents {
  const MeetingEvents({
    required this.update,
    required this.toast,
    required this.hiringPaused,
    required this.postReview,
    this.prompt,
  });

  final void Function(MeetingState state) update;
  final void Function(String text, ToastLevel level) toast;

  /// Why nobody may be hired right now (today's budget is spent), if that's so.
  final String? Function() hiringPaused;

  /// Posts the review panel's review on its pull request. Resolves to the review's URL.
  final Future<String> Function(int pr, String file) postReview;

  /// One of the office's prompts as it has it now (rewritten in ⚙️ Settings, or the default).
  final String Function(PromptId id)? prompt;
}

const _pumpEvery = Duration(seconds: 3);

/// A part handed to a worker that sits ready this long without starting on it is handed over again, once.
const _startGraceMs = 60000;

/// How much of the output file the board in the room shows.
const _previewChars = 6000;
const _pastMax = 20;
const _promptMax = 20000;
const _roleMax = 40;
const _partsMax = 100;

/// Who the office types a meeting's prompts as.
const _by = 'the meeting room';

/// What a red team or a reviewer writes when it has nothing to report.
final _nothing = RegExp(r'^\W*no findings\b', caseSensitive: false);

/// Ready for its next part: not starting up, busy, waiting on someone, or asleep.
bool _ready(WorkerStatus s) => s == WorkerStatus.idle || s == WorkerStatus.done;

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A part of a round, before it's handed over.
typedef _Part = ({int seat, String doing, String file, String ask});

class _Seat {
  _Seat(this.role, this.deskId, {this.workerId, this.workerName, this.tokens, this.cost});
  factory _Seat.of(MeetingSeat s) =>
      _Seat(s.role, s.deskId, workerId: s.workerId, workerName: s.workerName, tokens: s.tokens, cost: s.cost);

  final String role;
  final String deskId;
  String? workerId;
  String? workerName;
  int? tokens;
  double? cost;

  MeetingSeat get view =>
      MeetingSeat(role: role, deskId: deskId, workerId: workerId, workerName: workerName, tokens: tokens, cost: cost);
}

class _Turn {
  _Turn(this.seat, this.doing, this.file, this.state, {this.sentAt, this.retried = false});
  factory _Turn.of(MeetingTurn t) =>
      _Turn(t.seat, t.doing, t.file, t.state, sentAt: t.sentAt, retried: t.retried ?? false);

  final int seat;
  final String doing;
  final String file;
  MeetingTurnState state;
  int? sentAt;
  bool retried;

  MeetingTurn get view =>
      MeetingTurn(seat: seat, doing: doing, file: file, state: state, sentAt: sentAt, retried: retried ? true : null);
}

/// A [Meeting] as the room changes it.
class _Meeting {
  _Meeting({
    required this.id,
    required this.pattern,
    required this.title,
    required this.prompt,
    required this.output,
    required this.seats,
    this.parts,
    this.pr,
    this.issue,
    this.provider,
    this.model,
    this.effort,
    required this.rounds,
    required this.calledBy,
    required this.startedAt,
    this.worktree,
    required this.notes,
    required this.budget,
  });

  factory _Meeting.of(Meeting m) =>
      _Meeting(
          id: m.id,
          pattern: m.pattern,
          title: m.title,
          prompt: m.prompt,
          output: m.output,
          seats: [for (final s in m.seats) _Seat.of(s)],
          parts: m.parts,
          pr: m.pr,
          issue: m.issue,
          provider: m.provider,
          model: m.model,
          effort: m.effort,
          rounds: m.rounds,
          calledBy: m.calledBy,
          startedAt: m.startedAt,
          worktree: m.worktree,
          notes: m.notes,
          budget: m.budget,
        )
        ..round = m.round
        ..step = m.step
        ..lastRound = m.lastRound
        ..turns = [for (final t in m.turns) _Turn.of(t)]
        ..tokens = m.tokens
        ..cost = m.cost
        ..costKnown = m.costKnown
        ..status = m.status
        ..reason = m.reason
        ..finishedAt = m.finishedAt
        ..commit = m.commit
        ..review = m.review
        ..preview = m.preview
        ..cleared = m.cleared ?? false;

  final String id;
  final MeetingPattern pattern;
  final String title;
  final String prompt;
  final String output;
  final List<_Seat> seats;
  final List<String>? parts;
  final int? pr;
  final int? issue;
  final AgentProvider? provider;
  final String? model;
  final AgentEffort? effort;
  final int rounds;
  int round = 1;
  int step = 1;
  int? lastRound;
  List<_Turn> turns = [];
  final int budget;
  int tokens = 0;
  double cost = 0;
  bool costKnown = true;
  MeetingStatus status = MeetingStatus.running;
  String? reason;
  final String calledBy;
  final int startedAt;
  int? finishedAt;
  final WorkerWorktree? worktree;
  final String notes;
  String? commit;
  MeetingReview? review;
  String? preview;
  bool cleared = false;

  Meeting get view => Meeting(
    id: id,
    pattern: pattern,
    title: title,
    prompt: prompt,
    output: output,
    seats: [for (final s in seats) s.view],
    parts: parts,
    pr: pr,
    issue: issue,
    provider: provider,
    model: model,
    effort: effort,
    rounds: rounds,
    round: round,
    step: step,
    lastRound: lastRound,
    turns: [for (final t in turns) t.view],
    budget: budget,
    tokens: tokens,
    cost: cost,
    costKnown: costKnown,
    status: status,
    reason: reason,
    calledBy: calledBy,
    startedAt: startedAt,
    finishedAt: finishedAt,
    worktree: worktree,
    notes: notes,
    commit: commit,
    review: review,
    preview: preview,
    cleared: cleared ? true : null,
  );
}

/// The meeting room. A meeting seats 2–5 agents round the table, each with a role, and runs them
/// through the rounds of its pattern (office_shared's meetings.dart): in each step every worker with
/// a part gets it as a prompt, and the step is over when each of them has ended its turn with its
/// part written to the file it names. Checking the files, not the talk, is what moves a meeting on.
/// It ends when the output file is written, and stops early, saying why, when it runs over its token
/// budget, when a worker won't write its part, or when a worker leaves.
///
/// Everyone at the table shares the meeting's own git worktree (in a git project). When it's done,
/// the office commits the output there, or for a review panel posts it on the pull request. The
/// workers stay at the table to be looked at until the room is cleared or the next meeting is called.
class MeetingRoom {
  MeetingRoom(
    /// The project's checkout.
    this._dir,
    this._dataDir,
    this._workers,

    /// Git worktrees, in a project that's a git repository.
    this._trees,
    this._events,
  ) : _statePath = p.join(_dataDir, 'meetings.json') {
    _restore();
    _timer = Timer.periodic(_pumpEvery, (_) => _tick());
  }

  final String _dir;
  final String _dataDir;
  final MeetingWorkers _workers;
  final MeetingTrees? _trees;
  final MeetingEvents _events;
  final String _statePath;
  _Meeting? _current;
  List<MeetingRecord> _past = [];
  late final Timer _timer;
  bool _pumping = false;
  bool _again = false;

  /// Token counts changed: told everyone on the next tick rather than on every worker update.
  bool _dirty = false;
  bool _closing = false;

  /// When each handed-over part's worker was first seen ready without having started on it.
  final _readySince = <_Turn, int>{};

  MeetingState state() => MeetingState(current: _current?.view, past: List.of(_past));

  /// Calls a meeting. Returns why it couldn't, or null once everyone is sitting down.
  String? start(MeetingRequest req, String by) {
    final cur = _current;
    if (cur != null && cur.status == MeetingStatus.running) {
      return 'The meeting room is busy with “${cur.title}”: stop that meeting first';
    }
    final pattern = meetingPatterns[req.pattern]!;
    final paused = _events.hiringPaused();
    if (paused != null) return paused;
    var prompt = req.prompt.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (prompt.length > _promptMax) prompt = prompt.substring(0, _promptMax);
    if (prompt.isEmpty) return 'Say what the meeting is about';
    // Nobody picked: the office's default worker, model and effort included.
    final picked = req.provider != null
        ? AgentChoice(provider: req.provider!, model: req.model, effort: req.effort)
        : (_workers.officeDefault ?? AgentChoice(provider: _workers.defaultProvider));
    final provider = picked.provider;
    if (provider == AgentProvider.custom && _workers.defaultProvider != AgentProvider.custom) {
      return 'Unknown agent provider';
    }
    final model = (provider == AgentProvider.claude || provider == AgentProvider.opencode) && (picked.model ?? '') != ''
        ? picked.model
        : null;
    final effort = provider == AgentProvider.claude ? picked.effort : null;
    final bad =
        validateWorkerModel(WorkerKind.agent, provider, model) ??
        validateWorkerEffort(WorkerKind.agent, provider, effort);
    if (bad != null) return bad;

    final given = [for (final r in req.roles) _cut(r.replaceAll(RegExp(r'\s+'), ' ').trim(), _roleMax)];
    final count = given.isNotEmpty ? given.length : pattern.seats.defaultValue;
    if (count < pattern.seats.min || count > min(pattern.seats.max, meetingSeats.length)) {
      return pattern.seats.min == pattern.seats.max
          ? 'A ${pattern.label} meeting seats ${pattern.seats.min} workers'
          : 'A ${pattern.label} meeting seats ${pattern.seats.min} to ${pattern.seats.max} workers';
    }
    final roles = _numbered([
      for (var i = 0; i < count; i++)
        i < given.length && given[i].isNotEmpty
            ? given[i]
            : i < pattern.roles.length
            ? pattern.roles[i]
            : 'Worker ${i + 1}',
    ]);

    final pr = req.pr != null && req.pr! > 0 ? req.pr : null;
    if (pattern.needs == PatternNeeds.pr && pr == null) return 'A review panel needs a pull request to review';
    final parts = (req.parts ?? const <String>[])
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .take(_partsMax)
        .toList();
    if (pattern.needs == PatternNeeds.parts && parts.length < count - 1) {
      return 'List at least ${count - 1} part${count == 2 ? '' : 's'} for the mappers, one per line (or seat fewer workers)';
    }
    final issue = req.issue != null && req.issue! > 0 ? req.issue : null;
    final rounds = (req.rounds != null && req.rounds! > 0 ? req.rounds! : pattern.rounds.defaultValue).clamp(
      pattern.rounds.min,
      pattern.rounds.max,
    );
    final budget = (req.budget != null && req.budget! > 0 ? req.budget! : count * tokensPerSeat).clamp(
      50000,
      maxMeetingBudget,
    );
    final named = (req.title ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final title = _cut(
      named.isNotEmpty
          ? named
          : pr != null && req.pattern == MeetingPattern.review
          ? 'Review of PR #$pr'
          : _firstLine(prompt),
      100,
    );
    final id = _randomHex(4);
    final slug = slugify(title, 32);
    final asked = (req.output ?? '').trim();
    final output = asked.isNotEmpty ? asked : pattern.output(slug, pr);
    final outputBad = outputProblem(output);
    if (outputBad != null) return outputBad;

    // The last meeting's workers make room: they go home, and their worktree is tidied away after them.
    final last = _current;
    if (last != null) unawaited(_dismiss(last));
    final here = _workers.list();
    if (meetingSeats.take(count).any((d) => here.any((w) => w.deskId == d.id))) {
      return 'Someone is still sitting at the meeting table';
    }

    WorkerWorktree? worktree;
    final trees = _trees;
    if (trees != null) {
      final made = trees.create('meeting-$slug-${id.substring(0, 4)}');
      if (made.worktree == null) return made.error ?? "Couldn't make the meeting's worktree";
      worktree = made.worktree;
    }
    final m = _Meeting(
      id: id,
      pattern: req.pattern,
      title: title,
      prompt: prompt,
      output: output,
      seats: [for (var i = 0; i < roles.length; i++) _Seat(roles[i], meetingSeats[i].id)],
      parts: pattern.needs == PatternNeeds.parts ? parts : null,
      pr: pr,
      issue: issue,
      provider: provider,
      model: model,
      effort: effort,
      rounds: rounds,
      calledBy: by,
      startedAt: _now(),
      worktree: worktree,
      // Without git, the notes go with the floor's other state.
      notes: worktree != null ? meetingNotesDir : '.agent-office/meetings/$id',
      budget: budget,
    );
    try {
      Directory(p.join(_cwd(m), m.notes)).createSync(recursive: true);
    } catch (_) {
      // the first part's writer makes it
    }
    final first = _plan(m, 1, 1) ?? const <_Part>[];
    for (var i = 0; i < m.seats.length; i++) {
      final part = first.where((x) => x.seat == i).firstOrNull;
      final text = '${_brief(m, i)}\n\n${part != null ? _ask(m, part) : _say('meeting.wait')}';
      final r = _workers.seat(m.seats[i].deskId, '$by (meeting)', text, provider, model, effort, (
        id: id,
        worktree: worktree,
      ));
      final w = r.worker;
      if (w == null) {
        for (final s in m.seats) {
          if (s.workerId != null) unawaited(_workers.kill(s.workerId!));
        }
        if (worktree != null && trees != null) unawaited(trees.remove(_ref(worktree), WorktreeCleanup.all));
        return r.error ?? 'The worker could not sit down';
      }
      m.seats[i].workerId = w.id;
      m.seats[i].workerName = w.name;
    }
    final now = _now();
    m.turns = [for (final x in first) _Turn(x.seat, x.doing, x.file, MeetingTurnState.sent, sentAt: now)];
    if (last != null) _archive(last);
    _current = m;
    _changed();
    _events.toast(
      '🤝 $by called a ${pattern.label} meeting: “$title” ($count workers, $rounds round${rounds == 1 ? '' : 's'} at most, ${fmtTokens(budget)} tokens)',
      ToastLevel.info,
    );
    return null;
  }

  /// Stops the meeting that's running. Its workers stay at the table.
  String? stop(String by) {
    final m = _current;
    if (m == null || m.status != MeetingStatus.running) return 'No meeting is on';
    _halt(m, 'stopped by $by');
    return null;
  }

  /// Sends the last meeting's workers home and clears the table.
  String? clear(String by) {
    final m = _current;
    if (m == null) return 'Nobody is in the meeting room';
    if (m.status == MeetingStatus.running) return 'The meeting is still on: stop it first';
    _events.toast('🤝 $by cleared the meeting room', ToastLevel.info);
    unawaited(_dismiss(m));
    _archive(m);
    _current = null;
    _changed();
    return null;
  }

  /// A worker changed: cheap unless it's at the table.
  void onWorker(WorkerInfo info) {
    if (info.meeting != null && info.meeting == _current?.id) pump();
  }

  void onWorkerGone(String workerId) {
    if (_current?.seats.any((s) => s.workerId == workerId) ?? false) pump();
  }

  void pump() {
    if (_closing) return;
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _again = false;
        _run();
      } while (_again);
    } finally {
      _pumping = false;
    }
  }

  void shutdown() {
    _closing = true;
    _timer.cancel();
    _persist();
  }

  // ---------------------------------------------------------------------------------------------

  void _tick() {
    final m = _current;
    if (m != null && m.status == MeetingStatus.running && _readPreview(m)) _dirty = true;
    pump();
    if (_dirty) _changed();
  }

  void _run() {
    final m = _current;
    if (m == null) return;
    final byId = {for (final w in _workers.list()) w.id: w};
    if (_tally(m, byId)) _dirty = true;
    if (m.status != MeetingStatus.running) {
      // Everyone went home one by one: tidy the worktree away after them.
      if (!m.cleared && m.seats.every((s) => s.workerId == null || !byId.containsKey(s.workerId))) {
        unawaited(_dismiss(m));
      }
      return;
    }
    for (final s in m.seats) {
      final w = s.workerId != null ? byId[s.workerId] : null;
      if (w == null) return _halt(m, 'the ${s.role} (${s.workerName ?? 'its worker'}) was sent home');
      if (w.status == WorkerStatus.exited) return _halt(m, "the ${s.role}'s agent (${w.name}) exited");
    }
    if (m.tokens > m.budget) {
      return _halt(m, 'over budget: ${fmtTokens(m.tokens)} of ${fmtTokens(m.budget)} tokens');
    }
    var changed = false;
    for (final t in List.of(m.turns)) {
      changed = _advance(m, t, byId[m.seats[t.seat].workerId]!) || changed;
      if (m.status != MeetingStatus.running) return;
    }
    if (m.turns.every((t) => t.state == MeetingTurnState.done)) {
      _next(m);
      changed = true;
      _again = true;
    }
    if (changed) _changed();
  }

  /// Moves one worker's part along. Returns whether anything changed.
  bool _advance(_Meeting m, _Turn t, WorkerInfo w) {
    final now = _now();
    final seat = m.seats[t.seat];
    switch (t.state) {
      case MeetingTurnState.waiting:
        if (!_ready(w.status)) return false;
        final part = _plan(m, m.round, m.step)?.where((x) => x.seat == t.seat).firstOrNull;
        if (part == null || _workers.prompt(w.id, _ask(m, part), _by) != null) return false;
        t.state = MeetingTurnState.sent;
        t.sentAt = now;
        return true;
      case MeetingTurnState.sent:
        if (w.status == WorkerStatus.working) {
          t.state = MeetingTurnState.working;
          _readySince.remove(t);
          return true;
        }
        if (!_ready(w.status)) {
          _readySince.remove(t);
          return false;
        }
        // Written without our seeing it work (the office restarted in between): that counts.
        if (_written(m, t)) {
          t.state = MeetingTurnState.done;
          return true;
        }
        final since = _readySince[t] ?? now;
        _readySince[t] = since;
        if (now - since < _startGraceMs) return false;
        if (t.retried) {
          _halt(m, 'the ${seat.role} (${seat.workerName}) never started on its part of round ${m.round}');
          return true;
        }
        final part = _plan(m, m.round, m.step)?.where((x) => x.seat == t.seat).firstOrNull;
        t.retried = true;
        _readySince.remove(t);
        if (part != null) _workers.prompt(w.id, _ask(m, part), _by);
        return true;
      case MeetingTurnState.working:
        if (!_ready(w.status)) return false;
        if (_written(m, t)) {
          t.state = MeetingTurnState.done;
          return true;
        }
        if (t.retried) {
          final last = _isLast(m, m.round);
          _halt(
            m,
            last && t.file == m.output
                ? 'reached its round limit without writing ${m.output}: the ${seat.role} ended the last round without it'
                : 'the ${seat.role} (${seat.workerName}) ended round ${m.round} without writing ${t.file}',
          );
          return true;
        }
        t.retried = true;
        _readySince.remove(t);
        _workers.prompt(w.id, _say('meeting.nudge', {'file': p.join(_cwd(m), t.file)}), _by);
        t.state = MeetingTurnState.sent;
        return true;
      case MeetingTurnState.done:
        return false;
    }
  }

  /// Every part of the step is written: on to the next step, the next round, or the end.
  void _next(_Meeting m) {
    // Red / blue: the red team found nothing more to fix, so blue writes it up this round.
    if (m.pattern == MeetingPattern.redblue && m.step == 1 && _nothing.hasMatch(_head(m, m.turns.firstOrNull?.file))) {
      m.lastRound = m.round;
    }
    final more = _plan(m, m.round, m.step + 1);
    if (more != null) {
      m.step++;
      m.turns = [for (final x in more) _Turn(x.seat, x.doing, x.file, MeetingTurnState.waiting)];
      return;
    }
    if (_isLast(m, m.round)) return _finish(m);
    m.round++;
    m.step = 1;
    m.turns = [
      for (final x in _plan(m, m.round, 1) ?? const <_Part>[]) _Turn(x.seat, x.doing, x.file, MeetingTurnState.waiting),
    ];
  }

  bool _isLast(_Meeting m, int round) => round >= m.rounds || m.lastRound == round;

  /// The output is written. Commit it on the meeting's branch, or post the review on its pull request.
  void _finish(_Meeting m) {
    m.status = MeetingStatus.done;
    m.finishedAt = _now();
    m.turns = [];
    _readPreview(m);
    _keepNotes(m);
    final pat = meetingPatterns[m.pattern]!;
    _events.toast('🤝 The ${pat.label} meeting on “${m.title}” is done: it wrote ${m.output}', ToastLevel.info);
    final cwd = _cwd(m);
    final pr = m.pr;
    if (m.pattern == MeetingPattern.review && pr != null) {
      unawaited(
        _events
            .postReview(pr, p.join(cwd, m.output))
            .then(
              (url) {
                m.review = MeetingReview(url: url);
                _events.toast("🔍 Posted the panel's review on PR #$pr", ToastLevel.info);
                _changed();
              },
              onError: (Object err) {
                m.review = MeetingReview(error: _messageOf(err));
                _events.toast("Couldn't post the panel's review on PR #$pr: ${m.review!.error}", ToastLevel.warn);
                _changed();
              },
            ),
      );
    } else if (m.worktree != null) {
      unawaited(
        _commitAll(
          cwd,
          '${m.title}\n\n${pat.label} meeting in Agent Office, called by ${m.calledBy}. Output: ${m.output}',
          m.notes,
        ).then(
          (sha) {
            m.commit = sha;
            _changed();
          },
          onError: (Object err) {
            _events.toast("Couldn't commit ${m.output} on ${m.worktree!.branch}: ${gitError(err)}", ToastLevel.warn);
            _changed();
          },
        ),
      );
    }
  }

  /// Stops the meeting short, saying why. Whoever is still busy is told to stop (Esc).
  void _halt(_Meeting m, String reason) {
    if (m.status != MeetingStatus.running) return;
    m.status = MeetingStatus.stopped;
    m.reason = reason;
    m.finishedAt = _now();
    final busy = {
      for (final w in _workers.list())
        if (w.status == WorkerStatus.working || w.status == WorkerStatus.needsInput) w.id,
    };
    for (final s in m.seats) {
      if (s.workerId != null && busy.contains(s.workerId)) _workers.write(s.workerId!, '\x1b', _by);
    }
    _readPreview(m);
    _keepNotes(m);
    _events.toast('⛔ The meeting on “${m.title}” stopped in round ${m.round}: $reason', ToastLevel.warn);
    _changed();
  }

  /// Sends a meeting's workers home, then tidies its worktree away: the branch stays when the output
  /// was committed on it, and everything stays when something is left uncommitted.
  Future<void> _dismiss(_Meeting m) async {
    if (m.cleared) return;
    m.cleared = true;
    final here = {for (final w in _workers.list()) w.id};
    await Future.wait([
      for (final s in m.seats)
        if (s.workerId != null && here.contains(s.workerId)) _workers.kill(s.workerId!),
    ]);
    final wt = m.worktree;
    final trees = _trees;
    if (wt == null || trees == null) return _persist();
    // Kept with the floor's state already (keepNotes): the notes, and a review panel's review, which
    // is on the pull request now, go, so they don't count as work left behind.
    final cwd = _cwd(m);
    final own = p.join(p.normalize(p.absolute(_dir, '.agent-office', 'worktrees')), '');
    for (final leftover in [m.notes, if (m.pattern == MeetingPattern.review) m.output]) {
      final abs = p.normalize(p.absolute(cwd, leftover));
      if (!abs.startsWith(own)) continue;
      try {
        final type = FileSystemEntity.typeSync(abs);
        if (type == FileSystemEntityType.directory) {
          Directory(abs).deleteSync(recursive: true);
        } else if (type != FileSystemEntityType.notFound) {
          File(abs).deleteSync();
        }
      } catch (_) {
        // left behind: it's counted as a change below
      }
    }
    final ref = _ref(wt);
    final state = await trees.inspect(ref);
    if (state.error != null || state.dirty > 0) {
      final why = state.error ?? '${state.dirty} uncommitted change${state.dirty == 1 ? '' : 's'}';
      _events.toast("Kept the “${m.title}” meeting's worktree and branch ${wt.branch}: $why", ToastLevel.info);
    } else {
      final err = await trees.remove(ref, state.ahead > 0 ? WorktreeCleanup.worktree : WorktreeCleanup.all);
      if (err != null) _events.toast("Couldn't tidy away the meeting's worktree: $err", ToastLevel.warn);
    }
    _persist();
  }

  /// Puts a finished meeting on the list of earlier ones.
  void _archive(_Meeting m) {
    _past = [meetingRecord(m.view), ..._past.where((r) => r.id != m.id)].take(_pastMax).toList();
  }

  /// Adds up what the workers at the table have used. Returns whether it changed.
  bool _tally(_Meeting m, Map<String, WorkerInfo> byId) {
    var tokens = 0;
    var cost = 0.0;
    var known = true;
    for (final s in m.seats) {
      final w = s.workerId != null ? byId[s.workerId] : null;
      // A worker sent home took its figures with it: keep the last ones seen.
      final usage = w?.usage;
      if (w != null && usage != null) {
        s.tokens = tokensOf(usage);
        s.cost = usage.costKnown == false || (w.provider == AgentProvider.codex && usage.costKnown != true)
            ? null
            : usage.cost;
      }
      tokens += s.tokens ?? 0;
      if ((s.tokens ?? 0) != 0 && s.cost == null) known = false;
      cost += s.cost ?? 0;
    }
    if (tokens == m.tokens && cost == m.cost && known == m.costKnown) return false;
    m.tokens = tokens;
    m.cost = cost;
    m.costKnown = known;
    return true;
  }

  // --- The patterns ------------------------------------------------------------------------------

  /// What every worker is told when it sits down, ahead of its first part.
  String _brief(_Meeting m, int i) {
    final pat = meetingPatterns[m.pattern]!;
    final role = m.seats[i].role;
    final others = [
      for (var j = 0; j < m.seats.length; j++)
        if (j != i) 'the ${m.seats[j].role}',
    ];
    final head = m.seats[0].role;
    final how = switch (m.pattern) {
      MeetingPattern.debate =>
        "Round 1: everyone proposes an answer. Each round after that until the last: everyone reads the others' latest notes, critiques them and revises their own. Last round: the $head writes the decision.",
      MeetingPattern.lead =>
        'Round 1: the $head splits the task into a part for each of the others and writes the plan. Round 2: each of them does their part. Round 3: the $head merges the work, checks it and writes it up.',
      MeetingPattern.mapreduce =>
        'Round 1: each mapper does the task over its own parts. Round 2: the $head combines what they found into one result.',
      MeetingPattern.redblue =>
        'Each round the Red team attacks the change (bugs, security holes, edge cases) and the Blue team fixes what holds up. The $head writes it all up in the last round, which comes early if Red finds nothing more.',
      MeetingPattern.review =>
        'Round 1: each reviewer reviews the pull request through their own lens. Round 2: the $head merges the reviews into one, which the office posts on the pull request.',
    };
    final wt = m.worktree;
    final where = wt == null
        ? "You're in the project's folder, which other people use too: don't commit, push or switch branches."
        : m.pattern == MeetingPattern.review
        ? "This is a review: don't change, commit or push anything in the checkout. The only files you write are your notes${i == 0 ? ' and ${m.output}' : ''}."
        : "You all share one git worktree, on the branch ${wt.branch}. Don't commit, push or switch branches: when the meeting is over, the office commits ${m.output}, with whatever else was changed, there.";
    // The worktree sits inside the project's own folder, where a search can wander off to.
    final inside = wt != null
        ? ' The whole project is checked out in your working directory: read and write files there, by paths inside it, and never in a folder above it.'
        : '';
    return _say('meeting.brief', {
      'title': m.title,
      'role': role,
      'pattern': pat.label,
      'others': _list(others),
      'how': how,
      'about': m.prompt,
      'pullRequest': m.pr != null
          ? 'The pull request is #${m.pr}: read it with gh pr view ${m.pr} and gh pr diff ${m.pr}.'
          : '',
      'issue': m.issue != null ? 'It comes from GitHub issue #${m.issue}: gh issue view ${m.issue} --comments.' : '',
      'cwd': _cwd(m),
      'notes': p.join(_cwd(m), m.notes),
      'output': m.output,
      'outputPath': p.join(_cwd(m), m.output),
      'rounds': '${m.rounds} round${m.rounds == 1 ? '' : 's'}',
      'budget': fmtTokens(m.budget),
      'where': where + inside,
    });
  }

  /// One of the office's prompts, filled in.
  String _say(PromptId id, [PromptVars vars = const {}]) =>
      fillPrompt(_events.prompt?.call(id) ?? prompts[id]!.text, vars);

  /// A part, as the prompt that hands it over.
  String _ask(_Meeting m, _Part part) => 'Round ${m.round} of ${m.rounds}, ${part.doing}. ${part.ask}';

  /// The parts of step [step] of round [round], or null when that round has no such step.
  List<_Part>? _plan(_Meeting m, int round, int step) {
    // Parts name their files by full path: a worktree sits inside the project's own folder, and an
    // agent can take a relative path to be the project's (and then it's asked about writing outside).
    String a(String rel) => p.join(_cwd(m), rel);
    String note(int r, int i) => '${m.notes}/r$r-${i + 1}-${slugify(m.seats[i].role, 24)}.md';
    String notes(int r, List<int> seats) => seats.map((i) => a(note(r, i))).join(', ');
    final all = [for (var i = 0; i < m.seats.length; i++) i];
    final last = _isLast(m, round);
    switch (m.pattern) {
      case MeetingPattern.debate:
        if (step > 1) return null;
        if (last) {
          return [
            (
              seat: 0,
              doing: 'writing the decision',
              file: m.output,
              ask: _say('meeting.debate.decide', {
                'notes': a(m.notes),
                'lastNotes': notes(round - 1, all),
                'output': a(m.output),
              }),
            ),
          ];
        }
        if (round == 1) {
          return [
            for (final i in all)
              (
                seat: i,
                doing: 'proposing',
                file: note(1, i),
                ask: _say('meeting.debate.propose', {'role': m.seats[i].role, 'file': a(note(1, i))}),
              ),
          ];
        }
        return [
          for (final i in all)
            (
              seat: i,
              doing: 'critiquing',
              file: note(round, i),
              ask: _say('meeting.debate.critique', {
                'previousRound': round - 1,
                'theirNotes': notes(round - 1, all.where((j) => j != i).toList()),
                'file': a(note(round, i)),
              }),
            ),
        ];
      case MeetingPattern.lead:
        final team = all.sublist(1);
        if (step > 1) return null;
        final plan = '${m.notes}/plan.md';
        if (round == 1) {
          final parts = '${team.length} part${team.length == 1 ? '' : 's'}';
          return [
            (
              seat: 0,
              doing: 'planning',
              file: plan,
              ask: _say('meeting.lead.plan', {
                'parts': parts,
                'team': _list([for (final i in team) 'the ${m.seats[i].role}']),
                'exampleRole': m.seats[team[0]].role,
                'file': a(plan),
              }),
            ),
          ];
        }
        if (round == 2) {
          return [
            for (final i in team)
              (
                seat: i,
                doing: 'doing their part',
                file: note(2, i),
                ask: _say('meeting.lead.part', {
                  'plan': a(plan),
                  'role': m.seats[i].role,
                  'lead': m.seats[0].role,
                  'file': a(note(2, i)),
                }),
              ),
          ];
        }
        return [
          (
            seat: 0,
            doing: 'merging the work',
            file: m.output,
            ask: _say('meeting.lead.merge', {'reports': notes(2, team), 'output': a(m.output)}),
          ),
        ];
      case MeetingPattern.mapreduce:
        if (step > 1) return null;
        final mappers = all.sublist(1);
        if (round == 1) {
          final given = m.parts ?? const <String>[];
          return [
            for (var k = 0; k < mappers.length; k++)
              (
                seat: mappers[k],
                doing: 'mapping',
                file: note(1, mappers[k]),
                ask: _say('meeting.mapreduce.map', {
                  'parts': [
                    for (var j = 0; j < given.length; j++)
                      if (j % mappers.length == k) '- ${given[j]}',
                  ].join('\n'),
                  'file': a(note(1, mappers[k])),
                }),
              ),
          ];
        }
        return [
          (
            seat: 0,
            doing: 'reducing',
            file: m.output,
            ask: _say('meeting.mapreduce.reduce', {'results': notes(1, mappers), 'output': a(m.output)}),
          ),
        ];
      case MeetingPattern.redblue:
        const blue = 0, red = 1;
        final redNote = '${m.notes}/r$round-red.md';
        final blueNote = '${m.notes}/r$round-blue.md';
        if (step == 1) {
          final before = round > 1
              ? " The Blue team's fixes from round ${round - 1} are in ${a('${m.notes}/r${round - 1}-blue.md')}: check them first, then keep looking."
              : '';
          return [
            (
              seat: red,
              doing: 'attacking',
              file: redNote,
              ask: _say('meeting.redblue.attack', {'previousFixes': before, 'file': a(redNote)}),
            ),
          ];
        }
        if (step > 2) return null;
        if (m.lastRound == round) {
          return [
            (
              seat: blue,
              doing: 'writing it up',
              file: m.output,
              ask: _say('meeting.redblue.writeup', {
                'findings': a(redNote),
                'notes': a(m.notes),
                'output': a(m.output),
              }),
            ),
          ];
        }
        final wrap = last
            ? " This is the last round: once you've fixed things, also write ${a(m.output)}: every finding from every round (${a(m.notes)}/), what was fixed and how, and what's still open. That file is the meeting's output."
            : '';
        return [
          (
            seat: blue,
            doing: last ? 'fixing and writing it up' : 'fixing',
            file: last ? m.output : blueNote,
            ask: _say('meeting.redblue.fix', {
              'findings': a(redNote),
              'file': a(blueNote),
              'lastRound': wrap,
              'output': a(m.output),
            }),
          ),
        ];
      case MeetingPattern.review:
        if (step > 1) return null;
        if (round == 1) {
          return [
            for (final i in all)
              (
                seat: i,
                doing: 'reviewing',
                file: note(1, i),
                ask: _say('meeting.review.review', {'pr': m.pr, 'role': m.seats[i].role, 'file': a(note(1, i))}),
              ),
          ];
        }
        return [
          (
            seat: 0,
            doing: 'writing the review',
            file: m.output,
            ask: _say('meeting.review.combine', {
              'findings': notes(1, all),
              'exampleRole': m.seats.length > 1 ? m.seats[1].role : 'Security',
              'output': a(m.output),
            }),
          ),
        ];
    }
  }

  // --- Files -------------------------------------------------------------------------------------

  String _cwd(_Meeting m) => m.worktree != null ? p.join(_dir, m.worktree!.path) : _dir;

  /// Whether a part's file is there, with something in it, written since the part was handed over.
  bool _written(_Meeting m, _Turn t) {
    try {
      final st = File(p.join(_cwd(m), t.file)).statSync();
      return st.type == FileSystemEntityType.file &&
          st.size > 0 &&
          st.modified.millisecondsSinceEpoch >= (t.sentAt ?? 0) - 2000;
    } catch (_) {
      return false;
    }
  }

  /// The first line of a notes file with something on it ('' when there's no such file).
  String _head(_Meeting m, String? file) {
    if (file == null) return '';
    try {
      return _readStart(
        p.join(_cwd(m), file),
        400,
      ).split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    } catch (_) {
      return '';
    }
  }

  /// Reads what's written of the output so far, for the board in the room. Returns whether it changed.
  bool _readPreview(_Meeting m) {
    String? text;
    try {
      final s = _readStart(p.join(_cwd(m), m.output), _previewChars * 2);
      text = s.length > _previewChars ? s.substring(0, _previewChars) : s;
    } catch (_) {
      text = null;
    }
    if (text == m.preview) return false;
    m.preview = text;
    return true;
  }

  /// Copies the meeting's notes and output next to the floor's other state, where they outlive its worktree.
  void _keepNotes(_Meeting m) {
    try {
      final to = p.join(_dataDir, 'meetings', m.id);
      final from = p.join(_cwd(m), m.notes);
      if (p.normalize(p.absolute(from)) != p.normalize(p.absolute(to)) && Directory(from).existsSync()) {
        _copyDir(Directory(from), to);
      }
      final out = File(p.join(_cwd(m), m.output));
      if (out.existsSync()) {
        Directory(to).createSync(recursive: true);
        out.copySync(p.join(to, 'output-${p.basename(m.output)}'));
      }
    } catch (_) {
      // the notes are a courtesy; the meeting is over either way
    }
  }

  void _changed() {
    _dirty = false;
    _persist();
    _events.update(state());
  }

  void _persist() {
    try {
      final tmp = '$_statePath.tmp';
      File(tmp).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'current': _current?.view.toJson(),
          'past': [for (final r in _past) r.toJson()],
        }),
      );
      chmodSync(tmp, 0x180); // 0600
      File(tmp).renameSync(_statePath);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _restore() {
    final file = File(_statePath);
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      if (saved is! Map) return;
      final past = saved['past'];
      if (past is List) {
        _past = [
          for (final r in past)
            if (r is Map && r['id'] is String && r['summary'] is String)
              MeetingRecord.fromJson(Map<String, dynamic>.from(r)),
        ].take(_pastMax).toList();
      }
      final m = saved['current'];
      // The workers at the table outlive a restart of the office, so a meeting carries on where it was.
      if (m is Map && m['id'] is String && isMeetingPattern(m['pattern']) && m['seats'] is List && m['turns'] is List) {
        _current = _Meeting.of(Meeting.fromJson(Map<String, dynamic>.from(m)));
      }
    } catch (_) {
      // corrupt state file: an empty room
    }
  }
}

/// Commits everything in a checkout but [leaveOut] (the notes); resolves to the commit's short hash,
/// or null when there was nothing to commit.
Future<String?> _commitAll(String cwd, String message, String leaveOut) async {
  Future<String> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: cwd).timeout(const Duration(seconds: 60));
    if (r.exitCode != 0) throw GitException('${r.stderr}'.trim().isNotEmpty ? '${r.stderr}'.trim() : 'git failed');
    return '${r.stdout}'.trim();
  }

  await git(['add', '-A', '--', '.', ':(exclude)$leaveOut']);
  if ((await git(['diff', '--cached', '--name-only'])).isEmpty) return null;
  await git(['commit', '-q', '-m', message]);
  return git(['rev-parse', '--short', 'HEAD']);
}

/// The start of a file, at most [bytes] of it.
String _readStart(String file, int bytes) {
  final f = File(file).openSync();
  try {
    final data = f.readSync(bytes);
    return utf8.decode(data, allowMalformed: true).replaceFirst(RegExp('�+\$'), '');
  } finally {
    f.closeSync();
  }
}

void _copyDir(Directory from, String to) {
  Directory(to).createSync(recursive: true);
  for (final e in from.listSync()) {
    final dest = p.join(to, p.basename(e.path));
    if (e is Directory) {
      _copyDir(e, dest);
    } else if (e is File) {
      e.copySync(dest);
    }
  }
}

/// Roles that repeat get numbered, so each worker at the table has one of its own: Engineer 1, Engineer 2.
List<String> _numbered(List<String> roles) {
  final seen = <String, int>{};
  final count = <String, int>{};
  for (final r in roles) {
    count[r.toLowerCase()] = (count[r.toLowerCase()] ?? 0) + 1;
  }
  return [
    for (final r in roles)
      if ((count[r.toLowerCase()] ?? 0) < 2) r else '$r ${seen[r.toLowerCase()] = (seen[r.toLowerCase()] ?? 0) + 1}',
  ];
}

/// "a", "a and b", "a, b and c".
String _list(List<String> xs) =>
    xs.length < 2 ? (xs.firstOrNull ?? '') : '${xs.sublist(0, xs.length - 1).join(', ')} and ${xs.last}';

String _firstLine(String s) => s.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');

String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

WorktreeRef _ref(WorkerWorktree wt) => WorktreeRef(path: wt.path, branch: wt.branch, base: wt.base);

final _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

String _messageOf(Object err) => switch (err) {
  GitException(:final message) => message,
  _ => '$err'.replaceFirst(RegExp(r'^(Exception|_RunError|GhError): '), ''),
};
