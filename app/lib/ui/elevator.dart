// The elevator's panel: a button for every floor (every project), top floor first with the rooftop
// bar over them, and "add a project", which clones one of the repositories the office's gh login can
// see and makes it a new floor. The first time the office runs there are no floors, and this is
// where you start: the workspace folder, GitHub, then your first project. Admins can blow a floor
// off the building here too (💣); its checkout stays on disk (ui/elevator.ts).

import 'dart:async';

import 'package:flutter/material.dart';

import '../office_scope.dart';

import 'package:office_shared/floors.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof, roofName;

import '../state/store.dart';
import 'confirm.dart';
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// How many repositories the list shows at once; typing narrows it down.
const _shown = 60;

/// Ask gh for the repositories again after this long.
const _reposStaleMs = 5 * 60000;

ModalHandle? _current;

/// Longer than the office takes to ask GitHub about a repository before its clone starts (ms).
const _startMs = 60000;

/// The repository the open panel is waiting on the clone of, if any.
String? _waitingOn;

/// Whether the elevator's panel is waiting on [repo]'s clone, so it hears how it ended. When it isn't (the
/// panel was closed while it cloned), a clone that failed still says why: the office shows a toast.
bool elevatorWaitingOn(String repo) => _waitingOn != null && _waitingOn == repo;

/// How far through its step a floor's clone is, as a bar (none until git gives a percentage).
class CloneBar extends StatelessWidget {
  const CloneBar(this.p, {super.key});
  final CloneProgress? p;

  @override
  Widget build(BuildContext context) {
    final pct = p?.percent;
    if (pct == null) return const SizedBox.shrink();
    return Semantics(
      label: p!.step,
      value: '$pct%',
      child: Container(
        height: 11,
        margin: const EdgeInsets.only(top: 5),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Swatch.paper2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Swatch.ink, width: 2),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 600),
            widthFactor: (pct / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: const ColoredBox(color: Swatch.good),
          ),
        ),
      ),
    );
  }
}

/// What the 💣 asks before a floor comes off the building: (title, body).
(String, String) blowUpText(FloorInfo f, List<FloorInfo> floors) {
  FloorInfo? next;
  for (final o in floors) {
    if (o.id != f.id && o.cloning != true) {
      next = o;
      break;
    }
  }
  final n = f.workers;
  final workers = n > 0 ? 'Its $n worker${n == 1 ? '' : 's'} stop${n == 1 ? 's' : ''}. ' : '';
  final people = f.people > 0 ? 'Everyone on it rides the elevator to ${next?.name ?? 'the lobby'}. ' : '';
  // The office was started in it: its accounts, password and chat live in that .agent-office too, and stay.
  final own = f.local == true
      ? ' The office keeps its own settings there too, so it carries on as before, just without this floor.'
      : '';
  return (
    'Blow up ${f.name}?',
    '$workers${people}Nothing is deleted: its checkout stays in ${f.dir}, .agent-office folder and all.$own',
  );
}

/// The onboarding steps a new office shows over its first project: (done, title, what).
List<(bool, String, String)> setupSteps({
  required String dir,
  required bool custom,
  required ({List<RepoChoice> list, String? error, bool loading, int at}) repos,
}) => [
  (
    custom,
    '📁 Where projects go',
    custom ? 'Cloned into $dir/<owner>/<repo>.' : 'Cloned into $dir/<owner>/<repo> unless you pick another folder.',
  ),
  (
    repos.list.isNotEmpty && repos.error == null,
    '🐙 GitHub',
    repos.error != null
        ? "The office's gh login can't list your repositories: run gh auth login on the office's machine, then ↻."
        : repos.loading && repos.list.isEmpty
        ? 'Asking GitHub for your repositories…'
        : repos.list.isEmpty
        ? 'No repositories yet: type owner/name to clone any public one.'
        : "Signed in: ${repos.list.length} repositor${repos.list.length == 1 ? 'y' : 'ies'} to pick from.",
  ),
  (false, '🏗️ Your first project', 'Pick one below: it becomes the first floor of the building.'),
];

bool elevatorPanelOpen() => _current != null;

/// The garage under the building, where the elevator goes too. It isn't a floor: it's down under the one
/// you're on (from the roof, the bottom one), level with the street.
const garageStop = '@garage';

/// Opens the panel (once). [ride] takes you to another floor, the roof or the garage ([garageStop]);
/// [downstairs] says whether you're down in the garage (or out on the street) under the floor you're on.
void openElevator(
  OfficeScope scope, {
  required void Function(String floorId) ride,
  bool Function() downstairs = _upstairs,
}) {
  if (_current != null) return;
  // Nowhere to go yet: the panel greets you. It closes like any other; the elevator (or the floor name in
  // the corner) opens it again.
  final setup = scope.store.floor == null;
  _current = ModalStack.instance.show(
    (modal) => _ElevatorWindow(scope: scope, modal: modal, ride: ride, downstairs: downstairs, setup: setup),
    // A stray click shouldn't lose the first-run panel; ✕ and Esc still close it.
    backdropCloses: !setup,
    onClose: () => _current = null,
  );
}

bool _upstairs() => false;

class _ElevatorWindow extends StatefulWidget {
  const _ElevatorWindow({
    required this.scope,
    required this.modal,
    required this.ride,
    required this.downstairs,
    required this.setup,
  });
  final bool Function() downstairs;
  final OfficeScope scope;
  final ModalHandle modal;
  final void Function(String floorId) ride;
  final bool setup;

  @override
  State<_ElevatorWindow> createState() => _ElevatorWindowState();
}

class _ElevatorWindowState extends State<_ElevatorWindow> with ListenTo {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  String _filter = '';
  String? _selected;
  String? _adding;

  /// The office has started cloning [_adding] (it's on the floor list).
  bool _seen = false;
  Timer? _startTimer;
  String _error = '';
  late bool _showAdd = widget.setup || store.floors.isEmpty;

  /// Moving the workspace folder, right here (an admin, before the first project especially).
  bool _editDir = false;
  final _dir = TextEditingController();
  final _dirFocus = FocusNode();

  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topic(Topic.floors), _checkAdding);
    listenTo(
      store.topics(const [Topic.floors, Topic.repos, Topic.floor, Topic.peers, Topic.me]),
      () => setState(() {}),
    );
    // The folder moved (here or by someone else): done editing it.
    listenTo(store.topic(Topic.projectsDir), () => setState(() => _editDir = false));
    listenStream(widget.scope.net.messages, (msg) {
      if (msg is FloorAddedMsg) _onAdded(msg);
    });
    if (_showAdd) {
      _needRepos();
      WidgetsBinding.instance.addPostFrameCallback((_) => _inputFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    if (_adding != null && _waitingOn == _adding) _waitingOn = null;
    _dir.dispose();
    _dirFocus.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _needRepos() {
    final r = store.repos;
    if (r.loading || (r.at > 0 && DateTime.now().millisecondsSinceEpoch - r.at < _reposStaleMs && r.error == null)) {
      return;
    }
    store.repos = (list: r.list, error: r.error, loading: true, at: r.at);
    widget.scope.net.send(const FloorReposCmd());
  }

  /// What "Add floor" would add: the row picked, else what's typed if it's owner/name.
  String? _choice() => _selected ?? normalizeRepo(_filter);

  void _startEditDir() {
    setState(() {
      _editDir = true;
      _dir.text = store.projectsDir.dir;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _dirFocus.requestFocus());
  }

  void _saveDir() {
    final dir = _dir.text.trim();
    if (dir.isEmpty) return _dirFocus.requestFocus();
    // The server says why it can't, if it can't; the folder moving closes this.
    if (dir == store.projectsDir.dir) {
      setState(() => _editDir = false);
    } else {
      widget.scope.net.send(FloorProjectsDirCmd(dir));
    }
  }

  void _blowUp(FloorInfo f) {
    final (title, body) = blowUpText(f, store.floors);
    confirmDialog(title, body, '💣 Blow it up', () => widget.scope.net.send(FloorRemoveCmd(f.id)));
  }

  void _go(String floorId) {
    widget.modal.close();
    widget.ride(floorId);
  }

  void _add(String repo) {
    if (_adding != null) return;
    setState(() {
      _adding = repo;
      _seen = false;
      _error = '';
    });
    _waitingOn = repo;
    widget.scope.net.send(FloorAddCmd(repo));
    // The office went away before it started (a restart): don't wait forever.
    _startTimer?.cancel();
    _startTimer = Timer(const Duration(milliseconds: _startMs), () {
      if (!mounted || _adding != repo || _seen) return;
      setState(() {
        _adding = null;
        _error = "The office didn't start cloning $repo — try again";
      });
    });
  }

  /// The floor being added, once the office is cloning it (and after, when it's there).
  FloorInfo? _addingFloor() {
    final a = _adding;
    return a == null ? null : store.floors.where((f) => sameRepo(f.repo, a)).firstOrNull;
  }

  /// Done waiting on the clone, one way or another.
  void _settle(String? floor, [String? why]) {
    _startTimer?.cancel();
    if (_waitingOn == _adding) _waitingOn = null;
    setState(() => _adding = null);
    if (floor != null) return _go(floor);
    setState(() => _error = why ?? 'The floor could not be added');
  }

  void _onAdded(FloorAddedMsg msg) {
    if (_adding == null || msg.repo != _adding) return;
    _settle(msg.error != null ? null : msg.floor, msg.error);
  }

  /// The floor list changed. The office answers the one who asked with floor.added, but if it restarted
  /// mid-clone that answer went nowhere: the floor list still shows how it ended.
  void _checkAdding() {
    final adding = _adding;
    if (adding == null) return;
    final f = _addingFloor();
    if (f?.cloning == true) {
      _seen = true;
    } else if (_seen) {
      _settle(f?.id, 'Cloning $adding stopped before it finished — add it again');
    }
  }

  /// ⏹️: whoever added it, or an admin, stops a clone.
  void _stopClone(FloorInfo f) => confirmDialog(
    'Stop cloning ${f.repo ?? f.name}?',
    "What's come down so far is thrown away. You can add it again any time.",
    '⏹️ Stop cloning',
    () => widget.scope.net.send(FloorCancelCmd(f.id)),
  );

  /// While it clones: how far it's got (the office asks GitHub about it first).
  Widget _cloning(String dir, TextStyle note) {
    final on = _addingFloor();
    final repo = on?.repo ?? _adding!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          on != null ? '⏳ Cloning $repo into $dir/$repo' : '⏳ Asking GitHub about $_adding…',
          style: note.copyWith(color: Swatch.ink),
        ),
        if (on != null) ...[
          CloneBar(on.clone),
          Text([cloneStep(on.clone), ?on.clone?.detail].join(' · '), style: note),
        ],
        Text('You can close this and carry on: everyone hears when the new floor opens.', style: note),
      ],
    );
  }

  List<RepoChoice> _matches(String q) => store.repos.list
      .where((x) => q.isEmpty || x.name.toLowerCase().contains(q) || (x.description ?? '').toLowerCase().contains(q))
      .toList();

  void _enter() {
    final q = _filter.trim().toLowerCase();
    final matches = _matches(q).where((x) => !store.floors.any((f) => sameRepo(f.repo, x.name))).toList();
    final pick = _choice() ?? (q.isNotEmpty && matches.length == 1 ? matches.first.name : null);
    if (pick != null) _add(pick);
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    final pick = _choice();
    return ModalWindow(
      modal: widget.modal,
      width: 640,
      title: Text(setup ? '🏢 Welcome to Agent Office' : '🛗 Elevator'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (setup)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                store.floors.isNotEmpty
                    ? 'Every project is a floor of this building. Pick a floor to ride to, or add another project.'
                    : "Every project is a floor of this building, and it doesn't have any yet. Pick one of your repositories: the office clones it and it becomes the first floor.",
                style: heavy(16, weight: FontWeight.w700),
              ),
            ),
          if (setup && store.floors.isEmpty) ..._steps(),
          // The roof over every floor: the rooftop bar.
          if (store.floors.any((f) => f.cloning != true))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RoofButton(
                here: store.floor == roof,
                people: store.peers.values.where((p) => p.floor == roof).length,
                onRide: () => _go(roof),
              ),
            ),
          if (store.floors.isEmpty)
            Text(
              'No floors yet.',
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
            )
          else
            // Top floor first, the way an elevator's buttons stack, with floor 1 at the bottom.
            for (final (i, f) in store.floors.indexed.toList().reversed)
              Padding(
                padding: EdgeInsets.only(top: i == store.floors.length - 1 ? 0 : 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _FloorButton(
                        f,
                        i,
                        // Down in the garage, your floor is somewhere to go back up to.
                        here: f.id == store.floor && !widget.downstairs(),
                        mine: f.id == store.floor,
                        onRide: () => _go(f.id),
                      ),
                    ),
                    if (f.cloning == true && (store.me.admin || (_adding != null && sameRepo(f.repo, _adding!)))) ...[
                      const SizedBox(width: 8),
                      OfficeButton(
                        key: ValueKey('stop-${f.id}'),
                        label: '⏹️',
                        tooltip: 'Stop cloning ${f.repo ?? f.name}',
                        onPressed: () => _stopClone(f),
                      ),
                    ],
                    if (f.cloning != true) ...[
                      const SizedBox(width: 8),
                      OfficeButton(
                        key: ValueKey('pull-${f.id}'),
                        label: '⬇️',
                        tooltip: 'Pull the latest${f.branch != null ? ' ${f.branch}' : ''} from GitHub into ${f.name}',
                        onPressed: () => widget.scope.net.send(FloorPullCmd(f.id)),
                      ),
                    ],
                    if (store.me.admin && f.cloning != true) ...[
                      const SizedBox(width: 8),
                      OfficeButton(
                        key: ValueKey('blow-${f.id}'),
                        label: '💣',
                        tooltip: 'Blow ${f.name} off the building',
                        onPressed: () => _blowUp(f),
                      ),
                    ],
                  ],
                ),
              ),
          // Under floor 1: the garage, level with the street.
          if (store.floors.any((f) => f.cloning != true))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _GarageButton(
                here: widget.downstairs(),
                under: store.floor == roof
                    ? 'Under ${store.floors.where((f) => f.cloning != true).firstOrNull?.name ?? 'the building'}, level with the street'
                    : 'Under the building, level with the street: the cars, and the way out',
                onRide: () => _go(garageStop),
              ),
            ),
          Padding(padding: const EdgeInsets.only(top: 16), child: _showAdd ? _addSection(setup) : _openAdd()),
        ],
      ),
      footer: Row(
        children: [
          FooterNote(
            setup ? 'Your office, one floor per project · Esc to look around first' : 'Pick a floor · Esc to stay here',
          ),
          if (_showAdd) ...[
            const SizedBox(width: 8),
            OfficeButton(
              label: _adding != null
                  ? '⏳ Cloning…'
                  : pick != null
                  ? '🛗 Add $pick'
                  : '🛗 Add floor',
              kind: BtnKind.primary,
              onPressed: _adding != null || pick == null || store.floors.any((f) => sameRepo(f.repo, pick))
                  ? null
                  : () => _add(pick),
            ),
          ],
        ],
      ),
    );
  }

  /// A new office's walk-through: where projects go, GitHub, then the first project.
  List<Widget> _steps() => [
    for (final (i, (done, title, what)) in setupSteps(
      dir: store.projectsDir.dir,
      custom: store.projectsDir.custom,
      repos: store.repos,
    ).indexed)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: done ? Swatch.good : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Swatch.ink, width: 2),
              ),
              child: Text(done ? '✓' : '${i + 1}', style: heavy(12, color: done ? Colors.white : Swatch.ink)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: heavy(14, weight: FontWeight.w900)),
                  Text(
                    what,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
  ];

  Widget _openAdd() => Align(
    alignment: Alignment.centerLeft,
    child: OfficeButton(
      label: '➕ Add a project',
      onPressed: () {
        setState(() => _showAdd = true);
        _needRepos();
        WidgetsBinding.instance.addPostFrameCallback((_) => _inputFocus.requestFocus());
      },
    ),
  );

  Widget _addSection(bool setup) {
    final r = store.repos;
    final q = _filter.trim().toLowerCase();
    final typed = normalizeRepo(_filter);
    final matches = _matches(q);
    final rows = <Widget>[];
    // owner/name that isn't in the list (someone else's public repository): offer it anyway.
    if (typed != null && !r.list.any((x) => sameRepo(x.name, typed))) {
      rows.add(
        _repoRow(
          RepoChoice(name: typed, private: false, description: 'Not in your list — the office will try to clone it'),
        ),
      );
    }
    rows.addAll(matches.take(_shown).map(_repoRow));
    if (rows.isEmpty) {
      final empty = r.loading
          ? 'Asking GitHub for your repositories…'
          : r.error != null
          ? ''
          : q.isNotEmpty
          ? 'Nothing matches. Type owner/name to clone any repository.'
          : 'No repositories.';
      if (empty.isNotEmpty) {
        rows.add(
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              empty,
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
            ),
          ),
        );
      }
    }
    if (matches.length > _shown) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            '…and ${matches.length - _shown} more — type to narrow it down',
            style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
          ),
        ),
      );
    }
    final pick = _choice();
    final dir = store.projectsDir.dir;
    final dest = pick != null ? '$dir/$pick' : '$dir/<owner>/<repo>';
    final note = heavy(12, color: Swatch.muted, weight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            setup && store.floors.isEmpty ? 'Pick your first project' : '➕ Add a project',
            style: heavy(15, weight: FontWeight.w900),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: BoxInput(
                controller: _input,
                focusNode: _inputFocus,
                enabled: _adding == null,
                hint: 'Search your repositories, or type owner/name',
                onChanged: (v) => setState(() {
                  _filter = v;
                  // Typing something else drops the row that was picked, unless it's still what's typed.
                  if (_selected != null && !sameRepo(_selected, normalizeRepo(_filter))) _selected = null;
                }),
                onSubmitted: (_) => _enter(),
              ),
            ),
            const SizedBox(width: 8),
            OfficeButton(
              label: '↻',
              tooltip: 'Ask GitHub for the list again',
              onPressed: () {
                setState(() => store.repos = (list: r.list, error: null, loading: true, at: r.at));
                widget.scope.net.send(const FloorReposCmd(refresh: true));
              },
            ),
          ],
        ),
        Container(
          margin: const EdgeInsets.only(top: 8),
          constraints: const BoxConstraints(maxHeight: 280),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Swatch.ink, width: kBorder),
          ),
          child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: rows),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _adding != null
              ? _cloning(dir, note)
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Text(
                      "Cloned into $dest with this machine's gh login. Everything on the new floor works in that checkout.",
                      style: note,
                    ),
                    if (store.me.admin && !_editDir)
                      SmallButton(
                        key: const ValueKey('dir-change'),
                        label: '📁 Change folder',
                        tooltip: 'Clone new projects into another folder on the office’s machine',
                        onPressed: _startEditDir,
                      ),
                  ],
                ),
        ),
        if (_editDir)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: BoxInput(
                    key: const ValueKey('dir-input'),
                    controller: _dir,
                    focusNode: _dirFocus,
                    hint: '~/Workspace',
                    onSubmitted: (_) => _saveDir(),
                  ),
                ),
                const SizedBox(width: 8),
                OfficeButton(label: 'Save', kind: BtnKind.primary, onPressed: _saveDir),
                const SizedBox(width: 8),
                OfficeButton(label: 'Cancel', onPressed: () => setState(() => _editDir = false)),
              ],
            ),
          ),
        for (final e in [r.error, _error].where((e) => e != null && e.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(e!, style: heavy(13, color: Swatch.bad)),
          ),
      ],
    );
  }

  Widget _repoRow(RepoChoice r) {
    FloorInfo? floor;
    for (final f in store.floors) {
      if (sameRepo(f.repo, r.name)) floor = f;
    }
    final sel = _selected != null && sameRepo(_selected, r.name);
    return _RepoRow(
      repo: r,
      selected: sel,
      floorTag: floor == null
          ? null
          : floor.id == store.floor
          ? 'you are here'
          : 'floor ${store.floors.indexOf(floor) + 1}',
      onTap: () {
        if (_adding != null) return;
        if (floor != null) {
          // Already a floor: the row takes you there.
          if (floor.id != store.floor && floor.cloning != true) _go(floor.id);
          return;
        }
        setState(() => _selected = r.name);
      },
      onDoubleTap: floor == null ? () => _add(r.name) : null,
    );
  }
}

class _FloorButton extends StatefulWidget {
  const _FloorButton(this.f, this.i, {required this.here, this.mine = false, required this.onRide});
  final FloorInfo f;
  final int i;
  final bool here;

  /// The floor you're on, down in the garage under it.
  final bool mine;
  final VoidCallback onRide;

  @override
  State<_FloorButton> createState() => _FloorButtonState();
}

class _FloorButtonState extends State<_FloorButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final here = widget.here;
    final cloning = f.cloning == true;
    final disabled = cloning || here;
    final stat = heavy(13);
    final stats = <Widget>[
      if (cloning)
        Tooltip(
          message: f.clone?.detail ?? 'Being cloned',
          child: Text(cloneLabel(f.clone), style: stat),
        )
      else ...[
        if (f.busy > 0)
          Tooltip(
            message: 'Working',
            child: Text('👷 ${f.busy}', style: stat),
          ),
        if (f.waiting > 0)
          Tooltip(
            message: 'Waiting on someone',
            child: Text('🙋 ${f.waiting}', style: stat.copyWith(color: Swatch.bad)),
          ),
        Tooltip(
          message: 'Workers at desks',
          child: Text('💻 ${f.workers}', style: stat),
        ),
        if (f.people > 0)
          Tooltip(
            message: 'People on this floor',
            child: Text('🧑 ${f.people}', style: stat),
          ),
      ],
    ];
    final pressed = here || _down;
    return Tooltip(
      message: here
          ? "You're on this floor"
          : cloning
          ? 'Still being cloned'
          : 'Ride ${widget.mine ? 'back up ' : ''}to ${f.name}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = _down = false),
        child: GestureDetector(
          onTapDown: disabled ? null : (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: disabled ? null : widget.onRide,
          child: Container(
            transform: Matrix4.translationValues(0, pressed ? 2 : 0, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: here || (_hover && !disabled) ? Swatch.paper2 : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Swatch.ink, width: kBorder),
              boxShadow: [if (!here) BoxShadow(color: Swatch.ink, offset: Offset(0, _down ? 1 : 3))],
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cssColor(floorPalette(f.palette).trim),
                    shape: BoxShape.circle,
                    border: Border.all(color: Swatch.ink, width: kBorder),
                  ),
                  child: Text(
                    '${widget.i + 1}',
                    style: heavy(15, color: Colors.white, weight: FontWeight.w900).copyWith(
                      shadows: const [Shadow(color: Color(0x59000000), offset: Offset(0, 1))],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              f.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: heavy(15, weight: FontWeight.w900),
                            ),
                          ),
                          if (here || widget.mine) ...[
                            const SizedBox(width: 8),
                            Text(here ? 'you are here' : 'your floor', style: heavy(11, color: Swatch.muted)),
                          ],
                        ],
                      ),
                      Text(
                        [f.repo ?? f.dir, if (cloning) ?f.clone?.detail].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                      ),
                      if (cloning) CloneBar(f.clone),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Wrap(spacing: 6, children: stats),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RepoRow extends StatefulWidget {
  const _RepoRow({
    required this.repo,
    required this.selected,
    required this.floorTag,
    required this.onTap,
    this.onDoubleTap,
  });
  final RepoChoice repo;
  final bool selected;
  final String? floorTag;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  @override
  State<_RepoRow> createState() => _RepoRowState();
}

class _RepoRowState extends State<_RepoRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.repo;
    return Tooltip(
      message: r.description ?? r.name,
      waitDuration: const Duration(milliseconds: 800),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? const Color(0xFFFFE3D6)
                  : _hover
                  ? Swatch.paper2
                  : null,
              border: const Border(bottom: BorderSide(color: Swatch.paper2, width: 2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(r.name, style: heavy(16)),
                if (r.private) ...[const SizedBox(width: 8), const Tooltip(message: 'Private', child: Text('🔒'))],
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.description ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w400),
                  ),
                ),
                if (widget.floorTag != null)
                  Pill(widget.floorTag!)
                else if (r.pushedAt != null)
                  Text(
                    timeAgo(r.pushedAt!),
                    style: heavy(11, color: Swatch.muted, weight: FontWeight.w400),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The roof, over every floor: the rooftop bar.
class _RoofButton extends StatelessWidget {
  const _RoofButton({required this.here, required this.people, required this.onRide});

  final bool here;
  final int people;
  final VoidCallback onRide;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: here ? "You're up on the roof" : 'Ride up to the ${roofName.toLowerCase()}',
    waitDuration: const Duration(milliseconds: 600),
    child: InkWell(
      key: const ValueKey('ride-roof'),
      onTap: here ? null : onRide,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: here ? Swatch.paper2 : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Swatch.ink, width: kBorder),
          boxShadow: [if (!here) const BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Swatch.ink,
                shape: BoxShape.circle,
                border: Border.all(color: Swatch.ink, width: kBorder),
              ),
              child: const Text('🍸'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(here ? '$roofName · you are here' : roofName, style: heavy(15, weight: FontWeight.w900)),
                  Text(
                    'The roof: a DJ playing drum and bass, a bar, and the city all around',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            if (people > 0)
              Tooltip(
                message: 'People up there',
                child: Text('🧑 $people', style: heavy(13)),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Under floor 1: the garage, level with the street.
class _GarageButton extends StatelessWidget {
  const _GarageButton({required this.here, required this.under, required this.onRide});

  final bool here;
  final String under;
  final VoidCallback onRide;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: here ? "You're down at the street" : 'Ride down to the garage',
    waitDuration: const Duration(milliseconds: 600),
    child: InkWell(
      key: const ValueKey('ride-garage'),
      onTap: here ? null : onRide,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: here ? Swatch.paper2 : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Swatch.ink, width: kBorder),
          boxShadow: [if (!here) const BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Swatch.ink,
                shape: BoxShape.circle,
                border: Border.all(color: Swatch.ink, width: kBorder),
              ),
              child: const Text('🏎️'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(here ? 'Garage · you are here' : 'Garage', style: heavy(15, weight: FontWeight.w900)),
                  Text(
                    under,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
