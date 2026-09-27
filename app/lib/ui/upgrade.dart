// The ⬆️ panel: what's running, what's new upstream, and the button to upgrade. Then, while the
// office restarts, a window nobody can dismiss, and a reload onto the new version (ui/upgrade.ts).

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../office_scope.dart';
import '../shared/protocol.dart';
import '../shared/status.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

ModalHandle openUpgrade(OfficeScope scope) {
  final handle = ModalStack.instance.show((modal) => _UpgradeWindow(scope: scope, modal: modal));
  scope.net.send(const UpgradeCheckCmd());
  return handle;
}

/// "abc1234 Fix the thing · 3d ago"
class _Version extends StatelessWidget {
  const _Version(this.v);
  final VersionInfo v;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        _code(v.sha),
        TextSpan(text: ' ${v.subject}'),
        TextSpan(
          text: ' · ${timeAgo(v.date)}',
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
        ),
      ],
    ),
    style: heavy(16, weight: FontWeight.w700),
  );
}

InlineSpan _code(String text) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(color: Swatch.paper2, borderRadius: BorderRadius.circular(5)),
    child: Text(
      text,
      style: const TextStyle(fontFamily: kMono, fontSize: 12, color: Swatch.ink),
    ),
  ),
);

class _UpgradeWindow extends StatefulWidget {
  const _UpgradeWindow({required this.scope, required this.modal});
  final OfficeScope scope;
  final ModalHandle modal;

  @override
  State<_UpgradeWindow> createState() => _UpgradeWindowState();
}

class _UpgradeWindowState extends State<_UpgradeWindow> {
  Store get store => widget.scope.store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.topics(const [Topic.upgrade, Topic.workers]),
    builder: (context, _) {
      final u = store.upgrade;
      final busy = u.phase == UpgradePhase.building || u.phase == UpgradePhase.restarting;
      final net = widget.scope.net;
      return ModalWindow(
        modal: widget.modal,
        width: 620,
        title: const Text('⬆️ Upgrade the office'),
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _body(u, busy)),
        footer: Row(
          children: [
            const Spacer(),
            OfficeButton(
              label: '🔄 Check again',
              onPressed: u.checking == true || busy ? null : () => net.send(const UpgradeCheckCmd()),
            ),
            const SizedBox(width: 8),
            OfficeButton(
              label: '⬆️ Upgrade now',
              kind: BtnKind.primary,
              onPressed: u.latest == null || u.checking == true || busy
                  ? null
                  : () => net.send(const UpgradeStartCmd()),
            ),
          ],
        ),
      );
    },
  );

  List<Widget> _body(UpgradeState u, bool busy) {
    final out = <Widget>[];
    if (u.current != null) out.addAll([const FieldLabel('Running now'), _Version(u.current!)]);
    if (u.phase == UpgradePhase.building) {
      out.add(
        StatusBox(
          'Building ${u.latest?.sha ?? 'the new version'}${u.by != null ? ' (started by ${u.by})' : ''}. The office keeps working until it restarts, usually in a minute or two.',
          spinner: true,
          top: 12,
        ),
      );
    } else if (u.phase == UpgradePhase.failed && u.error != null) {
      out.add(
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD6E0),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Swatch.ink, width: 2),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              u.error!,
              style: const TextStyle(fontFamily: kMono, fontSize: 12, height: 1.45, color: Swatch.ink),
            ),
          ),
        ),
      );
    }
    if (u.checking == true) {
      out.add(const StatusBox('Checking GitHub for changes…', spinner: true, top: 12));
    } else if (u.error != null && u.phase != UpgradePhase.failed) {
      out.add(StatusBox(u.error!, kind: StatusKind.error, top: 12));
    } else if (u.latest == null && u.checkedAt != null) {
      out.add(StatusBox('✅ Up to date (checked ${timeAgo(u.checkedAt!)})', kind: StatusKind.ok, top: 12));
    }
    if (u.latest != null) {
      final changes = u.changes ?? const <UpgradeChange>[];
      final n = u.behind ?? changes.length;
      out.add(FieldLabel('New: ${n >= 50 ? '50+' : n} change${n == 1 ? '' : 's'}', top: 14));
      for (final c in changes) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '• '),
                  _code(c.sha),
                  TextSpan(text: ' ${c.subject}'),
                ],
              ),
              style: heavy(14, weight: FontWeight.w600),
            ),
          ),
        );
      }
      if (n > changes.length) out.add(Note('…and ${n >= 50 ? 'more' : '${n - changes.length} more'}', top: 12));
      if (!busy) {
        final awake = store.workers.values.where((w) => !isAsleep(w.status)).toList();
        final working = awake
            .where((w) => w.status == WorkerStatus.working || w.status == WorkerStatus.needsInput)
            .toList();
        final names = working.map((w) => w.name).join(', ');
        out.add(
          Note(
            'Upgrading builds the new version while the office keeps running, then restarts it. Everyone reconnects on the new version automatically. '
            '${awake.isNotEmpty ? 'Workers who are awake wake back up by themselves afterwards${working.isNotEmpty ? ', but $names ${working.length == 1 ? 'is' : 'are'} in the middle of something that will be interrupted' : ''}.' : ''}',
            top: 12,
          ),
        );
      }
    }
    return out;
  }
}

// --- Restart: a modal nobody can dismiss, then a reload onto the new version ---------------------

class _Restart {
  _Restart(this.modal, this.content);
  final ModalHandle modal;
  final ValueNotifier<(String, List<Widget>)> content;
}

_Restart? _restart;
Timer? _slowTimer;

bool restarting() => _restart != null;

void _restartDialog(String title, List<Widget> content) {
  if (_restart == null) {
    ModalStack.instance.closeAll();
    final notifier = ValueNotifier((title, content));
    final modal = ModalStack.instance.show(
      (modal) => ValueListenableBuilder(
        valueListenable: notifier,
        builder: (context, c, _) => ModalWindow(
          modal: modal,
          width: 480,
          closable: false,
          title: Text(c.$1),
          body: DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: c.$2),
          ),
        ),
      ),
      escCloses: false,
      backdropCloses: false,
    );
    _restart = _Restart(modal, notifier);
  } else {
    _restart!.content.value = (title, content);
  }
}

Widget _art(String emoji) => _Bob(child: Text(emoji, style: const TextStyle(fontSize: 64, height: 1)));

Widget _p(List<InlineSpan> spans) => Padding(
  padding: const EdgeInsets.only(top: 10),
  child: Text.rich(
    TextSpan(children: spans),
    textAlign: TextAlign.center,
    style: heavy(16, weight: FontWeight.w700),
  ),
);

/// The server said it's about to restart into a new version.
void showRestarting(UpgradeState u, OfficeScope scope) {
  scope.net.expectRestart();
  final latest = u.latest;
  final content = [
    _art('🏗️'),
    _p([
      TextSpan(
        text:
            '${u.by != null ? '${u.by} is upgrading' : 'Upgrading'} the office${latest != null ? ' to ${latest.sha}: “${latest.subject}”' : ''}.',
      ),
    ]),
    const StatusBox(
      'Restarting… you’ll be back in a few seconds. No need to do anything.',
      spinner: true,
      center: true,
    ),
  ];
  _restartDialog('🛠️ Upgrading the office', content);
  _slowTimer?.cancel();
  _slowTimer = Timer(const Duration(minutes: 3), () {
    final r = _restart;
    if (r == null) return;
    r.content.value = (
      r.content.value.$1,
      [
        ...r.content.value.$2,
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('This is taking longer than usual. ', style: heavy(13, color: Swatch.muted)),
              const OfficeButton(label: 'Try reloading', onPressed: reloadPage),
            ],
          ),
        ),
      ],
    );
  });
}

/// Reconnected to a different version than this page was loaded from: load the new client.
void showUpgraded(UpgradeState u) {
  _slowTimer?.cancel();
  final v = u.current;
  _restartDialog('✨ The office has been upgraded', [
    _art('🎉'),
    v != null
        ? _p([const TextSpan(text: 'Now running '), _code(v.sha), TextSpan(text: ': “${v.subject}”')])
        : _p(const [TextSpan(text: 'A new version is running.')]),
    const StatusBox('Loading the new version…', kind: StatusKind.ok, spinner: true, center: true),
  ]);
  Timer(const Duration(milliseconds: 2500), reloadPage);
}

/// .restart-art: bobs up and down.
class _Bob extends StatefulWidget {
  const _Bob({required this.child});
  final Widget child;

  @override
  State<_Bob> createState() => _BobState();
}

class _BobState extends State<_Bob> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) =>
        Transform.translate(offset: Offset(0, -6 * Curves.easeInOut.transform(_c.value)), child: child),
    child: widget.child,
  );
}
