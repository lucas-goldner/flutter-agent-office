// The floor list that drops down from the project in the corner (ui/floormenu.ts): every floor of
// the building, top floor first, with the rooftop bar over them. Picking one takes you straight
// there, to the same spot in the office you're standing in now. Adding a project is still the
// elevator's job.

import 'package:flutter/material.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof, roofName;

import '../state/store.dart';
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';

/// What the floor list does when you pick something in it.
class FloorMenuOptions {
  const FloorMenuOptions({required this.go, required this.elevator, this.roof});

  /// Go to that floor, staying where you are in the office.
  final void Function(String floorId) go;

  /// Open the elevator's panel, to add a project.
  final VoidCallback elevator;

  /// Up to the rooftop bar, by elevator. Without it there's no roof in the list.
  final VoidCallback? roof;
}

/// One row of the list, worked out from the store (for the widget, and for tests).
typedef FloorRow = ({FloorInfo floor, int number, bool here, String sub});

/// Every floor, top floor first, with where it is from you: "⬆ 2 floors up".
List<FloorRow> floorRows(List<FloorInfo> floors, String? current) {
  final here = floors.indexWhere((f) => f.id == current);
  return [
    for (final (i, f) in floors.indexed)
      (
        floor: f,
        number: i + 1,
        here: f.id == current,
        sub: f.id == current
            ? 'you are here'
            : here < 0
            ? (f.repo ?? f.dir)
            : '${i > here ? '⬆' : '⬇'} ${(i - here).abs()} floor${(i - here).abs() == 1 ? '' : 's'} ${i > here ? 'up' : 'down'}',
      ),
  ].reversed.toList();
}

ModalHandle? _open;

bool floorMenuOpen() => _open != null;
void closeFloorMenu() => _open?.close();

/// Opens the floor list under [anchor], or closes it if it's open.
void toggleFloorMenu(Store store, FloorMenuOptions opts, {Rect? anchor}) {
  final open = _open;
  if (open != null) return open.close();
  _open = ModalStack.instance.show(
    (modal) => _FloorMenuLayer(store: store, opts: opts, modal: modal, anchor: anchor),
    clear: true,
    backdropCloses: false,
    onClose: () => _open = null,
  );
}

class _FloorMenuLayer extends StatelessWidget {
  const _FloorMenuLayer({required this.store, required this.opts, required this.modal, this.anchor});

  final Store store;
  final FloorMenuOptions opts;
  final ModalHandle modal;
  final Rect? anchor;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = (anchor?.bottom ?? 64) + 8;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTapDown: (_) => modal.close()),
        ),
        Positioned(
          top: top,
          left: anchor?.left ?? 12,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (size.width - 24).clamp(200, 380),
              maxHeight: (size.height - top - 20).clamp(120, 2000),
            ),
            child: FloorMenu(store: store, opts: opts, close: modal.close),
          ),
        ),
      ],
    );
  }
}

class FloorMenu extends StatelessWidget {
  const FloorMenu({super.key, required this.store, required this.opts, required this.close});

  final Store store;
  final FloorMenuOptions opts;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ListenableBuilder(
      listenable: store.topics(const [Topic.floors, Topic.floor, Topic.peers]),
      builder: (context, _) {
        final floors = store.floors;
        final onRoof = store.floor == roof;
        final upTop = store.peers.values.where((p) => p.floor == roof).length;
        void pick(VoidCallback fn) {
          close();
          fn();
        }

        return Container(
          key: const ValueKey('floor-menu'),
          width: 360,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Swatch.paper,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Swatch.ink, width: kBorder),
            boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 5))],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                  child: Text(
                    '🏢 ${floors.length} floor${floors.length == 1 ? '' : 's'}',
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w900),
                  ),
                ),
                if (floors.isNotEmpty && opts.roof != null)
                  _Item(
                    key: const ValueKey('floor-roof'),
                    badge: '🍸',
                    badgeColor: Swatch.ink,
                    name: roofName,
                    sub: onRoof ? 'you are here' : 'A DJ, drinks and the city',
                    here: onRoof,
                    stats: [if (upTop > 0) ('🧑 $upTop', 'People up there', false)],
                    tooltip: onRoof ? "You're up on the roof" : 'Take the elevator up to the roof',
                    onTap: onRoof ? null : () => pick(opts.roof!),
                  ),
                for (final r in floorRows(floors, store.floor))
                  _Item(
                    key: ValueKey('floor-${r.floor.id}'),
                    badge: '${r.number}',
                    badgeColor: cssColor(floorPalette(r.floor.palette).trim),
                    name: r.floor.name,
                    sub: r.sub,
                    here: r.here,
                    stats: r.floor.cloning == true
                        ? const [('⏳ Cloning…', 'Still being cloned', false)]
                        : [
                            if (r.floor.waiting > 0) ('🙋 ${r.floor.waiting}', 'Workers waiting on someone', true),
                            if (r.floor.busy > 0) ('👷 ${r.floor.busy}', 'Working', false),
                            ('💻 ${r.floor.workers}', 'Workers at desks', false),
                            if (r.floor.people > 0) ('🧑 ${r.floor.people}', 'People on this floor', false),
                          ],
                    tooltip: r.here
                        ? "You're on this floor"
                        : r.floor.cloning == true
                        ? 'Still being cloned'
                        : "Go to ${r.floor.name}, right where you're standing",
                    onTap: r.here || r.floor.cloning == true ? null : () => pick(() => opts.go(r.floor.id)),
                  ),
                _Item(
                  key: const ValueKey('floor-elevator'),
                  badge: '🛗',
                  badgeColor: Colors.white,
                  name: 'Elevator',
                  sub: 'Add a project…',
                  tooltip: 'The elevator: add another project as a floor',
                  onTap: () => pick(opts.elevator),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item({
    super.key,
    required this.badge,
    required this.badgeColor,
    required this.name,
    required this.sub,
    required this.tooltip,
    this.here = false,
    this.stats = const [],
    this.onTap,
  });

  final String badge;
  final Color badgeColor;
  final String name;
  final String sub;
  final String tooltip;
  final bool here;

  /// (text, tooltip, stands out)
  final List<(String, String, bool)> stats;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 600),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      hoverColor: Swatch.paper2,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: here ? Swatch.paper2 : null, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
                border: Border.all(color: Swatch.ink, width: 2),
              ),
              child: Text(
                badge,
                style: heavy(13, color: Colors.white, weight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(14, weight: FontWeight.w900),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(11, color: Swatch.muted, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            for (final (text, tip, loud) in stats)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: tip,
                  child: Text(text, style: heavy(12, color: loud ? Swatch.bad : Swatch.ink)),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
