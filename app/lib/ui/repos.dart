// A worker across repositories (ui/repos.ts, see WorkerInfo.repos): one task in worktrees of several
// floors' projects, all on the same branch, with a pull request in each repository it commits to. The
// "🗂️ Also work in" picker for hiring one, and O at its desk: each repository's pull request.

import 'package:flutter/material.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

import '../interop/open_link.dart';
import '../office_scope.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart' show ListenTo;

/// Another floor's project a new worker can work in too.
typedef FloorChoice = ({String id, String name});

/// The building's other projects a new worker can work in too, each in a worktree of its own: floors with
/// a git checkout that aren't still being cloned.
List<FloorChoice> repoChoices(Store store) => [
  for (final f in store.floors)
    if (f.id != store.floor && f.branch != null && f.cloning != true) (id: f.id, name: f.name),
];

/// One of a worker's repositories: the floor it's on (null: the worker's own), its folder in the
/// workspace, and its pull request.
typedef WorkerRepoView = ({String? floor, String name, ({int number, String url})? pr});

String _folder(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? 'project' : parts.last;
}

/// Each of a worker's repositories, its own floor's first.
List<WorkerRepoView> workerRepos(WorkerInfo w) {
  final wt = w.worktree;
  if (wt == null) return const [];
  return [
    (floor: null, name: _folder(wt.path), pr: w.pr == null ? null : (number: w.pr!.number, url: w.pr!.url)),
    for (final r in w.repos ?? const <WorkerRepo>[])
      (floor: r.floor, name: r.name, pr: r.pr == null ? null : (number: r.pr!.number, url: r.pr!.url)),
  ];
}

/// The folders of its workspace, its own floor's first, for the send-home dialog; null for a worker in one.
List<String>? workerRepoFolders(WorkerInfo w) {
  if (w.repos == null || w.repos!.isEmpty) return null;
  return [for (final r in workerRepos(w)) r.name];
}

/// What the O in a desk hint says for a worker across repositories: its pull requests so far, or opening
/// them. Null when there's nothing to press O for yet. [ready]: done enough to open them.
({bool key, String text})? reposKey(WorkerInfo w, {required bool ready}) {
  final repos = workerRepos(w);
  final prs = repos.where((r) => r.pr != null).length;
  if (w.prOpening == true) return (key: false, text: '⏳ Opening PRs…');
  if (prs > 0) return (key: true, text: '$prs of ${repos.length} PRs');
  return ready ? (key: true, text: 'Open PRs (${repos.length} repos)') : null;
}

/// "🗂️ Also work in": other floors' projects, each a checkbox.
class RepoPicker extends StatelessWidget {
  const RepoPicker({super.key, required this.options, required this.picked, required this.onChanged});

  final List<FloorChoice> options;
  final Set<String> picked;
  final void Function(String id, bool on) onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Semantics(
      label: 'Other projects to work in',
      container: true,
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('🗂️ Also work in', style: heavy(14, weight: FontWeight.w700)),
          for (final r in options)
            Tooltip(
              message: 'A worktree of ${r.name} too, on the same branch, with a pull request of its own',
              child: InkWell(
                key: ValueKey('repo-pick-${r.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChanged(r.id, !picked.contains(r.id)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: Checkbox(
                        value: picked.contains(r.id),
                        onChanged: (v) => onChanged(r.id, v ?? false),
                        activeColor: Swatch.accent,
                        side: const BorderSide(color: Swatch.ink, width: 2),
                      ),
                    ),
                    Text(r.name, style: heavy(14, weight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class RepoPullsActions {
  const RepoPullsActions({required this.openPull, required this.openMissing, required this.changes});

  /// Its own floor's pull request, in the PR window.
  final void Function(int number, String url) openPull;

  /// Push and open the ones still missing ('worker.pr').
  final VoidCallback openMissing;

  /// The Changes window, on that repository's tab (null: its own floor's).
  final void Function(String? repo) changes;
}

/// O at the desk of a worker across repositories, once it has a pull request: each repository with its
/// pull request (or none yet) and its changes, and a button that opens the missing ones.
ModalHandle openRepoPulls(OfficeScope scope, String workerId, RepoPullsActions actions) =>
    ModalStack.instance.show((m) => _RepoPulls(scope: scope, modal: m, workerId: workerId, actions: actions))
      ..doing = '🔀 looking over pull requests';

class _RepoPulls extends StatefulWidget {
  const _RepoPulls({required this.scope, required this.modal, required this.workerId, required this.actions});
  final OfficeScope scope;
  final ModalHandle modal;
  final String workerId;
  final RepoPullsActions actions;

  @override
  State<_RepoPulls> createState() => _RepoPullsState();
}

class _RepoPullsState extends State<_RepoPulls> with ListenTo {
  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topics(const [Topic.workers, Topic.floors]), () {
      final w = store.workers[widget.workerId];
      if (w?.worktree == null) {
        widget.modal.close();
      } else {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = store.workers[widget.workerId];
    if (w == null || w.worktree == null) return const SizedBox.shrink();
    final repos = workerRepos(w);
    final busy = isBusy(w.status);
    final opening = w.prOpening == true;
    return ModalWindow(
      modal: widget.modal,
      width: 620,
      title: Text("🔀 ${w.name}'s pull requests"),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'One change across ${repos.length} repositories, each on 🌿 ${w.worktree!.branch}. Each repository it commits to gets a pull request of its own, and each one lists the others.',
              style: heavy(14, weight: FontWeight.w700),
            ),
          ),
          for (final r in repos) _row(w, r),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: 8,
        children: [
          OfficeButton(label: 'Close', onPressed: widget.modal.close),
          if (repos.any((r) => r.pr == null))
            OfficeButton(
              key: const ValueKey('open-missing-prs'),
              label: opening ? '⏳ Opening…' : '🔀 Open the missing PRs',
              kind: BtnKind.primary,
              tooltip: busy
                  ? "${w.name} is still at it — wait until it's done"
                  : 'Pushes the branch in each repository with commits and no pull request yet, and opens one there',
              onPressed: opening || busy ? null : widget.actions.openMissing,
            ),
        ],
      ),
    );
  }

  Widget _row(WorkerInfo w, WorkerRepoView r) {
    final floor = r.floor != null
        ? store.floors.where((f) => f.id == r.floor).firstOrNull?.name
        : store.currentFloor()?.name;
    final pr = r.pr;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Swatch.ink, width: kBorder),
        ),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('📁 ${r.name}', style: heavy(15)),
                  Text(
                    floor != null ? '$floor floor${r.floor == null ? ' · this one' : ''}' : 'no longer in the building',
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            if (pr != null)
              OfficeButton(
                label: '🔀 #${pr.number}${r.floor != null ? ' ↗' : ''}',
                dense: true,
                tooltip: r.floor != null ? 'Open it on GitHub' : 'Open it',
                onPressed: () {
                  if (r.floor != null) return openInNewTab(pr.url);
                  widget.modal.close();
                  widget.actions.openPull(pr.number, pr.url);
                },
              )
            else
              Text(
                'No PR yet',
                style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
              ),
            OfficeButton(
              label: '🌿 Changes',
              dense: true,
              tooltip: 'What ${w.name} changed in ${r.name}',
              onPressed: () {
                widget.modal.close();
                widget.actions.changes(r.floor);
              },
            ),
          ],
        ),
      ),
    );
  }
}
