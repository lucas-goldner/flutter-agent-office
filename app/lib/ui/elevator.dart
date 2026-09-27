// The elevator's panel: a button for every floor (every project), and "add a project", which clones
// one of the repositories the office's gh login can see and makes it a new floor. The first time
// the office runs there are no floors, and this is where you start (ui/elevator.ts).

import 'package:flutter/material.dart';

import '../office_scope.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// How many repositories the list shows at once; typing narrows it down.
const _shown = 60;

/// Ask gh for the repositories again after this long.
const _reposStaleMs = 5 * 60000;

ModalHandle? _current;

bool elevatorPanelOpen() => _current != null;

/// Opens the panel (once). [ride] takes you to another floor.
void openElevator(OfficeScope scope, {required void Function(String floorId) ride}) {
  if (_current != null) return;
  // Nowhere to go yet: the panel stays until there's a floor to ride to.
  final setup = scope.store.floor == null;
  _current = ModalStack.instance.show(
    (modal) => _ElevatorWindow(scope: scope, modal: modal, ride: ride, setup: setup),
    escCloses: !setup,
    backdropCloses: !setup,
    onClose: () => _current = null,
  );
}

class _ElevatorWindow extends StatefulWidget {
  const _ElevatorWindow({required this.scope, required this.modal, required this.ride, required this.setup});
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
  String _error = '';
  late bool _showAdd = widget.setup || store.floors.isEmpty;

  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topics(const [Topic.floors, Topic.repos, Topic.floor]), () => setState(() {}));
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

  void _go(String floorId) {
    widget.modal.close();
    widget.ride(floorId);
  }

  void _add(String repo) {
    if (_adding != null) return;
    setState(() {
      _adding = repo;
      _error = '';
    });
    widget.scope.net.send(FloorAddCmd(repo));
  }

  void _onAdded(FloorAddedMsg msg) {
    if (_adding == null || msg.repo != _adding) return;
    setState(() => _adding = null);
    if (msg.error != null || msg.floor == null) {
      setState(() => _error = msg.error ?? 'The floor could not be added');
      return;
    }
    _go(msg.floor!);
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
      closable: !setup,
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
          if (store.floors.isEmpty)
            Text(
              'No floors yet.',
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
            )
          else
            for (final (i, f) in store.floors.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                child: _FloorButton(f, i, here: f.id == store.floor, onRide: () => _go(f.id)),
              ),
          Padding(padding: const EdgeInsets.only(top: 16), child: _showAdd ? _addSection(setup) : _openAdd()),
        ],
      ),
      footer: Row(
        children: [
          FooterNote(setup ? 'Your office, one floor per project' : 'Pick a floor · Esc to stay here'),
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
    final dir = store.projectsDir;
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
              ? Text(
                  '⏳ Cloning $_adding into $dir/$_adding… A big repository can take a minute.',
                  style: note.copyWith(color: Swatch.ink),
                )
              : Text(
                  "Cloned into $dest with this machine's gh login. Everything on the new floor works in that checkout.",
                  style: note,
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
  const _FloorButton(this.f, this.i, {required this.here, required this.onRide});
  final FloorInfo f;
  final int i;
  final bool here;
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
        Text('⏳ Cloning…', style: stat)
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
          : 'Ride to ${f.name}',
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
                          if (here) ...[
                            const SizedBox(width: 8),
                            Text('you are here', style: heavy(11, color: Swatch.muted)),
                          ],
                        ],
                      ),
                      Text(
                        f.repo ?? f.dir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                      ),
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
