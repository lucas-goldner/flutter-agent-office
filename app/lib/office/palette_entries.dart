// What the command palette (Ctrl+K, ⌘K on a Mac) finds in the office (features/palette): the workers,
// the office's actions, its boards, the pull requests, issues and services, and the people in it. Enter
// does it; Shift+Enter walks you over to where it's done first, through the office's own walk-to (which
// knows the way round this floor; other maps and the back office route through it too).

import 'dart:math' as math;

import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';

import '../interop/open_link.dart';
import '../state/store.dart';
import '../ui/services.dart' show serviceLink;
import '../ui/modal.dart' show toast, ToastKind;
import '../ui/palette.dart';
import '../ui/worker_text.dart' show statusLabel;
import '../world/collider.dart' show InteractKind, Interactable;

/// A spot to walk to: where to stand, and what to turn to there.
typedef PaletteSpot = ({double x, double z});

/// What the palette needs from the office.
class PaletteHost {
  const PaletteHost({
    required this.store,
    required this.you,
    required this.interactables,
    required this.walkThen,
    required this.openTerminal,
    required this.hireAt,
    required this.showQueue,
    required this.showSettings,
    required this.showSearch,
    required this.invite,
    required this.startHanging,
    required this.openBoard,
    required this.openIssue,
    required this.openPull,
    required this.walkTo,
  });

  final Store store;

  /// Where you are on the floor.
  final PaletteSpot Function() you;
  final List<Interactable> Function() interactables;

  /// Walks you over to a spot and does [then] there ([face]: what to turn to); [what] names it for the toast.
  final void Function(PaletteSpot at, String what, void Function() then, {PaletteSpot? face}) walkThen;
  final void Function(String workerId) openTerminal;
  final void Function(String deskId) hireAt;
  final void Function() showQueue;
  final void Function() showSettings;
  final void Function() showSearch;

  /// Invite teammates (or the admins' accounts window), when the office has either.
  final void Function()? invite;
  final void Function() startHanging;

  /// E at the board of that kind (issues, pulls, services, whiteboard, meeting).
  final void Function(InteractKind kind) openBoard;
  final void Function(GhIssue issue) openIssue;
  final void Function(GhPull pull) openPull;

  /// Over to a teammate, by elevator if need be.
  final void Function(String peerId) walkTo;
}

/// The board agents' icons by station.
const Map<String, String> _stationIcon = {'issues': '📌', 'pulls': '🔀', 'queue': '📋'};

/// Everything the palette finds, in the order it lists them before you type.
List<PaletteRow> paletteEntries(PaletteHost h) {
  final store = h.store;

  /// Where you stand to use something of this kind on this floor, like the Issues board.
  Interactable? spotOf(InteractKind kind) => h.interactables().where((it) => it.kind == kind && !it.off).firstOrNull;

  /// Where you stand at a desk: behind the worker, looking over their shoulder (as standAt).
  PaletteSpot deskSpot(DeskDef desk) {
    final s = deskSeat(desk, desk.station != null ? -1.6 : (desk.beanbag ? 1.6 : 2.4));
    return (x: s.x, z: s.z);
  }

  /// An entry that walks you over to [kind]'s spot (Shift+Enter) before doing what Enter does.
  PaletteRow at(
    InteractKind kind,
    String what, {
    required String icon,
    required String kind_,
    required String title,
    String? detail,
    List<String?> keywords = const [],
    required void Function() open,
  }) {
    final it = spotOf(kind);
    return PaletteRow(
      icon: icon,
      kind: kind_,
      title: title,
      detail: detail,
      keywords: keywords,
      open: open,
      walk: it == null ? null : () => h.walkThen((x: it.x, z: it.z), what, open),
    );
  }

  final out = <PaletteRow>[];
  for (final w in store.workers.values) {
    final desk = deskById[w.deskId];
    void open() => h.openTerminal(w.id);
    out.add(
      PaletteRow(
        icon: desk?.station != null
            ? (_stationIcon[desk!.station!.name] ?? '🤖')
            : (w.kind == WorkerKind.shell ? '🐚' : '🧑‍💻'),
        kind: 'Worker',
        title: w.name,
        detail: [?w.task?.name, ?desk?.label, statusLabel(w.status)].join(' · '),
        keywords: [w.title, w.worktree?.branch],
        open: open,
        walk: desk == null
            ? null
            : () => h.walkThen(deskSpot(desk), '${w.name} at ${desk.label}', open, face: (x: desk.x, z: desk.z)),
      ),
    );
  }

  // The free desk nearest you, for hiring from the palette.
  final me = h.you();
  DeskDef? free;
  var bestD = double.infinity;
  for (final d in desks) {
    if (store.workerAtDesk(d.id) != null) continue;
    final dist = math.sqrt(math.pow(d.x - me.x, 2) + math.pow(d.z - me.z, 2));
    if (dist < bestD) {
      free = d;
      bestD = dist;
    }
  }
  out.add(
    PaletteRow(
      icon: '✨',
      kind: 'Action',
      title: 'Hire a worker',
      detail: free != null ? 'At ${free.label}, the free desk nearest you' : 'Every desk is taken',
      keywords: const ['new worker', 'spawn an agent'],
      open: free != null ? () => h.hireAt(free!.id) : () => toast('Every desk on this floor is taken', ToastKind.warn),
      walk: free == null
          ? null
          : () => h.walkThen(deskSpot(free!), free.label, () => h.hireAt(free!.id), face: (x: free.x, z: free.z)),
    ),
  );
  out.add(
    at(
      InteractKind.queue,
      'the task queue',
      icon: '📋',
      kind_: 'Action',
      title: 'Open the task queue',
      detail: 'Issues and tasks waiting for a worker',
      keywords: const ['backlog', 'tasks'],
      open: h.showQueue,
    ),
  );
  out.add(
    PaletteRow(
      icon: '⚙️',
      kind: 'Action',
      title: 'Settings',
      keywords: const ['preferences', 'options'],
      open: h.showSettings,
    ),
  );
  if (h.invite != null) {
    out.add(
      PaletteRow(
        icon: '👥',
        kind: 'Action',
        title: store.invites ? 'Invite teammates' : 'Invite people',
        detail: store.invites ? null : 'Accounts',
        keywords: const ['team', 'add people', 'accounts'],
        open: h.invite!,
      ),
    );
  }
  out.add(
    PaletteRow(
      icon: '🖼️',
      kind: 'Action',
      title: 'Hang a picture',
      detail: 'On a wall of this floor',
      keywords: const ['decorate', 'frame', 'art'],
      open: h.startHanging,
    ),
  );
  out.add(
    PaletteRow(
      icon: '🔎',
      kind: 'Action',
      title: 'Search the chat and every terminal',
      keywords: const ['find'],
      open: h.showSearch,
    ),
  );

  void board(
    InteractKind kind,
    String what,
    String icon,
    String title, {
    String? detail,
    List<String?> keywords = const [],
  }) => out.add(
    at(
      kind,
      what,
      icon: icon,
      kind_: 'Board',
      title: title,
      detail: detail,
      keywords: keywords,
      open: () => h.openBoard(kind),
    ),
  );
  board(InteractKind.issues, 'the Issues board', '📌', 'Issues board');
  board(InteractKind.pulls, 'the PR board', '🔀', 'PR board', keywords: const ['pull requests']);
  board(
    InteractKind.services,
    'the Services board',
    '🌐',
    'Services board',
    detail: 'Web servers the workers are running',
  );
  board(InteractKind.whiteboard, 'the whiteboard', '📝', 'Whiteboard');
  board(InteractKind.meeting, 'the meeting room', '🤝', 'Meeting room', keywords: const ['call a meeting']);

  for (final pr in store.pulls.items) {
    out.add(
      at(
        InteractKind.pulls,
        'the PR board',
        icon: '🔀',
        kind_: 'PR',
        title: '#${pr.number} ${pr.title}',
        detail: [pr.isDraft ? 'Draft' : pr.state.toLowerCase(), pr.headRefName, pr.author].join(' · '),
        open: () => h.openPull(pr),
      ),
    );
  }
  for (final issue in store.issues.items) {
    out.add(
      at(
        InteractKind.issues,
        'the Issues board',
        icon: '📌',
        kind_: 'Issue',
        title: '#${issue.number} ${issue.title}',
        detail: [issue.state.toLowerCase(), ...issue.labels.map((l) => l.name), issue.author].join(' · '),
        open: () => h.openIssue(issue),
      ),
    );
  }
  final servicesBoard = spotOf(InteractKind.services);
  for (final svc in store.services.items) {
    final title = svc.title ?? '';
    out.add(
      PaletteRow(
        icon: '🌐',
        kind: 'Service',
        title: title.isNotEmpty ? title : svc.command,
        detail: [':${svc.port}', if (title.isNotEmpty) svc.command, ?store.workers[svc.workerId]?.name].join(' · '),
        keywords: ['${svc.port}'],
        // As its Open ↗ button does. Walking there shows the board instead.
        open: () => openInNewTab(serviceLink(store.services, svc.port)),
        walk: servicesBoard == null
            ? null
            : () => h.walkThen(
                (x: servicesBoard.x, z: servicesBoard.z),
                'the Services board',
                () => h.openBoard(InteractKind.services),
              ),
      ),
    );
  }
  for (final p in store.peers.values) {
    if (p.id == store.you) continue;
    final floor = store.onMyFloor(p)
        ? 'On this floor'
        : 'On the ${store.floors.where((f) => f.id == p.floor).firstOrNull?.name ?? 'other'} floor';
    // As clicking them under "In the office" does: over to them, by elevator if need be.
    out.add(PaletteRow(icon: '🙂', kind: 'Teammate', title: p.name, detail: floor, open: () => h.walkTo(p.id)));
  }
  return out;
}
