// The meeting room's window (ui/meeting.ts). With a meeting at the table it shows how it's going (and
// stops it, or clears the table once it's over); otherwise, or with a preset from an issue or a PR,
// it's the form that calls one: the pattern, what it's about, who sits down, the output, the bounds.

import 'package:flutter/material.dart';
import 'package:office_shared/meetings.dart';
import 'package:office_shared/protocol.dart';

import '../interop/open_link.dart';
import '../state/store.dart';
import '../world/meeting.dart' show meetingStage;
import 'confirm.dart';
import 'modal.dart';
import 'provider.dart';
import 'theme.dart';
import 'window_parts.dart';
import 'markdown.dart' show mono;
import 'worker_text.dart' show hexColor, statusLabel;

/// What a meeting called from an issue, a PR or a task starts out with.
class MeetingPreset {
  const MeetingPreset({this.pattern, this.prompt, this.title, this.pr, this.issue});
  final MeetingPattern? pattern;
  final String? prompt;
  final String? title;
  final int? pr;
  final int? issue;
}

const Map<MeetingTurnState, String> _partLabel = {
  MeetingTurnState.waiting: '⏳ up next',
  MeetingTurnState.sent: '📨 handed over',
  MeetingTurnState.working: '💬 on it',
  MeetingTurnState.done: '✅ written',
};

/// The request the form sends, worked out from what's in it; or what's missing.
({MeetingRequest? request, String? problem}) meetingRequest({
  required MeetingPattern pattern,
  required String prompt,
  required String title,
  required String output,
  required List<String> roles,
  required String parts,
  int? pr,
  int? issue,
  int? rounds,
  double? budgetThousands,
  AgentProvider? provider,
  String? model,
}) {
  final def = meetingPatterns[pattern]!;
  if (prompt.trim().isEmpty) return (request: null, problem: 'Say what the meeting is about');
  if (def.needs == PatternNeeds.pr && pr == null) return (request: null, problem: 'Pick a pull request');
  final list = parts.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (def.needs == PatternNeeds.parts && list.length < roles.length - 1) {
    return (request: null, problem: 'List at least ${roles.length - 1} parts, one per line, or seat fewer workers');
  }
  final bad = outputProblem(output.trim());
  if (bad != null) return (request: null, problem: bad);
  final budget = ((budgetThousands ?? 0) * 1000).round();
  return (
    request: MeetingRequest(
      pattern: pattern,
      prompt: prompt.trim(),
      title: title.trim().isEmpty ? null : title.trim(),
      output: output.trim(),
      roles: [for (final r in roles) r.trim()],
      parts: def.needs == PatternNeeds.parts ? list : null,
      pr: def.needs == PatternNeeds.pr ? pr : null,
      issue: issue,
      rounds: rounds,
      budget: budget > 0 ? budget : null,
      provider: provider,
      model: model,
    ),
    problem: null,
  );
}

ModalHandle openMeeting({
  required Store store,
  required void Function(ClientMsg msg) send,
  required void Function(String workerId) openTerminal,
  void Function(String workerId)? openPr,
  MeetingPreset? preset,
}) => ModalStack.instance.show(
  (modal) => _MeetingWindow(
    modal: modal,
    store: store,
    send: send,
    openTerminal: openTerminal,
    openPr: openPr,
    preset: preset,
  ),
)..doing = '🤝 at the meeting room';

class _MeetingWindow extends StatefulWidget {
  const _MeetingWindow({
    required this.modal,
    required this.store,
    required this.send,
    required this.openTerminal,
    required this.openPr,
    required this.preset,
  });

  final ModalHandle modal;
  final Store store;
  final void Function(ClientMsg msg) send;
  final void Function(String workerId) openTerminal;
  final void Function(String workerId)? openPr;
  final MeetingPreset? preset;

  @override
  State<_MeetingWindow> createState() => _MeetingWindowState();
}

class _MeetingWindowState extends State<_MeetingWindow> {
  late bool _form = widget.preset != null || widget.store.rooms.meeting.current == null;
  late MeetingPattern _pattern = widget.preset?.pattern ?? MeetingPattern.debate;
  late final TextEditingController _about = TextEditingController(text: widget.preset?.prompt ?? '');
  late final TextEditingController _title = TextEditingController(text: widget.preset?.title ?? '');
  final TextEditingController _output = TextEditingController();
  final TextEditingController _parts = TextEditingController();
  final TextEditingController _rounds = TextEditingController();
  final TextEditingController _budget = TextEditingController();
  final List<TextEditingController> _roles = [];
  late final ProviderPickerController _provider = ProviderPickerController(widget.store.project);
  late int? _pr = widget.preset?.pr;
  bool _outputTouched = false, _budgetTouched = false;

  Store get store => widget.store;
  PatternDef get _def => meetingPatterns[_pattern]!;

  @override
  void initState() {
    super.initState();
    store.rooms.meetingChanged.addListener(_changed);
    store.topic(Topic.workers).addListener(_changed);
    store.topic(Topic.pulls).addListener(_changed);
    _pick(_pattern);
    _about.addListener(_syncOutput);
    _title.addListener(_syncOutput);
  }

  @override
  void dispose() {
    store.rooms.meetingChanged.removeListener(_changed);
    store.topic(Topic.workers).removeListener(_changed);
    store.topic(Topic.pulls).removeListener(_changed);
    for (final c in [_about, _title, _output, _parts, _rounds, _budget, ..._roles]) {
      c.dispose();
    }
    _provider.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _slug() {
    final t = _title.text.trim();
    final first = _about.text.trim().split('\n').first;
    return slugify(t.isNotEmpty ? t : (first.isNotEmpty ? first : 'meeting'), 32);
  }

  void _syncOutput() {
    if (!_outputTouched) {
      final v = _def.output(_slug(), _pr);
      if (_output.text != v) _output.text = v;
    }
    if (mounted) setState(() {});
  }

  void _syncBudget() {
    if (!_budgetTouched) _budget.text = '${_roles.length * tokensPerSeat ~/ 1000}';
  }

  void _pick(MeetingPattern p) {
    _pattern = p;
    for (final c in _roles) {
      c.dispose();
    }
    _roles
      ..clear()
      ..addAll([for (final r in _def.roles.take(_def.seats.defaultValue)) TextEditingController(text: r)]);
    _rounds.text = '${_def.rounds.defaultValue}';
    _syncBudget();
    _syncOutput();
  }

  void _seats(int by) {
    setState(() {
      if (by < 0 && _roles.length > _def.seats.min) _roles.removeLast().dispose();
      if (by > 0 && _roles.length < _def.seats.max) {
        final n = _roles.length;
        _roles.add(TextEditingController(text: n < _def.roles.length ? _def.roles[n] : 'Worker ${n + 1}'));
      }
      _syncBudget();
    });
  }

  void _start() {
    if (store.rooms.meeting.current?.status == MeetingStatus.running) return;
    if (!_provider.valid()) return;
    final r = meetingRequest(
      pattern: _pattern,
      prompt: _about.text,
      title: _title.text,
      output: _output.text,
      roles: [for (final c in _roles) c.text],
      parts: _parts.text,
      pr: _pr,
      issue: widget.preset?.issue,
      rounds: int.tryParse(_rounds.text),
      budgetThousands: double.tryParse(_budget.text),
      provider: _provider.value(),
      model: _provider.model(),
    );
    final req = r.request;
    if (req == null) return toast(r.problem!, ToastKind.warn);
    widget.send(MeetingStartCmd(req));
    toast('🤝 Calling the ${_def.label} meeting: the workers are heading for the meeting room');
    widget.modal.close();
  }

  @override
  Widget build(BuildContext context) {
    final m = store.rooms.meeting.current;
    final status = !_form && m != null;
    return ModalWindow(
      modal: widget.modal,
      width: 720,
      title: Text(status ? '🤝 Meeting room' : '🤝 Call a meeting'),
      body: status ? _status(m) : _formBody(),
      footer: status ? _statusFoot(m) : _formFoot(),
    );
  }

  // ---- How it's going -------------------------------------------------------------------------

  Widget _status(Meeting m) {
    final p = meetingPatterns[m.pattern]!;
    final running = m.status == MeetingStatus.running;
    final f = (m.tokens / (m.budget < 1 ? 1 : m.budget)).clamp(0.0, 1.0);
    final line = running
        ? '${meetingStage(m)} · called by ${m.calledBy} ${timeAgo(m.startedAt)}'
        : m.status == MeetingStatus.done
        ? '✅ Wrote ${m.output} in ${m.round} round${m.round == 1 ? '' : 's'}'
        : '⛔ Stopped in round ${m.round}: ${m.reason ?? 'stopped'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _pill(
              running ? 'in a meeting' : m.status.wire,
              running ? Swatch.warn : (m.status == MeetingStatus.done ? Swatch.good : Swatch.bad),
            ),
            Text('${p.icon} ${p.label}', style: heavy(15)),
            Tooltip(
              message: m.prompt,
              child: Text(m.title, style: heavy(15, weight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(line, style: heavy(13, color: Swatch.muted)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: f,
                  minHeight: 10,
                  backgroundColor: Swatch.paper2,
                  color: f > 0.9
                      ? Swatch.bad
                      : f > 0.7
                      ? Swatch.warn
                      : Swatch.good,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${meetingSpend(tokens: m.tokens, cost: m.cost, costKnown: m.costKnown)} of ${fmtTokens(m.budget)} tokens',
              style: heavy(12, color: Swatch.muted),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < m.seats.length; i++) _seat(m, i, running),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('📄 ', style: heavy(14)),
            Text(m.output, style: mono(13)),
            if (m.worktree != null)
              Text(
                '  🌿 ${m.worktree!.branch}${m.commit != null ? ' · committed ${m.commit}' : ''}',
                style: heavy(12, color: Swatch.muted),
              ),
            const Spacer(),
            if (m.review?.url != null)
              OfficeButton(
                label: '🔍 The review on PR #${m.pr} ↗',
                dense: true,
                onPressed: () => openInNewTab(m.review!.url!),
              ),
          ],
        ),
        if (m.review?.error != null)
          Text("Couldn't post the review: ${m.review!.error}", style: heavy(12, color: Swatch.bad)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 260),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Swatch.ink, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: Text(
              m.preview?.trim().isNotEmpty == true
                  ? m.preview!
                  : (running ? 'Nothing written yet.' : 'Nothing was written.'),
              style: mono(12.5),
            ),
          ),
        ),
        if (store.rooms.meeting.past.isNotEmpty) ...[
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Earlier meetings (${store.rooms.meeting.past.length})', style: heavy(13)),
            children: [
              for (final r in store.rooms.meeting.past)
                ListTile(
                  dense: true,
                  title: Text(r.title, style: heavy(13)),
                  subtitle: Text(
                    r.summary,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _seat(Meeting m, int i, bool running) {
    final s = m.seats[i];
    final w = s.workerId != null ? store.workers[s.workerId] : null;
    final t = m.turns.where((x) => x.seat == i).firstOrNull;
    final part = running ? (t != null ? '${_partLabel[t.state]}: ${t.doing}' : '👂 listening') : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: w != null ? hexColor(w.color) : const Color(0xFFADB5BD),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(s.role, style: heavy(13)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${i == 0 ? 'head of the table · ' : ''}${s.workerName ?? '…'}${w != null ? ' · ${statusLabel(w.status)}' : ' · gone home'}${part.isNotEmpty ? ' · $part' : ''}${s.tokens != null ? ' · ${fmtTokens(s.tokens!)} tokens' : ''}',
              style: heavy(12, color: Swatch.muted, weight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (w != null) ...[
            const SizedBox(width: 6),
            OfficeButton(label: '🖥️ Terminal', dense: true, onPressed: () => widget.openTerminal(w.id)),
          ],
        ],
      ),
    );
  }

  Widget _statusFoot(Meeting m) {
    final running = m.status == MeetingStatus.running;
    final headId = m.seats.isNotEmpty ? m.seats.first.workerId : null;
    final head = headId != null ? store.workers[headId] : null;
    return footerRow([
      FooterNote(
        running
            ? 'The workers stay at the table after it ends, so you can read their terminals.'
            : 'Clearing the room sends the workers home. A committed output stays on its branch.',
      ),
      if (running)
        OfficeButton(
          label: '⛔ Stop meeting',
          onPressed: () => confirmDialog(
            'Stop the meeting?',
            'The workers stop where they are and stay at the table. ${m.output} is only there if it was written.',
            'Stop it',
            () => widget.send(const MeetingStopCmd()),
          ),
        ),
      if (!running && m.commit != null && head?.worktree != null && widget.openPr != null)
        OfficeButton(
          label: head!.pr != null ? '🔀 PR #${head.pr!.number}' : '🔀 Open PR',
          onPressed: () => widget.openPr!(head.id),
        ),
      if (!running) OfficeButton(label: '🧹 Clear the room', onPressed: () => widget.send(const MeetingClearCmd())),
      if (!running)
        OfficeButton(label: '🤝 Call a meeting…', kind: BtnKind.primary, onPressed: () => setState(() => _form = true)),
    ]);
  }

  Widget _pill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: Text(text, style: heavy(11)),
  );

  // ---- Calling one ----------------------------------------------------------------------------

  Widget _field(String label, Widget child, [String? note, bool bad = false]) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label.isNotEmpty) FieldLabel(label),
        child,
        if (note != null)
          Text(
            note,
            style: heavy(11.5, color: bad ? Swatch.bad : Swatch.muted, weight: FontWeight.w600),
          ),
      ],
    ),
  );

  Widget _area(TextEditingController c, String hint, int lines) => TextField(
    controller: c,
    minLines: lines,
    maxLines: lines + 4,
    style: heavy(14, weight: FontWeight.w500),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: heavy(14, color: Swatch.muted, weight: FontWeight.w400),
    ),
  );

  Widget _formBody() {
    final def = _def;
    final open = store.pulls.items.where((p) => p.state == 'OPEN').toList();
    final problem = outputProblem(_output.text.trim());
    final m = store.rooms.meeting.current;
    final taken = m?.status == MeetingStatus.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [for (final id in meetingPatternIds) _patternCard(id)]),
        const SizedBox(height: 12),
        _field(
          'What’s it about?',
          _area(_about, 'The question to settle, or the task to do: e.g. “Should the dog use A* or a navmesh?”', 3),
        ),
        _field('', BoxInput(controller: _title, hint: 'Title (optional): the first line otherwise', maxLength: 100)),
        if (def.needs == PatternNeeds.pr)
          _field(
            'Pull request',
            DropdownButton<int?>(
              value: _pr,
              isExpanded: true,
              hint: Text(open.isEmpty ? 'No open pull requests' : 'Pick a pull request…', style: heavy(13)),
              items: [
                if (_pr != null && !open.any((p) => p.number == _pr))
                  DropdownMenuItem(
                    value: _pr,
                    child: Text('#$_pr', style: heavy(13)),
                  ),
                for (final p in open)
                  DropdownMenuItem(
                    value: p.number,
                    child: Text(clip('#${p.number} ${p.title}', 70), style: heavy(13)),
                  ),
              ],
              onChanged: (v) => setState(() {
                _pr = v;
                _syncOutput();
              }),
            ),
          ),
        if (def.needs == PatternNeeds.parts)
          _field(
            'Parts, one per line',
            _area(_parts, 'src/server/\nsrc/client/\nsrc/shared/', 3),
            'Handed out to the mappers in turn: files, folders, modules or issues.',
          ),
        _field(
          'Output file',
          BoxInput(controller: _output, onChanged: (_) => setState(() => _outputTouched = true)),
          problem != null
              ? '⚠️ $problem'
              : _pattern == MeetingPattern.review
              ? 'It ends when this file is written; the office then posts it on the PR as one review.'
              : store.project?.branch != null
              ? 'It ends when this file is written; the office commits it on the meeting’s own branch.'
              : 'It ends when this file is written.',
          problem != null,
        ),
        _field(
          '',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const FieldLabel('Workers at the table'),
                  const SizedBox(width: 10),
                  OfficeButton(
                    label: '−',
                    dense: true,
                    onPressed: _roles.length > def.seats.min ? () => _seats(-1) : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('${_roles.length}', style: heavy(15)),
                  ),
                  OfficeButton(
                    label: '+',
                    dense: true,
                    onPressed: _roles.length < def.seats.max ? () => _seats(1) : null,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < _roles.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: Text(i == 0 ? '👑' : '${i + 1}', style: heavy(13, color: Swatch.muted)),
                      ),
                      Expanded(child: BoxInput(controller: _roles[i], maxLength: 40)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                'Round limit',
                BoxInput(controller: _rounds, enabled: def.rounds.min != def.rounds.max),
                '${def.roundsNote} (${def.rounds.min}–${def.rounds.max})',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                'Token budget (thousands)',
                BoxInput(controller: _budget, onChanged: (_) => _budgetTouched = true),
                'For everyone at the table together. Over it, the meeting stops.',
              ),
            ),
          ],
        ),
        ProviderPicker(controller: _provider, label: 'Workers'),
        if (m != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              taken
                  ? 'The room is busy with “${m.title}” until it ends or someone stops it.'
                  : 'Starting this sends the last meeting’s workers home.',
              style: heavy(12.5, color: taken ? Swatch.bad : Swatch.muted),
            ),
          ),
      ],
    );
  }

  Widget _patternCard(MeetingPattern id) {
    final d = meetingPatterns[id]!;
    final on = id == _pattern;
    return GestureDetector(
      onTap: () => setState(() => _pick(id)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 210,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFFFE3C8) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? Swatch.accent : Swatch.ink, width: on ? 3 : 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${d.icon} ${d.label}', style: heavy(13.5)),
              Text(
                d.blurb,
                style: heavy(11, color: Swatch.muted, weight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formFoot() {
    final taken = store.rooms.meeting.current?.status == MeetingStatus.running;
    final back = store.rooms.meeting.current != null;
    return footerRow([
      const FooterNote('Few rounds and a file at the end: that’s what keeps meetings cheap.'),
      OfficeButton(
        label: back ? '← Back' : 'Cancel',
        onPressed: back ? () => setState(() => _form = false) : widget.modal.close,
      ),
      OfficeButton(label: '🤝 Start the meeting', kind: BtnKind.primary, onPressed: taken ? null : _start),
    ]);
  }
}
