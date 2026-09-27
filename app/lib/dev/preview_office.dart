// A preview of the office building on its own, for screenshots while porting it.
//
//   ?view=overview|spawn|lounge|loft|street   a preset camera, or
//   ?cam=x,y,z&at=x,y,z&fov=degrees          a camera of your own (office coordinates, as the TS).
//   &beanbags=1   brings every bean bag out;  &look=2  paints floor palette 2;
//   &elevator=1   opens the elevator;          &juke=1  plays the jukebox.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/floors.dart';
import 'package:office_shared/layout.dart' as lay;
import '../ui/theme.dart';
import '../world/labels.dart';
import '../world/office/office.dart';
import '../world/toon.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: PreviewOffice()));

const _views = {
  'overview': ('-5,24,12', '-5,0,-1', 50.0),
  'spawn': ('8,1.4,7', '3,1.4,2', 70.0),
  'lounge': ('7.5,2.4,6', '16,1.4,-1.5', 65.0),
  'loft': ('3.5,1.5,1.5', '13,4,10', 65.0),
  'street': ('0,-2,30', '0,0,0', 60.0),
};

/// A point given in the office's (three.js, right-handed) coordinates, in the engine's space:
/// flutter_scene is left-handed, so the office hangs under a root mirrored in z.
vm.Vector3 _v(String s) {
  final p = s.split(',').map(double.parse).toList();
  return vm.Vector3(p[0], p[1], -p[2]);
}

double _r(double n) => (n * 1e6).roundToDouble() / 1e6;

/// The office's colliders, interactables and fixtures as JSON, to diff against the TS build.
String _dump(Office o) => jsonEncode({
  'colliders': [for (final c in o.colliders) [_r(c.minX), _r(c.maxX), _r(c.minZ), _r(c.maxZ), _r(c.top), c.bottom == null ? null : _r(c.bottom!)]],
  'interactables': [
    for (final i in o.interactables) [i.kind.name, _r(i.x), _r(i.z), i.y == null ? null : _r(i.y!), _r(i.radius), i.deskId ?? i.seatId, i.off],
  ],
  'fixtures': [for (final f in o.fixtures()) [f.wall.wire, _r(f.u0), _r(f.u1), _r(f.y0), _r(f.y1)]],
  'lamps': o.night.lamps.length,
  'halos': o.night.halos.length,
  'bulbs': o.night.bulbs.length,
});

class PreviewOffice extends StatefulWidget {
  const PreviewOffice({super.key});

  @override
  State<PreviewOffice> createState() => _PreviewOfficeState();
}

class _PreviewOfficeState extends State<PreviewOffice> {
  final scene = Scene();
  final labels = LabelHub();
  late final PerspectiveCamera camera;
  Office? office;
  double t = 0;

  @override
  void initState() {
    super.initState();
    final q = Uri.base.queryParameters;
    final preset = _views[q['view'] ?? 'overview'] ?? _views['overview']!;
    camera = PerspectiveCamera(
      position: _v(q['cam'] ?? preset.$1),
      target: _v(q['at'] ?? preset.$2),
      fovRadiansY: double.parse(q['fov'] ?? '${preset.$3}') * vm.degrees2Radians,
      fovNear: 0.1,
      fovFar: 400,
    );
    () async {
      await Scene.initializeStaticResources();
      await Toon.init();
      scene.toneMapping = ToneMappingMode.linear;
      final sw = Stopwatch()..start();
      final o = buildOffice(labels: labels);
      debugPrint('office built in ${sw.elapsedMilliseconds} ms: ${o.colliders.length} colliders, ${o.interactables.length} interactables');
      scene.add(Node(name: 'mirror')..localTransform = vm.Matrix4.diagonal3Values(1, 1, -1)..add(o.group));
      o.setProjectName('agent-office');
      if (q['beanbags'] == '1') o.setBeanbags({for (final b in lay.beanbags) b.id});
      if (q['look'] != null) o.setLook(floorPalettes[int.parse(q['look']!)]);
      if (q['elevator'] == '1') o.elevator.setOpen(true);
      if (q['juke'] == '1') o.jukebox.show(true, 'Lo-fi beats to code to');
      if (q['dump'] == '1') debugPrint('DUMP ${_dump(o)}');
      if (mounted) setState(() => office = o);
    }();
  }

  void _tick(Duration elapsed, double dt) {
    final o = office;
    if (o == null) return;
    t += dt;
    final eye = camera.position;
    o.update(t, dt, [vm.Vector3(eye.x, eye.y, -eye.z)]);
    o.jukebox.update(t, dt, 0.5);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: ColoredBox(color: Swatch.sky)),
      if (office != null) ...[
        Positioned.fill(child: SceneView(scene, camera: camera, onTick: _tick)),
        Positioned.fill(child: LabelLayer(hub: labels, camera: () => camera)),
      ],
    ],
  );
}
