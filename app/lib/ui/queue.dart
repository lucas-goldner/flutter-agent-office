// The 📋 task queue: what the next free worker does, what they're doing now and what they did.
// A port of ui/queue.ts.

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/portable.dart';
import '../office_scope.dart';
import '../shared/protocol.dart';
import '../state/store.dart';
import 'child_button.dart';
import 'modal.dart';
import 'prompt.dart';
import 'provider.dart';
import 'queue_logic.dart';
import 'theme.dart';

/// The 📋 Queue button in the top bar: shows how many tasks are waiting or running.
class QueueButton extends StatelessWidget {
  const QueueButton({super.key, required this.store, required this.onOpen});

  final Store store;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.topic(Topic.queue),
    builder: (context, _) {
      final n = store.queue.tasks.where((t) => t.status != TaskStatus.done).length;
      return ChildButton(
        onPressed: onOpen,
        fontSize: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📋 Queue'),
            if (n > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: Swatch.accent, borderRadius: BorderRadius.circular(999)),
                child: Text(
                  '$n',
                  style: heavy(12, color: Colors.white, weight: FontWeight.w900),
                ),
              ),
          ],
        ),
      );
    },
  );
}

ModalHandle openQueue(OfficeScope scope) => ModalStack.instance.show((m) => _QueueWindow(modal: m, scope: scope));

class _QueueWindow extends StatefulWidget {
  const _QueueWindow({required this.modal, required this.scope});

  final ModalHandle modal;
  final OfficeScope scope;

  @override
  State<_QueueWindow> createState() => _QueueWindowState();
}

class _QueueWindowState extends State<_QueueWindow> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  late final _provider = ProviderPickerController(widget.scope.store.project);
  late final Timer _tick;

  Store get store => widget.scope.store;
  void _send(ClientMsg m) => widget.scope.net.send(m);

  @override
  void initState() {
    super.initState();
    // Keeps the "started 5m ago"s fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    _text.dispose();
    _focus.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _add() {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    if (!_provider.valid()) return;
    _send(QueueAddCmd(prompt: text, provider: _provider.value(), model: _provider.model()));
    _text.clear();
  }

  @override
  Widget build(BuildContext context) => ModalWindow(
    modal: widget.modal,
    width: 800,
    title: const Text('📋 Task queue'),
    headerExtras: [ListenableBuilder(listenable: store.topic(Topic.queue), builder: (context, _) => _limit())],
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The form stays put and only the list below it re-renders, so worker updates don't pull focus out of the box.
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: (box.maxWidth - 8 - 210 - 8 - 130).clamp(180, box.maxWidth),
                child: PromptField(
                  controller: _text,
                  focusNode: _focus,
                  onSend: _add,
                  hint: 'Describe a task for the next free worker…',
                  minLines: 2,
                  maxLines: 6,
                  autofocus: true,
                ),
              ),
              SizedBox(
                width: 210,
                child: ProviderPicker(controller: _provider, label: 'Queue provider', compact: true),
              ),
              OfficeButton(label: 'Add to queue', kind: BtnKind.primary, onPressed: _add),
            ],
          ),
        ),
        ListenableBuilder(listenable: store.topics([Topic.queue, Topic.workers, Topic.issues]), builder: (context, _) => _list()),
      ],
    ),
    footer: const Row(children: [FooterNote('The queue keeps going while you are away. Set “workers at once” to 0 to pause it.')]),
  );

  Widget _limit() {
    final max = store.queue.maxWorkers;
    final muted = heavy(13, color: Swatch.muted);
    return Tooltip(
      message: 'How many workers the queue keeps busy at once. 0 pauses it.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Text('Workers at once', style: muted),
          ChildButton(
            tooltip: 'Fewer workers at once',
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
            fontSize: 15,
            onPressed: max <= 0 ? null : () => _send(QueueLimitCmd(max - 1)),
            child: const Text('−'),
          ),
          SizedBox(
            width: 58,
            child: Text(
              max == 0 ? 'Paused' : '$max',
              textAlign: TextAlign.center,
              style: heavy(15, weight: FontWeight.w900),
            ),
          ),
          ChildButton(
            tooltip: 'More workers at once',
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
            fontSize: 15,
            onPressed: () => _send(QueueLimitCmd(max + 1)),
            child: const Text('+'),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    final q = store.queue;
    final running = q.tasks.where((t) => t.status == TaskStatus.running).toList();
    final queued = q.tasks.where((t) => t.status == TaskStatus.queued).toList();
    final done = q.tasks.where((t) => t.status == TaskStatus.done).toList().reversed.toList();
    final note = heavy(13, color: Swatch.muted, weight: FontWeight.w600).copyWith(height: 1.45);
    final b = heavy(13, color: Swatch.muted, weight: FontWeight.w900);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text.rich(
            TextSpan(
              style: note,
              children: [
                const TextSpan(text: 'Or open the 📌 Issues board and click '),
                TextSpan(text: 'Add to queue', style: b),
                const TextSpan(text: ' on an issue. Whenever a desk is free and fewer than '),
                TextSpan(text: q.maxWorkers == 0 ? '0' : '${q.maxWorkers}', style: b),
                const TextSpan(
                  text:
                      ' workers are busy, the next task gets a fresh worker in its own git worktree. '
                      'Issues are assigned on GitHub when they start, and the pull request is linked when it shows up.',
                ),
              ],
            ),
          ),
        ),
        ?_section('🤖 Working on it', running, queued),
        ?_section('⏳ Up next', queued, queued),
        ?_section(
          '✅ Finished',
          done,
          queued,
          extra: OfficeButton(label: 'Clear', dense: true, onPressed: () => _send(const QueueClearCmd())),
        ),
        if (running.isEmpty && queued.isEmpty && done.isEmpty)
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Swatch.muted, width: kBorder), // dashed in the CSS
            ),
            child: Text('Nothing on the queue yet.', textAlign: TextAlign.center, style: heavy(14)),
          ),
      ],
    );
  }

  Widget? _section(String title, List<QueueTask> tasks, List<QueueTask> queued, {Widget? extra}) {
    if (tasks.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Row(
            spacing: 8,
            children: [
              Text(
                title.toUpperCase(),
                style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 14 * 0.04),
              ),
              Text(
                '${tasks.length}',
                style: heavy(14, color: Swatch.muted, weight: FontWeight.w900),
              ),
              if (extra != null) ...[const Spacer(), extra],
            ],
          ),
        ),
        for (final t in tasks) Padding(padding: const EdgeInsets.only(bottom: 8), child: _row(t, queued)),
      ],
    );
  }

  Widget _row(QueueTask t, List<QueueTask> queued) {
    final w = t.workerId != null ? store.workers[t.workerId] : null;
    final buttons = <Widget>[];
    String? pos;
    Widget btn(String label, VoidCallback? onPressed, {String? tip}) => OfficeButton(label: label, dense: true, tooltip: tip, onPressed: onPressed);
    switch (t.status) {
      case TaskStatus.running:
        if (w != null) {
          buttons.add(btn('🖥️ Terminal', () => widget.scope.actions.openWorkerTerminal(w.id)));
          buttons.add(
            btn(
              '⏹ Stop',
              () => confirmDialog(
                'Stop ${w.name}?',
                'This sends ${w.name} home and stops the task. You can requeue it afterwards.',
                'Stop',
                () => _send(WorkerKillCmd(w.id)),
              ),
              tip: 'Send the worker home; the task counts as stopped',
            ),
          );
        }
      case TaskStatus.queued:
        final i = queued.indexOf(t);
        pos = '${i + 1}';
        buttons.add(btn('↑', i == 0 ? null : () => _send(QueueMoveCmd(t.id, -1)), tip: 'Move up'));
        buttons.add(btn('↓', i == queued.length - 1 ? null : () => _send(QueueMoveCmd(t.id, 1)), tip: 'Move down'));
        buttons.add(btn('✕', () => _send(QueueRemoveCmd(t.id)), tip: 'Remove from the queue'));
      case TaskStatus.done:
        if (t.pr case final pr?) buttons.add(btn(taskPrLabel(pr), () => openInNewTab(pr.url), tip: pr.title));
        if (w != null) buttons.add(btn('🖥️ Terminal', () => widget.scope.actions.openWorkerTerminal(w.id)));
        buttons.add(btn('↻ Requeue', () => _send(QueueRetryCmd(t.id)), tip: 'Put it back on the queue'));
        buttons.add(btn('✕', () => _send(QueueRemoveCmd(t.id)), tip: 'Forget it'));
    }
    final issue = t.issue == null ? null : store.issues.items.where((i) => i.number == t.issue).firstOrNull;
    final title = Text(
      taskTitleText(t),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: heavy(14, weight: FontWeight.w900),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: switch (t.status) {
          TaskStatus.running => const Color(0xFFE7F8EE),
          TaskStatus.done => Swatch.paper2,
          TaskStatus.queued => Colors.white,
        },
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink, width: kBorder),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
      ),
      child: Row(
        spacing: 10,
        children: [
          if (pos != null)
            SizedBox(
              width: 24,
              child: Text(
                pos,
                textAlign: TextAlign.center,
                style: heavy(14, color: Swatch.muted, weight: FontWeight.w900),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: t.prompt,
                  waitDuration: const Duration(milliseconds: 600),
                  child: issue == null
                      ? title
                      : MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(onTap: () => openInNewTab(issue.url), child: title),
                        ),
                ),
                Text(
                  taskMeta(t, w: w, project: store.project),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: buttons),
        ],
      ),
    );
  }
}
