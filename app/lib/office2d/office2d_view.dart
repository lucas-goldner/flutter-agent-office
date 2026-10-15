// The 👾 2D office (⚙️ Settings → Office, or F2): the floor as a pixel map from above instead of the
// 3D scene, for when the GPU has better things to do. The office runs just as it does in 3D (the
// controller's tick: people, workers, the dog), only nothing is rendered in 3D. Click the
// floor to walk there; click something to walk over and use it, as E would. Windows (the whiteboard,
// boards, the arcade's games) open over the map as they do over the 3D office.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/nav.dart' show deskPoint;
import 'package:office_shared/protocol.dart';

import '../office/controller.dart';
import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../ui/theme.dart';
import '../world/collider.dart';
import 'map_painter.dart';
import 'pixel_map.dart';

/// Room left at the top of the map for the HUD's bar.
const double kMap2dTop = 64;

class Office2DView extends StatefulWidget {
  const Office2DView({super.key, required this.c});
  final OfficeController c;

  @override
  State<Office2DView> createState() => _Office2DViewState();
}

class _Office2DViewState extends State<Office2DView> with SingleTickerProviderStateMixin {
  OfficeController get c => widget.c;
  late final Ticker _ticker = createTicker(_frame);
  final _repaint = ValueNotifier<int>(0);
  ui.Image? _map;
  Size _size = Size.zero;
  Duration _last = Duration.zero;
  double _pending = 0;
  double _t = 0;
  Offset? _mouse;
  Interactable? _hover;

  /// How far in you've zoomed (1: the whole floor), and the floor point in the middle of the view
  /// (null: the floor's middle). While [_follow], the view keeps you in the middle as you walk.
  double _zoom = 1;
  ({double x, double z})? _center;
  bool _follow = false;

  /// Which way your sprite faces: the way you last walked, toward the viewer to start with.
  double _myFacing = 0;
  ({double x, double z})? _myLast;
  double _pinch = 1;

  /// A press that may turn into a drag (which pans) instead of a click (which walks).
  Offset? _pressAt;
  bool _dragging = false;

  /// Something you can use is under the mouse: the hand cursor.
  final _pointing = ValueNotifier<bool>(false);
  late final OfficeMapPainter _painter = OfficeMapPainter(
    map: null,
    scene: _scene,
    top: kMap2dTop,
    view: _viewFor,
    repaint: _repaint,
  );

  @override
  void initState() {
    super.initState();
    _drawMap();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _pointing.dispose();
    _map?.dispose();
    super.dispose();
  }

  /// Which map is drawn: the building's map, and on the office how far its back office is built out.
  String _drawn = '';

  String get _mapKey => c.inOffice ? 'office|${c.store.floorPlan.wing}' : c.plan.id;

  /// Draws the floor plan of the map you're on: the office's (with its back office as far as it's
  /// built out), or a map of its own's from its plan (the castle's hall, the station's deck).
  Future<void> _drawMap() async {
    final key = _drawn = _mapKey;
    final rec = ui.PictureRecorder();
    if (c.inOffice) {
      final wing = c.store.floorPlan.wing;
      MapBounds.office(wing);
      paintFloorPlan(Canvas(rec), wing: wing);
    } else {
      MapBounds.plan(c.plan.bounds);
      paintMapPlan(Canvas(rec), c.plan);
    }
    final img = await rec.endRecording().toImage(MapBounds.width, MapBounds.height);
    if (!mounted || key != _drawn) return img.dispose();
    final old = _map;
    setState(() {
      _map = img;
      _painter.map = img;
    });
    old?.dispose();
  }

  /// The office runs every frame; the map is painted at most 30 times a second, so the GPU can rest.
  void _frame(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    _pending += math.min(dt, 0.1);
    if (_pending < 1 / 30) return;
    final step = _pending;
    _pending = 0;
    _t += step;
    // On to another map (or the back office built out): its plan, and the whole of it in view.
    if (_mapKey != _drawn) {
      _zoom = 1;
      _center = null;
      _follow = false;
      _drawMap();
    }
    // W up the map, as the map is drawn north up.
    if (!c.player.walkingPath) c.player.camYaw = 0;
    c.tick(step, _size);
    final at = (x: c.player.pos.x, z: c.player.pos.z), was = _myLast;
    if (was != null && ((at.x - was.x).abs() + (at.z - was.z).abs()) > 0.01) {
      _myFacing = math.atan2(at.x - was.x, at.z - was.z);
    }
    _myLast = at;
    if (_follow) {
      final c0 = _center ?? _mapMiddle;
      final ease = math.min(1.0, step * 5);
      _center = _clamp((x: c0.x + (c.player.pos.x - c0.x) * ease, z: c0.z + (c.player.pos.z - c0.z) * ease));
    }
    _hover = _mouse == null || ModalStack.instance.open ? null : (_labelAt(_mouse!) ?? _hit(_mouse!));
    _pointing.value = _hover != null;
    _repaint.value++;
  }

  // ---- Zooming and panning -------------------------------------------------------------------

  ({double x, double z}) get _mapMiddle => floorPoint(Offset(MapBounds.width / 2, MapBounds.height / 2));

  /// Where the map is on a page [size] big, as zoomed and panned.
  MapView _viewFor(Size size) {
    final f = mapFit(size, top: kMap2dTop);
    if (_zoom <= 1 && _center == null) return MapView(f.scale, f.origin);
    final scale = f.scale * _zoom;
    final c = _center ?? _mapMiddle;
    final mid = Offset(size.width / 2, kMap2dTop + (size.height - kMap2dTop) / 2);
    return MapView(scale, mid - mapPoint(c.x, c.z) * scale);
  }

  ({double x, double z}) _clamp(({double x, double z}) c) => (
    x: c.x.clamp(MapBounds.minX, MapBounds.maxX).toDouble(),
    z: c.z.clamp(MapBounds.minZ, MapBounds.maxZ).toDouble(),
  );

  /// Zooms by [factor], keeping the floor under [focal] (page pixels) where it is.
  void _zoomAt(Offset focal, double factor) {
    final f = _viewFor(_size).toFloor(focal);
    final c = _center ?? _mapMiddle;
    final zoom = (_zoom * factor).clamp(1.0, kMaxZoom).toDouble();
    if (zoom == _zoom) return;
    final k = _zoom / zoom;
    _zoom = zoom;
    if (_zoom <= 1.0001) {
      _zoom = 1;
      _center = null;
      _follow = false;
    } else if (!_follow) {
      _center = _clamp((x: f.x - (f.x - c.x) * k, z: f.z - (f.z - c.z) * k));
    }
    _repaint.value++;
  }

  /// Moves the map with your fingers (or the mouse) by [d] page pixels.
  void _panBy(Offset d) {
    if (_zoom <= 1) return;
    _follow = false;
    final m = _viewFor(_size).perMeter;
    final c = _center ?? _mapMiddle;
    _center = _clamp((x: c.x - d.dx / m, z: c.z - d.dy / m));
    _repaint.value++;
  }

  Offset get _middle => Offset(_size.width / 2, kMap2dTop + (_size.height - kMap2dTop) / 2);

  /// Zoomed in, the view keeps you in the middle (until you pan away).
  void _followMe() {
    if (_zoom < 2.5) _zoom = 2.5;
    _follow = true;
    _center = (x: c.player.pos.x, z: c.player.pos.z);
    _repaint.value++;
  }

  void _wholeFloor() {
    _zoom = 1;
    _center = null;
    _follow = false;
    _repaint.value++;
  }

  void _signal(PointerSignalEvent e) {
    if (ModalStack.instance.open) return;
    if (e is PointerScaleEvent) return _zoomAt(e.localPosition, e.scale);
    if (e is! PointerScrollEvent) return;
    final hk = HardwareKeyboard.instance;
    // ⌘ or Ctrl and the wheel (and a browser's pinch) zoom; a two-finger swipe moves the map.
    if (hk.isMetaPressed || hk.isControlPressed) return _zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy * 0.0012));
    _panBy(-e.scrollDelta);
  }

  /// The floor point under [p] (page pixels).
  ({double x, double z}) _floorAt(Offset p) => _viewFor(_size).toFloor(p);

  /// What you can use under the mouse, on this floor (not the loft's): the thing itself, or the
  /// nearest spot you'd stand at to use something.
  Interactable? _hit(Offset p) {
    final at = _floorAt(p);
    Interactable? best;
    var bestD = double.infinity;
    for (final it in c.interactables) {
      if (it.off || (it.y ?? 0) > 1) continue;
      final shape = _objectOf(it);
      if (shape != null && shape.inflate(0.15).contains(Offset(at.x, at.z))) return it;
      final d = math.sqrt(math.pow(it.x - at.x, 2) + math.pow(it.z - at.z, 2));
      final reach = math.max(0.45, math.min(it.radius * 0.6, 1.0));
      if (d < reach && d < bestD) {
        best = it;
        bestD = d;
      }
    }
    return best;
  }

  /// The thing whose name tag is under [p], if any.
  Interactable? _labelAt(Offset p) {
    final its = c.interactables;
    for (final (r, id) in _painter.labelHits.reversed) {
      if (r.contains(p) && id >= 0 && id < its.length) return its[id];
    }
    return null;
  }

  void _click(Offset p) {
    if (ModalStack.instance.open) return;
    final it = _labelAt(p) ?? _hit(p);
    if (it != null) return c.use2d(it);
    final at = _floorAt(p);
    c.walk2d(at.x, at.z);
  }

  /// Right-clicked on the map: what you can do with the thing there (a worker: open its terminal, its
  /// changes, prompt it, its PR, send it home…), as its keys in 3D.
  Future<void> _menu(Offset local, Offset global) async {
    if (ModalStack.instance.open) return;
    final it = _labelAt(local) ?? _hit(local);
    if (it == null) return;
    final actions = c.actions2d(it);
    if (actions.isEmpty) return;
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
      items: [
        PopupMenuItem<int>(
          enabled: false,
          height: 32,
          child: Text(_title(it), style: heavy(13, weight: FontWeight.w900)),
        ),
        const PopupMenuDivider(),
        for (final (i, a) in actions.indexed)
          PopupMenuItem<int>(
            key: ValueKey('map-menu-${a.key}'),
            value: i,
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: Text(
                    a.key,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w900),
                  ),
                ),
                Text(a.label, style: heavy(13.5, weight: FontWeight.w700)),
              ],
            ),
          ),
      ],
    );
    if (picked != null && mounted) actions[picked].run();
  }

  MapScene _scene() {
    final store = c.store;
    final people = <MapPerson>[];
    final me = c.player.pos;
    if (me.y < 1.5) {
      people.add(
        MapPerson(
          x: me.x,
          z: me.z,
          look: store.profile.look,
          shirt: mapColor(store.profile.color),
          facing: c.player.seat != null ? c.player.facing : _myFacing,
          walking: c.player.moving,
          sitting: c.player.seat != null,
          me: true,
        ),
      );
    }
    for (final p in store.peers.values) {
      if (p.id == store.you || !store.onMyFloor(p)) continue;
      final pose = store.poses[p.id];
      final (x, y, z) = pose != null ? (pose.x, pose.y, pose.z) : (p.x, p.y, p.z);
      if (y > 1.5) continue;
      people.add(
        MapPerson(
          x: x,
          z: z,
          look: p.look,
          shirt: mapColor(p.color),
          name: p.name,
          facing: pose?.rotY ?? p.rotY,
          walking: pose?.moving ?? p.moving,
          sitting: p.seat != null,
        ),
      );
    }
    final plan = c.plan;
    for (final w in store.workers.values) {
      final desk = plan.byId[w.deskId];
      if (desk == null) continue;
      // Board agents stand behind their kiosks; everyone else sits at a desk.
      final (sx, sz) = desk.station != null ? deskPoint(desk, 0, Kiosk.stand) : (deskSeat(desk).x, deskSeat(desk).z);
      people.add(
        MapPerson(
          x: sx,
          z: sz,
          look: lookFromSeed(w.id),
          shirt: mapColor(w.color),
          facing: desk.rotY + math.pi,
          sitting: desk.station == null,
          status: mapStatus(w.status),
        ),
      );
    }
    // A board agent nobody has asked anything yet waits at its kiosk all the same, as in 3D.
    for (final k in plan.stations) {
      if (store.workerAtDesk(k.id) != null) continue;
      final (sx, sz) = deskPoint(k, 0, Kiosk.stand);
      final agent = stationAgent[k.station!]!;
      people.add(
        MapPerson(x: sx, z: sz, look: lookFromSeed(k.id), shirt: mapColor(agent.color), status: MapStatus.idle),
      );
    }
    final dog = c.dog.root;
    final h = _hover;
    return MapScene(
      people: people,
      heading: c.heading2d,
      dog: dog.visible && dog.position.y < 1.5 ? (x: dog.position.x, z: dog.position.z) : null,
      signs: [for (final g in _signs()) (x: g.x, z: g.z, color: g.color)],
      hover: h == null ? null : _hoverOf(h),
      labels: [
        ..._labels(h),
        for (final g in _signs()) MapLabel(x: g.x, z: g.z - 0.2, text: '🪧 ${g.text}', id: -1),
      ],
      t: _t,
    );
  }

  /// Where [it] is drawn on the office's plan; on a map of its own, the plan has no such shapes.
  Rect? _objectOf(Interactable it) => c.inOffice ? objectOf(it) : null;

  /// Things whose tag is what their hint calls them (a board agent, the castle's herald).
  static bool _titled(InteractKind k) => k == InteractKind.station || k == InteractKind.herald;

  /// The signs hung over this floor's desks (in the office: its own plan's), where each hangs (over
  /// the desk's far side, as in 3D) and what it says.
  List<({double x, double z, Color color, String text})> _signs() {
    if (!c.inOffice) return const [];
    final plan = c.store.floorPlan;
    return [
      for (final MapEntry(key: id, value: label) in plan.labels.entries)
        if (deskById[id] case final d? when deskBuilt(d, plan.wing))
          (x: d.x, z: d.z - (d.rotY == 0 ? 1 : -1) * 0.55, color: mapColor(label.color), text: label.text),
    ];
  }

  /// A name tag over everything you can use but the desks and seats; the one under the mouse opened
  /// up with what its hint says and what a click does.
  List<MapLabel> _labels(Interactable? hover) {
    final its = c.interactables;
    // One tag a thing, even with several spots to use it from (the meeting room's): the first.
    final picked = <(int, String, double, double, bool)>[];
    for (var i = 0; i < its.length; i++) {
      final it = its[i];
      if (it.off || (it.y ?? 0) > 1) continue;
      final name = labelOf(it.kind) ?? (_titled(it.kind) ? c.titleFor(it) : null);
      if (name == null || name.isEmpty) continue;
      final o = _objectOf(it);
      final (x, z) = o != null ? (o.center.dx, o.top) : (it.x, it.z - 0.3);
      if (picked.any((p) => p.$2 == name && (p.$3 - x).abs() + (p.$4 - z).abs() < 12)) continue;
      picked.add((i, name, x, z, false));
    }
    // Each worker's tag, over its head (and its bubble): its name and how it's doing. It stands for
    // the worker's desk, so hovering it says what the desk's hint says, and a click opens it.
    final deskIndex = {
      for (var i = 0; i < its.length; i++)
        if (its[i].kind == InteractKind.desk && its[i].deskId != null) its[i].deskId!: i,
    };
    for (final w in c.store.workers.values) {
      final desk = c.plan.byId[w.deskId];
      if (desk == null || desk.station != null) continue; // the board agents have their kiosk's tag
      final seat = deskSeat(desk);
      final st = mapStatus(w.status);
      final bubble = st == MapStatus.needsInput || st == MapStatus.done || st == MapStatus.working;
      // North of its desk, over its head (and bubble); south of it, under its feet, clear of the desk.
      final south = seat.z > desk.z;
      picked.add((
        deskIndex[w.deskId] ?? -1,
        '${workerEmoji(st)} ${w.name}',
        seat.x,
        south ? seat.z + 0.1 : seat.z - (bubble ? 2.85 : 1.95),
        south,
      ));
    }
    // The hovered thing opens its tag, or the tag standing for it.
    var open = -1;
    if (hover != null) {
      final hi = its.indexOf(hover);
      final name = labelOf(hover.kind) ?? (_titled(hover.kind) ? c.titleFor(hover) : null);
      for (final p in picked) {
        if (p.$1 == hi || (p.$2 == name && (p.$3 - hover.x).abs() + (p.$4 - hover.z).abs() < 14)) open = p.$1;
      }
    }
    return [
      for (final (i, name, x, z, below) in picked)
        if (i != open || i < 0)
          MapLabel(x: x, z: z, text: name, id: i, below: below)
        else
          _openLabel(its[i], name, x, z, i, below: below),
    ];
  }

  MapLabel _openLabel(Interactable it, String name, double x, double z, int id, {bool below = false}) {
    final parts = c.hintFor2d(it);
    final detail = [
      for (final p in parts)
        switch (p) {
          HintTitle(:final text) => text,
          HintAside(:final text) => text,
          HintCost(:final text) => text,
          HintKey() => null,
        },
    ].nonNulls.toList();
    final key = parts.whereType<HintKey>().firstOrNull;
    final walk = OfficeController.kWalkToUse.contains(it.kind);
    return MapLabel(
      x: x,
      z: z,
      text: name,
      id: id,
      below: below,
      detail: detail.isEmpty ? [name] : detail,
      action: key == null ? null : '🖱 ${walk ? 'Walk over: ' : ''}${key.label}',
    );
  }

  MapHover _hoverOf(Interactable it) {
    final o = _objectOf(it);
    if (o == null) return MapHover(x: it.x, z: it.z, radius: it.radius, title: _title(it));
    return MapHover(
      x: o.center.dx,
      z: o.center.dy,
      radius: math.min(1.6, math.max(o.width, o.height) / 2 + 0.3),
      title: _title(it),
    );
  }

  /// The tooltip: a worker's name at its desk, else what its hint calls it.
  String _title(Interactable it) {
    if (it.kind == InteractKind.desk && it.deskId != null) {
      final w = c.store.workerAtDesk(it.deskId!);
      if (w != null) return '${w.name} · ${w.activity ?? w.status.wire}';
    }
    return c.titleFor(it);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _size = box.biggest;
      return Stack(
        children: [
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _pointing,
              builder: (context, pointing, child) => MouseRegion(
                cursor: pointing ? SystemMouseCursors.click : SystemMouseCursors.basic,
                onHover: (e) => _mouse = e.localPosition,
                // The browser's own right-click menu stays off over the map (it has its own).
                onEnter: (_) => kIsWeb ? unawaited(BrowserContextMenu.disableContextMenu()) : null,
                onExit: (_) {
                  _mouse = null;
                  if (kIsWeb) unawaited(BrowserContextMenu.enableContextMenu());
                },
                child: child,
              ),
              child: Listener(
                onPointerDown: (e) {
                  if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
                    return unawaited(_menu(e.localPosition, e.position));
                  }
                  if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
                  _pressAt = e.localPosition;
                  _dragging = false;
                },
                onPointerMove: (e) {
                  final at = _pressAt;
                  if (at == null) return;
                  if (!_dragging && (e.localPosition - at).distance > 6 && _zoom > 1) _dragging = true;
                  if (_dragging) _panBy(e.localDelta);
                },
                onPointerUp: (e) {
                  final at = _pressAt;
                  _pressAt = null;
                  if (at != null && !_dragging) _click(e.localPosition);
                  _dragging = false;
                },
                onPointerCancel: (_) => _pressAt = null,
                onPointerSignal: _signal,
                // The Mac's trackpad: pinch to zoom, two fingers to move the map.
                onPointerPanZoomStart: (_) => _pinch = 1,
                onPointerPanZoomUpdate: (e) {
                  if (ModalStack.instance.open) return;
                  if (e.scale != _pinch) {
                    _zoomAt(e.localPosition, e.scale / _pinch);
                    _pinch = e.scale;
                  }
                  _panBy(e.localPanDelta);
                },
                child: CustomPaint(size: Size.infinite, painter: _painter),
              ),
            ),
          ),
          // Outside the map's own pointer handling, so pressing a button doesn't also walk you there.
          Positioned(
            right: 14,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ZoomBar(
                onIn: () => _zoomAt(_middle, 1.5),
                onOut: () => _zoomAt(_middle, 1 / 1.5),
                onMe: _followMe,
                onAll: _wholeFloor,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The emoji on a worker's tag for how it's doing.
String workerEmoji(MapStatus s) => switch (s) {
  MapStatus.working => '⌨️',
  MapStatus.needsInput => '❗',
  MapStatus.done => '✅',
  MapStatus.idle => '💬',
  MapStatus.starting => '⏳',
  MapStatus.off => '💤',
};

/// The name tag over each kind of thing on the map (desks, seats and pictures go without).
String? labelOf(InteractKind k) => switch (k) {
  InteractKind.issues => '📌 Issues',
  InteractKind.pulls => '🔀 Pull requests',
  InteractKind.services => '🌐 Services',
  InteractKind.queue => '📋 Task queue',
  InteractKind.tv => '📺 TV',
  InteractKind.coffee => '☕ Coffee',
  InteractKind.smoke => '🚬 Ashtray',
  InteractKind.elevator => '🛗 Elevator',
  InteractKind.gong => '🎉 Gong',
  InteractKind.jukebox => '🎵 Jukebox',
  InteractKind.whiteboard => '📝 Whiteboard',
  InteractKind.cabinet => '🕹️ Arcade',
  InteractKind.meeting => '🤝 Meeting room',
  InteractKind.golf => '⛳ Golf',
  InteractKind.ball => '🏀 Ball',
  InteractKind.bookshelf => '📚 Bookshelf',
  InteractKind.expand => '🚧 Room to grow',
  InteractKind.ladder => '🪜 Ladder',
  InteractKind.pole => '🚒 Fire pole',
  _ => null,
};

/// How far in the map zooms.
const double kMaxZoom = 4;

/// The map's zoom buttons, down its right side.
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({required this.onIn, required this.onOut, required this.onMe, required this.onAll});
  final VoidCallback onIn, onOut, onMe, onAll;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Swatch.paper,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Swatch.ink, width: 2),
      boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (key, icon, tip, tap) in [
          ('in', Icons.add_rounded, 'Zoom in (pinch, or ⌘ and scroll)', onIn),
          ('out', Icons.remove_rounded, 'Zoom out', onOut),
          ('me', Icons.my_location_rounded, 'Follow me', onMe),
          ('all', Icons.zoom_out_map_rounded, 'The whole floor', onAll),
        ])
          Tooltip(
            message: tip,
            child: InkWell(
              key: ValueKey('map-zoom-$key'),
              borderRadius: BorderRadius.circular(10),
              onTap: tap,
              child: SizedBox(width: 34, height: 34, child: Icon(icon, size: 20, color: Swatch.ink)),
            ),
          ),
      ],
    ),
  );
}

/// Where the thing you use is on the floor (x across, z down; meters), for the ones you stand back
/// from to use: clicking the thing itself on the map uses it too. Null for the rest.
Rect? objectOf(Interactable it) {
  Rect at(double x, double z, double w, double d) => Rect.fromCenter(center: Offset(x, z), width: w, height: d);
  Rect board(BoardDef b) => Rect.fromLTRB(b.x - b.width / 2, Floor.minZ, b.x + b.width / 2, Floor.minZ + 0.5);
  return switch (it.kind) {
    InteractKind.issues => board(Boards.issues),
    InteractKind.pulls => board(Boards.pulls),
    InteractKind.services => board(Boards.services),
    InteractKind.queue => board(Boards.queue),
    InteractKind.whiteboard => at(Whiteboard.x, Whiteboard.z, Whiteboard.width, 0.8),
    InteractKind.gong => Rect.fromLTRB(Gong.x - Gong.width / 2, Floor.minZ, Gong.x + Gong.width / 2, Floor.minZ + 1.2),
    InteractKind.cabinet => at(Cabinet.x, Cabinet.z, Cabinet.width, Cabinet.depth),
    InteractKind.jukebox => at(Jukebox.x, Jukebox.z, 0.8, 1.0),
    InteractKind.elevator => Rect.fromLTRB(
      Elevator.x - Elevator.width / 2,
      Floor.minZ,
      Elevator.x + Elevator.width / 2,
      elevatorFront,
    ),
    InteractKind.tv => Rect.fromLTRB(Tv.x - 0.6, Tv.z - 1.6, Tv.x, Tv.z + 1.6),
    InteractKind.bookshelf => Rect.fromLTRB(Bookshelf.x - 1, Bookshelf.z - 0.4, Bookshelf.x + 1, Floor.maxZ),
    _ => null,
  };
}

/// A worker's status as the map's bubble shows it.
MapStatus mapStatus(WorkerStatus s) => switch (s) {
  WorkerStatus.starting => MapStatus.starting,
  WorkerStatus.idle => MapStatus.idle,
  WorkerStatus.working => MapStatus.working,
  WorkerStatus.needsInput => MapStatus.needsInput,
  WorkerStatus.done => MapStatus.done,
  WorkerStatus.exited || WorkerStatus.offline => MapStatus.off,
};
