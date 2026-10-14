// The 2D view at /lite (lite.html and lite.ts): a page that scrolls, made for a phone, rather than a HUD
// over the 3D office. The floor switcher on top, every worker on the floor as a card (the ones waiting on
// someone first), and the boards, the queue and ✨ New task along the bottom. LiteController does the
// work; nothing of the 3D office (no flutter_scene Scene) is built here.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:office_shared/protocol.dart';

import '../interop/browser.dart';
import '../lite/lite_controller.dart';
import '../lite/lite_logic.dart';
import '../nextup.dart';
import '../notify.dart' show NotifyPermission, waitingOnSomeone;
import '../office_scope.dart';
import '../state/store.dart';
import '../ui/boards.dart';
import '../ui/modal.dart';
import '../ui/theme.dart';
import '../ui/worker_text.dart' show StatusPill, hexColor, statusLabel;

/// The bars line up with the list on a wide window.
const double kLiteWidth = 760;

class LitePage extends StatefulWidget {
  const LitePage({super.key, this.controller});

  /// For tests: a controller that's been set up already (its init is left to the test).
  final LiteController? controller;

  @override
  State<LitePage> createState() => _LitePageState();
}

class _LitePageState extends State<LitePage> {
  late final LiteController c = widget.controller ?? LiteController();
  Timer? _tick;
  bool _bell = false;

  @override
  void initState() {
    super.initState();
    // The big windows take the whole screen on a phone; the small ones stay dialogs.
    ModalStack.instance.phoneSheets = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ModalStack.instance.attach(Overlay.of(context));
    });
    if (widget.controller == null) c.init();
    // The browser only asks from a tap, so there's a button for it while it hasn't been asked.
    _bell = c.settings.notify && c.notifier.permission == NotifyPermission.ask;
    // "3m ago" moves on by itself.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    c.needsName.addListener(_askName);
  }

  @override
  void dispose() {
    c.needsName.removeListener(_askName);
    _tick?.cancel();
    ModalStack.instance
      ..closeAll()
      ..phoneSheets = false;
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  /// Your name, the first time this browser comes in on the shared password.
  void _askName() {
    if (!c.needsName.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ModalStack.instance.show((m) => _NameWindow(modal: m, done: c.named), escCloses: false, backdropCloses: false);
    });
  }

  @override
  Widget build(BuildContext context) => OfficeScope(
    store: c.store,
    net: c.net,
    settings: c.settings,
    actions: c,
    child: Material(
      color: Swatch.paper,
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                _TopBar(c: c, bell: _bell, onBell: _askNotify),
                Expanded(child: _Workers(c: c)),
                _BottomNav(c: c),
              ],
            ),
          ),
          // What floats over the page stays put on the screen.
          const Positioned(top: 84, left: 12, right: 12, child: Center(child: ToastLayer())),
          Positioned(
            top: 84,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: c.connected,
              builder: (context, up, _) =>
                  up ? const SizedBox.shrink() : Center(child: Pill('Reconnecting…', color: Swatch.warn)),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _askNotify() async {
    await c.notifier.askPermission();
    if (mounted) setState(() => _bell = false);
  }
}

/// Lays [child] out in the list's width on a wide window.
Widget _column(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: kLiteWidth),
    child: child,
  ),
);

// ---- The floor you're on ------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.c, required this.bell, required this.onBell});
  final LiteController c;
  final bool bell;
  final VoidCallback onBell;

  @override
  Widget build(BuildContext context) {
    final store = c.store;
    return Container(
      decoration: const BoxDecoration(
        color: Swatch.paper2,
        border: Border(
          bottom: BorderSide(color: Swatch.ink, width: kBorder),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: _column(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: store.topics(const [Topic.floors, Topic.floor]),
                    builder: (context, _) => _FloorPicker(c: c),
                  ),
                ),
                if (bell) ...[
                  OfficeButton(
                    key: const ValueKey('lite-bell'),
                    label: '🔔',
                    tooltip: 'Get a notification when a worker needs input or is done',
                    onPressed: onBell,
                  ),
                  const SizedBox(width: 8),
                ],
                OfficeButton(
                  key: const ValueKey('lite-3d'),
                  label: '🏢 3D',
                  tooltip: 'The 3D office, where you walk around',
                  onPressed: () => goTo('/?3d=1'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FloorPicker extends StatelessWidget {
  const _FloorPicker({required this.c});
  final LiteController c;

  @override
  Widget build(BuildContext context) {
    final store = c.store;
    final floors = store.floors;
    final here = floors.any((f) => f.id == store.floor) ? store.floor : null;
    final style = heavy(19, weight: FontWeight.w900);
    return Tooltip(
      message: "The floor you're on: pick another to see its workers",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'FLOOR',
            style: heavy(11, color: Swatch.muted, weight: FontWeight.w900).copyWith(letterSpacing: 0.6),
          ),
          if (floors.isEmpty)
            Text('No floors yet', style: style)
          else
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('lite-floor'),
                value: here,
                isExpanded: true,
                isDense: true,
                style: style,
                iconEnabledColor: Swatch.ink,
                hint: Text('Pick a floor', style: style),
                // One floor: nowhere else to go.
                onChanged: floors.length < 2 ? null : (id) => id == null ? null : c.ride(id),
                items: [
                  for (final f in floors)
                    DropdownMenuItem(
                      value: f.id,
                      enabled: f.cloning != true,
                      child: Text(liteFloorLabel(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Workers ------------------------------------------------------------------------------------

class _Workers extends StatelessWidget {
  const _Workers({required this.c});
  final LiteController c;

  @override
  Widget build(BuildContext context) {
    final store = c.store;
    return ListenableBuilder(
      listenable: store.topics(const [Topic.workers, Topic.project, Topic.floors, Topic.floor]),
      builder: (context, _) {
        final list = byUrgency(store.workers.values);
        final meta = liteFloorMeta(
          project: store.project,
          floor: store.currentFloor(),
          anyFloors: store.floors.isNotEmpty,
        );
        final elsewhere = waitingElsewhere(store.floors, store.floor);
        final waiting = waitingLabel(waitingInOrder(list));
        return ListView(
          key: const ValueKey('lite-list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _column(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                      ),
                    ),
                  // Someone waiting on another floor: a way straight there.
                  for (final o in elsewhere)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _GoThere(text: '🙋 ${o.waiting} waiting on ${o.name}', onTap: () => c.ride(o.id)),
                    ),
                  if (elsewhere.isNotEmpty) const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 10),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.end,
                      children: [
                        Text('WORKERS', style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.7)),
                        if (waiting.isNotEmpty)
                          Text(
                            waiting,
                            key: const ValueKey('lite-waiting'),
                            style: heavy(13, color: const Color(0xFFC9184A), weight: FontWeight.w900),
                          ),
                      ],
                    ),
                  ),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
                      child: Text(
                        store.project != null
                            ? 'Nobody is working on this floor. ✨ New task hires someone.'
                            : 'No workers here.',
                        textAlign: TextAlign.center,
                        style: heavy(14, color: Swatch.muted),
                      ),
                    ),
                  for (final w in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _WorkerCard(w: w, c: c),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GoThere extends StatelessWidget {
  const _GoThere({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFFFD6E0),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Swatch.ink, width: kBorder),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text(text, style: heavy(14))),
              Text('→', style: heavy(16)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A worker's card: its colour, name, task, what it's doing and the rest in a line; tapping it opens its
/// terminal (waking it up). ✍️ sends it a prompt.
class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.w, required this.c});
  final WorkerInfo w;
  final LiteController c;

  @override
  Widget build(BuildContext context) {
    final waiting = waitingOnSomeone(w);
    final task = liteTask(w);
    final now = liteNow(w);
    final sub = liteSub(w, c.store.project);
    final grey = w.status == WorkerStatus.exited || w.status == WorkerStatus.offline;
    final since = w.waitingSince;
    return Semantics(
      label: '${w.name}, ${statusLabel(w.status)}: open its terminal',
      button: true,
      child: Container(
        key: ValueKey('lite-worker-${w.id}'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: grey ? const Color(0xFFF3F1EE) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Swatch.ink, width: kBorder),
          boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Waiting on someone: a bar down its side, red for a question and green for done.
              if (waiting) Container(width: 6, color: w.status == WorkerStatus.done ? Swatch.good : Swatch.bad),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => c.openWorker(w.id),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(waiting ? 8 : 14, 12, 10, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(padding: const EdgeInsets.only(top: 4), child: Dot(hexColor(w.color), size: 14)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(w.name, style: heavy(16, weight: FontWeight.w900)),
                                if (task != null) ...[const SizedBox(height: 3), Text(task, style: heavy(14))],
                                if (now != null && now.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    now,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: heavy(
                                      13,
                                      weight: FontWeight.w700,
                                      color: w.status == WorkerStatus.needsInput ? const Color(0xFFC9184A) : Swatch.ink,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 3),
                                Text(
                                  sub,
                                  style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              StatusPill(w.status),
                              if (waiting && since != null) ...[
                                const SizedBox(height: 4),
                                Text(timeAgo(since), style: heavy(11, color: Swatch.muted)),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (liteCanPrompt(w))
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: OfficeButton(
                        key: ValueKey('lite-say-${w.id}'),
                        label: '✍️',
                        tooltip: 'Send ${w.name} a prompt',
                        onPressed: () => c.promptWorker(w.id),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- The boards, the queue and new work ----------------------------------------------------------

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.c});
  final LiteController c;

  @override
  Widget build(BuildContext context) {
    final store = c.store;
    return Container(
      decoration: const BoxDecoration(
        color: Swatch.paper2,
        border: Border(
          top: BorderSide(color: Swatch.ink, width: kBorder),
        ),
      ),
      child: SafeArea(
        top: false,
        child: _column(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: ListenableBuilder(
              listenable: store.topics(const [Topic.issues, Topic.pulls, Topic.queue]),
              builder: (context, _) {
                final issues = store.issues.items.where((i) => i.state == 'OPEN').length;
                final pulls = store.pulls.items.where((p) => p.state == 'OPEN').length;
                final queue = store.queue.tasks.where((t) => t.status != TaskStatus.done).length;
                return Row(
                  children: [
                    _NavButton(
                      id: 'issues',
                      label: '📌 Issues',
                      n: issues,
                      onTap: () => openBoard(c.scope, BoardKind.issues),
                    ),
                    _NavButton(
                      id: 'pulls',
                      label: '🔀 PRs',
                      n: pulls,
                      onTap: () => openBoard(c.scope, BoardKind.pulls),
                    ),
                    _NavButton(id: 'queue', label: '📋 Queue', n: queue, onTap: c.showQueue),
                    _NavButton(
                      id: 'new',
                      label: '✨ New task',
                      primary: true,
                      onTap: () => c.sendToWorker('✨ New task'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.id, required this.label, required this.onTap, this.n = 0, this.primary = false});
  final String id;
  final String label;
  final int n;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: primary ? Swatch.accent : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Swatch.ink, width: kBorder),
        ),
        child: InkWell(
          key: ValueKey('lite-nav-$id'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    Text(label, textAlign: TextAlign.center, style: heavy(14).copyWith(height: 1.15)),
                    if (n > 0)
                      Container(
                        constraints: const BoxConstraints(minWidth: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: primary ? Colors.white : Swatch.ink,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$n',
                          textAlign: TextAlign.center,
                          style: heavy(12, color: primary ? Swatch.ink : Colors.white).copyWith(height: 20 / 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// ---- In ----------------------------------------------------------------------------------------

/// 👋 Who is it? Your name, which your teammates see on what you type and send.
class _NameWindow extends StatefulWidget {
  const _NameWindow({required this.modal, required this.done});
  final ModalHandle modal;
  final void Function(String name) done;

  @override
  State<_NameWindow> createState() => _NameWindowState();
}

class _NameWindowState extends State<_NameWindow> {
  final _name = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return _focus.requestFocus();
    widget.modal.close();
    widget.done(name);
  }

  @override
  Widget build(BuildContext context) => ModalWindow(
    modal: widget.modal,
    width: 420,
    closable: false,
    title: const Text('👋 Who is it?'),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Your teammates see this name on what you type and send.', style: heavy(14, weight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('lite-name'),
          controller: _name,
          focusNode: _focus,
          autofocus: true,
          maxLength: 24,
          autofillHints: const [AutofillHints.nickname],
          style: heavy(16, weight: FontWeight.w500),
          decoration: const InputDecoration(hintText: 'Your name', counterText: ''),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    footer: Align(
      alignment: Alignment.centerRight,
      child: OfficeButton(
        key: const ValueKey('lite-in'),
        label: 'Come on in',
        kind: BtnKind.primary,
        onPressed: _submit,
      ),
    ),
  );
}
