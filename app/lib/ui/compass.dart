// Arrows at the edge of the screen for each worker waiting on you that's out of view, pointing the
// way to turn to see it: red for needs input, green for done. Plus the chip that counts them
// ("🙋 2 waiting · ✅ 1 done  N"), which does what N does. A port of ui/compass.ts.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'theme.dart';

/// A worker waiting on you: who, what for, and where its head is (engine space).
class Bearing {
  const Bearing({required this.id, required this.name, required this.status, required this.at});
  final String id;
  final String name;
  final WorkerStatus status;
  final vm.Vector3 at;
}

/// From a mark's middle to the edge of the screen, or of the HUD it sits beside, with room for its tip (px).
const double kCompassMargin = 46;

/// How far apart marks on one edge keep: a dial and its name down a side, a name's width along the top or bottom (px).
const double _spacingSide = 56, _spacingAcross = 110;

enum CompassEdge { left, right, top, bottom }

/// Where a mark goes: its middle, the way its pin points (radians, screen space), and its edge.
class PlacedMark {
  PlacedMark(this.id, this.x, this.y, this.angle, this.edge);
  final String id;
  double x;
  double y;
  final double angle;
  final CompassEdge edge;
}

/// Where [at] is from the middle of the screen: null while it's in view already; otherwise the
/// screen-space way to it (right and down are positive). One behind you points to the side you'd
/// turn to, or straight down when it's right behind.
Offset? bearingFrom(PerspectiveCamera camera, vm.Vector3 at, Size size) {
  final eye = camera.position;
  final forward = (camera.target - eye)..normalize();
  final v = at - eye;
  final ahead = v.dot(forward);
  final cx = size.width / 2, cy = size.height / 2;
  if (ahead > 0.01) {
    final s = camera.worldToScreen(at, size);
    if (s == null) return null;
    if (s.dx >= 0 && s.dx <= size.width && s.dy >= 0 && s.dy <= size.height) return null;
    return Offset(s.dx - cx, s.dy - cy);
  }
  // Mirror it through the camera's plane to in front: the same way sideways and up, then project.
  final lateral = v - forward * ahead;
  if (lateral.length < 0.05) return const Offset(0, 1);
  final mirrored = eye + lateral + forward * math.max(0.5, -ahead);
  final s = camera.worldToScreen(mirrored, size);
  if (s == null) return const Offset(0, 1);
  final d = Offset(s.dx - cx, s.dy - cy);
  return d.distance < 0.5 ? const Offset(0, 1) : d;
}

/// Pushes each way out from the middle of [size] to the edge of [box], then spreads out marks that
/// land on top of each other along their edge (workers at desks side by side).
List<PlacedMark> placeMarks(List<(String id, Offset dir)> ways, Size size, Rect box) {
  final cx = size.width / 2, cy = size.height / 2;
  final placed = <PlacedMark>[];
  for (final (id, d) in ways) {
    var s = double.infinity;
    if (d.dx > 0) s = (box.right - cx) / d.dx;
    if (d.dx < 0) s = (box.left - cx) / d.dx;
    if (d.dy > 0) s = math.min(s, (box.bottom - cy) / d.dy);
    if (d.dy < 0) s = math.min(s, (box.top - cy) / d.dy);
    if (!s.isFinite) continue;
    final x = cx + d.dx * s, y = cy + d.dy * s;
    final edge = x <= box.left + 1
        ? CompassEdge.left
        : x >= box.right - 1
        ? CompassEdge.right
        : y <= box.top + 1
        ? CompassEdge.top
        : CompassEdge.bottom;
    placed.add(PlacedMark(id, x, y, math.atan2(d.dy, d.dx), edge));
  }
  for (final edge in CompassEdge.values) {
    final side = edge == CompassEdge.left || edge == CompassEdge.right;
    double get(PlacedMark p) => side ? p.y : p.x;
    void set(PlacedMark p, double v) => side ? p.y = v : p.x = v;
    final gap = side ? _spacingSide : _spacingAcross;
    final row = placed.where((p) => p.edge == edge).toList()..sort((a, b) => get(a).compareTo(get(b)));
    for (var i = 1; i < row.length; i++) {
      set(row[i], math.max(get(row[i]), get(row[i - 1]) + gap));
    }
    // Pushed off the end: back the lot up.
    final over = row.isEmpty ? 0.0 : get(row.last) - (side ? box.bottom : box.right);
    if (over > 0) {
      for (final p in row) {
        set(p, math.max(side ? box.top : box.left, get(p) - over));
      }
    }
  }
  return placed;
}

/// Where the marks can go: clear of the top bar, the side panels, and the hint and chat along the
/// bottom, and never so tight they crowd the middle of the screen.
Rect compassBox(Size size) => Rect.fromLTRB(
  kCompassMargin,
  math.min(kCompassMargin + 64, size.height / 2 - 60),
  math.max(size.width - kCompassMargin, size.width / 2 + 60),
  math.max(size.height - 130, size.height / 2 + 60),
);

/// The arrows, re-placed every frame from [bearings] and the [camera].
class CompassLayer extends StatefulWidget {
  const CompassLayer({
    super.key,
    required this.camera,
    required this.bearings,
    required this.waiting,
    required this.onNext,
    this.chip = true,
  });

  final PerspectiveCamera Function() camera;

  /// Shows the waiting chip under the top bar. Off where the ☰ HUD's dock has it (its 'waiting' action).
  final bool chip;

  /// The waiting workers to point to this frame (none while a window is open or you're riding the elevator).
  final List<Bearing> Function() bearings;

  /// The chip's text ("🙋 2 waiting · ✅ 1 done", empty for none) and whether all of them are done.
  final ValueNotifier<(String, bool)> waiting;
  final VoidCallback onNext;

  @override
  State<CompassLayer> createState() => _CompassLayerState();
}

class _CompassLayerState extends State<CompassLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final size = c.biggest;
      final cam = widget.camera();
      final bs = widget.bearings();
      final byId = {for (final b in bs) b.id: b};
      final ways = <(String, Offset)>[
        for (final b in bs)
          if (bearingFrom(cam, b.at, size) case final d?) (b.id, d),
      ];
      final marks = placeMarks(ways, size, compassBox(size));
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final m in marks)
            Positioned(
              left: m.x.roundToDouble(),
              top: m.y.roundToDouble(),
              child: IgnorePointer(
                child: _Mark(bearing: byId[m.id]!, angle: m.angle),
              ),
            ),
          if (widget.chip)
            Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: Center(
                child: _WaitingChip(waiting: widget.waiting, onTap: widget.onNext),
              ),
            ),
        ],
      );
    },
  );
}

class _Mark extends StatelessWidget {
  const _Mark({required this.bearing, required this.angle});
  final Bearing bearing;
  final double angle;

  @override
  Widget build(BuildContext context) {
    final needs = bearing.status == WorkerStatus.needsInput;
    return SizedBox(
      width: 0,
      height: 0,
      child: OverflowBox(
        minWidth: 0,
        minHeight: 0,
        maxWidth: 160,
        maxHeight: 120,
        alignment: Alignment.topLeft,
        child: Transform.translate(
          offset: const Offset(-80, -19),
          child: SizedBox(
            width: 160,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 38,
                  height: 38,
                  child: Stack(
                    children: [
                      // A pin whose point (its square corner, bottom-left at 135°) turns to face the worker.
                      Transform.rotate(
                        angle: angle - 3 * math.pi / 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: needs ? Swatch.bad : Swatch.good,
                            border: Border.all(color: Swatch.ink, width: 3),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(19),
                              topRight: Radius.circular(19),
                              bottomRight: Radius.circular(19),
                            ),
                          ),
                        ),
                      ),
                      Center(child: Text(needs ? '🙋' : '✅', style: const TextStyle(fontSize: 17, height: 1))),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  constraints: const BoxConstraints(maxWidth: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    bearing.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: heavy(11, color: Swatch.paper, weight: FontWeight.w900),
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

/// "🙋 2 waiting · ✅ 1 done  [N]": click it (or press N) to go to the one that has waited longest.
class _WaitingChip extends StatelessWidget {
  const _WaitingChip({required this.waiting, required this.onTap});
  final ValueNotifier<(String, bool)> waiting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: waiting,
    builder: (context, v, _) {
      final (text, allDone) = v;
      if (text.isEmpty) return const SizedBox.shrink();
      return Tooltip(
        message: 'Go to the worker that has waited longest on someone (N)',
        child: Semantics(
          button: true,
          child: GestureDetector(
            onTap: onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: allDone ? const Color(0xFFD8F5E3) : const Color(0xFFFFE3EA),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Swatch.ink, width: 2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(text, style: heavy(13, weight: FontWeight.w900)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        'N',
                        style: heavy(12, color: Swatch.paper, weight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
