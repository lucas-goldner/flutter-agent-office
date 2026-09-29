// The 📌 Issues and 🔀 Pull Requests boards: sticky notes in columns on cork, from the store's
// GitHub state. A port of boards.ts; the column rules and prompts are in gh_logic.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../interop/portable.dart';
import '../office_scope.dart';
import 'package:office_shared/layout.dart' show deskById;
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'gh_logic.dart';
import 'modal.dart';
import 'pull.dart';
import 'theme.dart';

enum BoardKind { issues, pulls }

const _tilts = [-1.2, 0.8, -0.4, 1.4, 0.0, -0.9];
const _cork = Color(0xFFD8A86A);

/// Opens the issues or pull requests board.
ModalHandle openBoard(OfficeScope scope, BoardKind kind) =>
    ModalStack.instance.show((modal) => _BoardWindow(modal: modal, scope: scope, kind: kind))
      ..doing = kind == BoardKind.issues ? '📋 at the issues board' : '🔀 at the PR board';

class _BoardWindow extends StatefulWidget {
  const _BoardWindow({required this.modal, required this.scope, required this.kind});
  final ModalHandle modal;
  final OfficeScope scope;
  final BoardKind kind;

  @override
  State<_BoardWindow> createState() => _BoardWindowState();
}

class _BoardWindowState extends State<_BoardWindow> {
  Timer? _timer;
  Store get store => widget.scope.store;

  /// The labels each column is filtered to (column key → label names), kept in this browser.
  late final Map<String, List<String>> filters = parseLabelFilters(storageGet(_filtersKey));

  /// The column whose label picker is open, if any.
  String? picking;

  String get _filtersKey => labelFiltersKey(store.floor, store.project?.dir, widget.kind == BoardKind.issues ? 'issues' : 'pulls');

  void _setFilter(String key, List<String> labels) {
    setState(() {
      if (labels.isEmpty) {
        filters.remove(key);
      } else {
        filters[key] = labels;
      }
    });
    storageSet(_filtersKey, jsonEncode(filters));
  }

  /// A column of cards. Click its header to filter it by label.
  Widget _column<T extends Object>(BoardColumn<T> col, Map<String, String> all, Widget Function(T it, int i) cardOf) {
    final picked = filters[col.key] ?? const <String>[];
    final f = filterColumn(col, picked);
    return _ColumnView(
      title: col.title,
      count: f.count,
      picked: picked,
      open: picking == col.key,
      empty: picked.isEmpty ? 'Nothing here' : 'Nothing here with those labels',
      colors: all,
      choices: picking == col.key ? pickerLabels(col, all, picked) : const [],
      onHead: () => setState(() => picking = picking == col.key ? null : col.key),
      onPick: (labels) => _setFilter(col.key, labels),
      cards: [for (var i = 0; i < f.shown.length; i++) cardOf(f.shown[i], i)],
    );
  }

  @override
  void initState() {
    super.initState();
    // "Updated 2m ago" keeps counting.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final issues = widget.kind == BoardKind.issues;
    final screen = MediaQuery.sizeOf(context);
    // Which desk a PR came from can change (a worker sent home, a PR opened from a desk), and so
    // can the worker on an issue.
    final topics = [issues ? Topic.issues : Topic.pulls, Topic.queue, Topic.workers];
    return ListenableBuilder(
      listenable: store.topics(topics),
      builder: (context, _) {
        final loading = issues ? store.issues.loading : store.pulls.loading;
        final fetchedAt = issues ? store.issues.fetchedAt : store.pulls.fetchedAt;
        final status = loading ? 'Refreshing…' : (fetchedAt > 0 ? 'Updated ${timeAgo(fetchedAt)}' : '');
        return Semantics(
          label: issues ? 'Issues board' : 'Pull requests board',
          child: ModalWindow(
            modal: widget.modal,
            width: 1400,
            height: math.min(860, screen.height - 32),
            scrollBody: false,
            bodyPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Text(issues ? '📌 Issues' : '🔀 Pull Requests'),
                const SizedBox(width: 10),
                Flexible(child: Text(status, style: heavy(12, color: Swatch.muted, weight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
              ],
            ),
            headerExtras: [
              OfficeButton(label: '🔄 Refresh', tooltip: 'Refresh from GitHub', onPressed: () => widget.scope.net.send(const GhRefreshCmd())),
            ],
            body: CustomPaint(painter: const _CorkPainter(), child: _body(issues)),
          ),
        );
      },
    );
  }

  Widget _body(bool issues) {
    final error = issues ? store.issues.error : store.pulls.error;
    final empty = issues ? store.issues.items.isEmpty : store.pulls.items.isEmpty;
    if (error != null && empty) return _BoardError(error);
    final columns = issues ? _issueColumns() : _pullColumns();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, c) {
          // Columns share the width, but never get narrower than 220px; then the board scrolls.
          final n = columns.length;
          final w = math.max(220.0, (c.maxWidth - 12 * (n - 1)) / n);
          final row = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < n; i++) ...[if (i > 0) const SizedBox(width: 12), SizedBox(width: w, child: columns[i])],
            ],
          );
          return w * n + 12 * (n - 1) > c.maxWidth + 0.5
              ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(height: c.maxHeight, child: row))
              : row;
        },
      ),
    );
  }

  List<Widget> _issueColumns() => [
        for (final col in issueColumns(store.issues.items, store.taskForIssue))
          _column<GhIssue>(
            col,
            boardLabels(store.issues.items),
            (it, i) => BoardCard(
                    number: it.number,
                    title: it.title,
                    index: i,
                    onTap: () => openIssue(widget.scope, it),
                    onLabels: () => openLabels(widget.scope, GhKind.issue, it.number, it.title, it.url, it.labels),
                    meta: [
                      ...it.labels.take(4).map(LabelChip.new),
                      ?_queueChip(it.number),
                      _metaText(it.assignees.isNotEmpty ? '👤 ${it.assignees.join(', ')}' : 'by ${it.author}'),
                      if (it.comments > 0) _metaText('💬 ${it.comments}'),
                      _metaText(timeAgo(it.updatedAt)),
                    ],
                  ),
          ),
      ];

  List<Widget> _pullColumns() => [
        for (final col in pullColumns(store.pulls.items))
          _column<GhPull>(
            col,
            boardLabels(store.pulls.items),
            (it, i) {
                  final w = workerForPull(store.workers.values, it);
                  return BoardCard(
                    number: it.number,
                    title: it.title,
                    index: i,
                    onTap: () => openPull(widget.scope, it),
                    onLabels: () => openLabels(widget.scope, GhKind.pull, it.number, it.title, it.url, it.labels),
                    meta: [
                      if (w != null) DeskChip(w),
                      ...it.labels.take(4).map(LabelChip.new),
                      _metaText('by ${it.author}'),
                      if (it.reviewDecision == 'CHANGES_REQUESTED') _metaText('🛠 changes requested'),
                      if (checkIcon[it.checks]!.isNotEmpty) _metaText(checkIcon[it.checks]!),
                      _metaText('+${it.additions}', color: const Color(0xFF2A9D4B)),
                      _metaText('-${it.deletions}', color: const Color(0xFFC3423F)),
                      _metaText(timeAgo(it.updatedAt)),
                    ],
                  );
            },
          ),
      ];

  /// Where an issue stands on the 📋 queue, for its card.
  Widget? _queueChip(int issue) {
    final t = store.taskForIssue(issue);
    if (t == null) return null;
    final provider = ' · ${providerName(t.provider, store.project)}';
    if (t.status == TaskStatus.queued) {
      final first = store.queue.tasks.where((x) => x.status == TaskStatus.queued).firstOrNull;
      return _QChip('${identical(first, t) ? '📋 up next' : '📋 queued'}$provider', const Color(0xFFE0F2FE));
    }
    if (t.status == TaskStatus.running) {
      final w = t.workerId == null ? null : store.workers[t.workerId];
      if (w != null) return DeskChip(w, tooltip: '${w.name} is working on this at ${deskById[w.deskId]?.label ?? 'a desk'}$provider');
      return _QChip('🤖 ${t.workerName ?? 'a worker'}$provider', const Color(0xFFD8F5E3));
    }
    return t.pr != null ? _QChip('🔀 PR #${t.pr!.number}$provider', Swatch.paper2) : null;
  }
}

Widget _metaText(String s, {Color color = Swatch.muted}) => Text(s, style: heavy(11, color: color, weight: FontWeight.w700));

class _QChip extends StatelessWidget {
  const _QChip(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 1.5)),
        child: Text(text, style: heavy(10, weight: FontWeight.w900)),
      );
}

/// A chip naming the worker and desk a pull request came from.
class DeskChip extends StatelessWidget {
  const DeskChip(this.w, {super.key, this.tooltip});
  final WorkerInfo w;

  /// What hovering it says; by default, that the pull request was opened from this desk.
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? "Opened from ${w.name}'s desk (${w.worktree?.branch ?? 'its branch'})",
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: parseHex(w.color, Swatch.accent), shape: BoxShape.circle, border: Border.all(color: Swatch.ink, width: 1)),
              ),
              const SizedBox(width: 5),
              Text('🪑 ${w.name} · ${deskById[w.deskId]?.label ?? 'a desk'}', style: heavy(11)),
            ],
          ),
        ),
      );
}

class _ColumnView extends StatelessWidget {
  const _ColumnView({
    required this.title,
    required this.count,
    required this.cards,
    required this.picked,
    required this.open,
    required this.empty,
    required this.colors,
    required this.choices,
    required this.onHead,
    required this.onPick,
  });
  final String title;
  final String count;
  final List<Widget> cards;

  /// The labels the column is filtered to.
  final List<String> picked;

  /// Whether its label picker is open.
  final bool open;
  final String empty;

  /// Every label on the board, by name, with its colour.
  final Map<String, String> colors;

  /// The picker's labels and how many of the column's cards carry each (while [open]).
  final List<({String name, int count})> choices;
  final VoidCallback onHead;
  final ValueChanged<List<String>> onPick;

  GhLabel _label(String name) => GhLabel(name: name, color: colors[name] ?? '#dddddd');

  @override
  Widget build(BuildContext context) {
    final filtered = picked.isNotEmpty;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0x8CFFFAF3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink, width: 3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ColumnHead(
            title: title,
            count: count,
            open: open,
            filtered: filtered,
            tooltip: filtered ? 'Only cards labelled ${picked.join(' or ')}. Click to change.' : 'Filter by label',
            onTap: onHead,
          ),
          if (open)
            _picker()
          else if (filtered)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: const BoxDecoration(color: Swatch.paper, border: Border(bottom: BorderSide(color: Swatch.ink, width: 3))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Wrap(spacing: 4, runSpacing: 4, children: [for (final n in picked) LabelChip(_label(n))])),
                  Tooltip(
                    message: 'Show every card',
                    child: Semantics(
                      button: true,
                      label: 'Clear label filter',
                      child: InkWell(
                        onTap: () => onPick(const []),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Text('✕', style: heavy(12, color: Swatch.muted, weight: FontWeight.w900))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: cards.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(empty, textAlign: TextAlign.center, style: heavy(13, color: Swatch.muted, weight: FontWeight.w700)),
                  )
                : ListView.separated(
                    // Room above the first card for its pin.
                    padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
                    itemCount: cards.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (_, i) => cards[i],
                  ),
          ),
        ],
      ),
    );
  }

  /// Toggles for every label on the board; the column shows cards with any of the ones picked.
  Widget _picker() {
    final what = title.replaceFirst(RegExp(r'^\S+ '), '');
    return LayoutBuilder(
      builder: (context, _) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: const BoxDecoration(color: Swatch.paper, border: Border(bottom: BorderSide(color: Swatch.ink, width: 3))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: choices.isEmpty
                    ? Text('No labels on this board yet.', style: heavy(11, color: Swatch.muted, weight: FontWeight.w700))
                    : Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final c in choices)
                            _LabelPick(
                              label: _label(c.name),
                              count: c.count,
                              on: picked.contains(c.name),
                              tooltip: '${c.count} in $what',
                              onTap: () => onPick(picked.contains(c.name) ? picked.where((x) => x != c.name).toList() : [...picked, c.name]),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    picked.isNotEmpty ? 'Showing cards with any of these labels' : 'Pick labels to show only their cards',
                    style: heavy(11, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ),
                if (picked.isNotEmpty) OfficeButton(label: 'Clear', dense: true, onPressed: () => onPick(const [])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A column's header: its title and count, a button that opens its label filter.
class _ColumnHead extends StatefulWidget {
  const _ColumnHead({required this.title, required this.count, required this.open, required this.filtered, required this.tooltip, required this.onTap});
  final String title;
  final String count;
  final bool open;
  final bool filtered;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ColumnHead> createState() => _ColumnHeadState();
}

class _ColumnHeadState extends State<_ColumnHead> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = hover || widget.open;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        expanded: widget.open,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) => setState(() => hover = v),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: lit || widget.filtered ? Swatch.paper2 : Swatch.paper,
                border: const Border(bottom: BorderSide(color: Swatch.ink, width: 3)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: heavy(14, weight: FontWeight.w900))),
                  const SizedBox(width: 8),
                  Text(widget.count, style: heavy(14, weight: FontWeight.w900)),
                  const SizedBox(width: 5),
                  Text(widget.open ? '▴' : '▾', style: heavy(11, color: lit ? Swatch.ink : Swatch.muted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One label in a column's picker: its chip and how many of the column's cards carry it.
class _LabelPick extends StatefulWidget {
  const _LabelPick({required this.label, required this.count, required this.on, required this.tooltip, required this.onTap});
  final GhLabel label;
  final int count;
  final bool on;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_LabelPick> createState() => _LabelPickState();
}

class _LabelPickState extends State<_LabelPick> {
  bool hover = false;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: Semantics(
          button: true,
          toggled: widget.on,
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowHoverHighlight: (v) => setState(() => hover = v),
            actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
            child: GestureDetector(
              onTap: widget.onTap,
              child: Opacity(
                opacity: widget.on || hover ? 1 : 0.55,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
                  decoration: BoxDecoration(
                    color: widget.on ? Colors.white : null,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: widget.on ? Swatch.ink : Colors.transparent, width: 2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LabelChip(widget.label),
                      const SizedBox(width: 4),
                      Text('${widget.count}', style: heavy(11, color: widget.on ? Swatch.ink : Swatch.muted, weight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// A sticky note on the board: tilted a little, pinned at the top, straightening up on hover.
class BoardCard extends StatefulWidget {
  const BoardCard({super.key, required this.number, required this.title, required this.meta, required this.index, required this.onTap, this.onLabels});
  final int number;
  final String title;
  final List<Widget> meta;
  final int index;
  final VoidCallback onTap;

  /// Opens the label picker (the 🏷️ that shows on hover).
  final VoidCallback? onLabels;

  @override
  State<BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends State<BoardCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.number;
    final tilt = hover ? 0.0 : _tilts[n % _tilts.length] * math.pi / 180;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => hover = v),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 100),
          scale: hover ? 1.02 : 1,
          child: AnimatedRotation(
            duration: const Duration(milliseconds: 100),
            turns: tilt / (2 * math.pi),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                  decoration: BoxDecoration(
                    color: kNoteColors[n % kNoteColors.length],
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Swatch.ink, width: 2),
                    boxShadow: const [BoxShadow(color: Color(0x992B2D42), offset: Offset(0, 3))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('#$n', style: heavy(12, color: Swatch.muted, weight: FontWeight.w900)),
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 6),
                        child: Text(widget.title, style: heavy(14)),
                      ),
                      Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: widget.meta),
                    ],
                  ),
                ),
                if (widget.onLabels != null && hover)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Tooltip(
                      message: 'Change the labels',
                      child: Semantics(
                        button: true,
                        label: 'Change the labels on #$n',
                        child: GestureDetector(
                          onTap: widget.onLabels,
                          child: Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Swatch.paper,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Swatch.ink, width: 2),
                              boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 2))],
                            ),
                            child: const Text('🏷️', style: TextStyle(fontSize: 13)),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: -7,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: kPins[widget.index % 4], shape: BoxShape.circle, border: Border.all(color: Swatch.ink, width: 2)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardError extends StatelessWidget {
  const _BoardError(this.error);
  final String error;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(color: Swatch.paper, borderRadius: BorderRadius.circular(14), border: Border.all(color: Swatch.ink, width: 3)),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: "Couldn't load from GitHub: $error\n", style: heavy(15)),
              TextSpan(
                text: 'The server runs `gh` in the project directory — make sure it is installed and authenticated (gh auth login).',
                style: heavy(12),
              ),
            ]),
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// Cork: the tan board with a fine grid of darker dots.
class _CorkPainter extends CustomPainter {
  const _CorkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _cork);
    final pts = <Offset>[
      for (var y = 4.5; y < size.height; y += 9)
        for (var x = 4.5; x < size.width; x += 9) Offset(x, y),
    ];
    canvas.drawPoints(
      PointMode.points,
      pts,
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CorkPainter old) => false;
}
