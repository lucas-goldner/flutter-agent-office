// Things that float over the office and face you: name tags, task cards, chat bubbles, the dog's
// barks, the jukebox's notes. The old client drew these as three.js sprites from 2D canvases; here
// they're Flutter widgets laid over the SceneView at each anchor's projected position, so text
// stays crisp at every distance and nothing has to be re-uploaded as a texture.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// One floating label. Change [child] or [visible] and it updates on the next frame.
class WorldLabel {
  WorldLabel({
    required this.anchor,
    required this.child,
    vm.Vector3? offset,
    this.alignment = Alignment.bottomCenter,
    this.maxDistance = 30,
    this.scaleWithDistance = true,
    this.priority = 0,
  }) : offset = offset ?? vm.Vector3.zero();

  /// The node it hangs over, and how far above/around that node's origin (world units).
  Node anchor;
  vm.Vector3 offset;

  /// What sits on the point: bottomCenter puts the label's bottom-middle on it (like the old
  /// sprites, whose centre was (0.5, 0)).
  Alignment alignment;
  Widget child;
  bool visible = true;

  /// Hidden beyond this many metres from the camera.
  double maxDistance;

  /// Shrinks with distance like a sprite did (full size at 4 m), down to half size.
  bool scaleWithDistance;

  /// Drawn over lower priorities when they overlap.
  int priority;

  /// Where it was drawn last frame, for hit testing and tests.
  Offset? screen;

  /// Something solid stands between it and the camera (checked a few labels a frame).
  bool hidden = false;
}

/// Every label in the office. The world adds and removes them; [LabelLayer] draws them.
class LabelHub {
  final List<WorldLabel> _labels = [];

  List<WorldLabel> get labels => _labels;

  WorldLabel add(WorldLabel l) {
    _labels.add(l);
    return l;
  }

  void remove(WorldLabel? l) {
    if (l != null) _labels.remove(l);
  }
}

/// Lays the hub's labels over a SceneView of the same size, re-projecting every frame.
class LabelLayer extends StatefulWidget {
  const LabelLayer({super.key, required this.hub, required this.camera, this.blocked, this.checksPerFrame = 6});

  final LabelHub hub;

  /// Whether something solid is in the way from the camera to [point] (engine space), for hiding
  /// labels behind walls the way the old depth-tested sprites were. Null: labels always show.
  final bool Function(vm.Vector3 point)? blocked;

  /// How many labels a frame get their line of sight checked, round-robin.
  final int checksPerFrame;

  /// The camera the scene is drawn with this frame.
  final Camera Function() camera;

  @override
  State<LabelLayer> createState() => _LabelLayerState();
}

class _LabelLayerState extends State<LabelLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _next = 0;

  void _checkSight() {
    final blocked = widget.blocked;
    final labels = widget.hub.labels;
    if (blocked == null || labels.isEmpty) return;
    for (var i = 0; i < widget.checksPerFrame && i < labels.length; i++) {
      final l = labels[_next++ % labels.length];
      if (!l.visible) continue;
      l.hidden = blocked(l.anchor.globalTransform.transform3(l.offset.clone()));
    }
  }

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
    builder: (context, constraints) {
      final size = constraints.biggest;
      final cam = widget.camera();
      final eye = cam.position;
      _checkSight();
      final placed = <(double, WorldLabel, Offset, double)>[];
      for (final l in widget.hub.labels) {
        l.screen = null;
        if (!l.visible || l.hidden || !_shown(l.anchor)) continue;
        final p = l.anchor.globalTransform.transform3(l.offset.clone());
        final dist = p.distanceTo(eye);
        if (dist > l.maxDistance) continue;
        final s = cam.worldToScreen(p, size);
        if (s == null || s.dx < -200 || s.dy < -200 || s.dx > size.width + 200 || s.dy > size.height + 200) continue;
        l.screen = s;
        final scale = l.scaleWithDistance ? (4 / dist).clamp(0.5, 1.0) : 1.0;
        placed.add((dist, l, s, scale));
      }
      // Far ones first, so near ones draw over them; priority wins over distance.
      placed.sort((a, b) {
        final p = a.$2.priority.compareTo(b.$2.priority);
        return p != 0 ? p : b.$1.compareTo(a.$1);
      });
      return IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (_, l, s, scale) in placed)
              Positioned(
                left: s.dx,
                top: s.dy,
                child: FractionalTranslation(
                  translation: Offset(-(l.alignment.x + 1) / 2, -(l.alignment.y + 1) / 2),
                  child: Transform.scale(
                    scale: scale,
                    alignment: l.alignment,
                    child: l.child,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  /// Hidden with any hidden ancestor.
  bool _shown(Node n) {
    for (Node? p = n; p != null; p = p.parent) {
      if (!p.visible) return false;
    }
    return true;
  }
}
