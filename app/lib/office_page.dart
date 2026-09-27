// The office itself: the 3D floor with the HUD over it. (Being built: see FLUTTER_WEB_PLAN.md.)

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'ui/theme.dart';
import 'world/toon.dart';

class OfficePage extends StatefulWidget {
  const OfficePage({super.key});

  @override
  State<OfficePage> createState() => _OfficePageState();
}

class _OfficePageState extends State<OfficePage> {
  final scene = Scene();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    () async {
      await Scene.initializeStaticResources();
      await Toon.init();
      scene.toneMapping = ToneMappingMode.linear;
      scene.add(mesh(CuboidGeometry(vm.Vector3(12, 0.2, 8)), toon(hex('#f2d7b0')), 0, -0.1, 0));
      if (mounted) setState(() => ready = true);
    }();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: ColoredBox(color: Swatch.sky)),
      if (ready)
        Positioned.fill(
          child: SceneView(scene, camera: PerspectiveCamera(position: vm.Vector3(4, 5, 8), target: vm.Vector3(0, 0.5, -1))),
        ),
    ],
  );
}
