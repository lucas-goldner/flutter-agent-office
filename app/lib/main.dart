import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() => runApp(const MaterialApp(home: Spike()));

class Spike extends StatefulWidget {
  const Spike({super.key});
  @override
  State<Spike> createState() => _SpikeState();
}

class _SpikeState extends State<Spike> {
  final scene = Scene();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      final m = PhysicallyBasedMaterial()..baseColorFactor = vm.Vector4(1, 0.5, 0.3, 1);
      scene.add(Node(mesh: Mesh(CuboidGeometry(vm.Vector3(1, 1, 1)), m)));
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) => ready
      ? SceneView(scene, camera: PerspectiveCamera(position: vm.Vector3(2, 2, -4)))
      : const SizedBox.expand();
}
