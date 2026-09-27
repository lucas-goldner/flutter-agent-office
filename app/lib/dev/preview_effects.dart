// Preview: confetti and smoke on a floor, for screenshots.

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../world/confetti.dart';
import '../world/smoke.dart';
import '../world/space.dart';
import '../world/toon.dart';

void main() => runApp(const MaterialApp(home: _Preview()));

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final scene = Scene();
  late Confetti confetti;
  late Smoke smoke;
  bool ready = false;
  double since = 0;
  final cam = vm.Vector3(0, 2.2, 6), at = vm.Vector3(0, 1, 0);

  @override
  void initState() {
    super.initState();
    () async {
      await Scene.initializeStaticResources();
      await Toon.init();
      scene.toneMapping = ToneMappingMode.linear;
      final root = officeRoot();
      scene.add(root);
      root.add(mesh(CuboidGeometry(vm.Vector3(10, 0.2, 10)), toon(hex('#f2d7b0')), 0, -0.1, 0));
      root.add(mesh(roundedBox(2.2, 0.78, 1.1), toon(hex('#f7f3ea')), 1.5, 0.39, 0));
      confetti = Confetti((x, z, y) => (x - 1.5).abs() < 1.1 && z.abs() < 0.55 ? 0.78 : 0);
      smoke = Smoke();
      root.add(confetti.node);
      root.add(smoke.node);
      confetti.burst(0.5, 2.3, 0, 400);
      if (mounted) setState(() => ready = true);
    }();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFBFE3FF),
    child: ready
        ? SceneView(
            scene,
            camera: PerspectiveCamera(position: toEngine(cam), target: toEngine(at)),
            onTick: (elapsed, dt) {
              since += dt;
              if (since > 0.15) {
                since = 0;
                smoke.wisp(vm.Vector3(-1.5, 1.2, 0));
              }
              if (elapsed.inMilliseconds % 3000 < 20) {
                smoke.exhale(vm.Vector3(-1.2, 1.5, 0), vm.Vector3(1, 0, 0));
                confetti.burst(0.5, 2.3, 0, 300);
              }
              confetti.update(dt);
              smoke.update(dt, cam, at);
            },
          )
        : const SizedBox.expand(),
  );
}
