// A preview of the characters, for checking the port by eye: build with
//   flutter build web --release --no-web-resources-cdn -t lib/dev/preview_characters.dart -o build/preview_characters
// Query: ?cam=x,y,z&at=x,y,z picks the camera; ?hands=1 looks through your own eyes at a wall
// close up (with &overlay=0 to draw the hands in the world instead of as an overlay); ?only=people,
// workers or dogs builds one row; ?t=seconds runs the animation that long before the first frame.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/avatar.dart';
import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart';
import '../ui/theme.dart';
import '../world/character.dart';
import '../audio/sound_model.dart' show DogSounds;
import '../world/dog.dart';
import '../world/geo.dart';
import '../world/hands.dart';
import '../world/labels.dart';
import '../world/toon.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Preview()));

vm.Vector3? _vec(String? s) {
  final p = s?.split(',').map(double.tryParse).toList();
  if (p == null || p.length != 3 || p.contains(null)) return null;
  return vm.Vector3(p[0]!, p[1]!, p[2]!);
}

class _Quiet implements DogSounds {
  @override
  void bark(double x, double z, int times) {}
  @override
  void yip(double x, double z) {}
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final scene = Scene();
  final hub = LabelHub();
  bool ready = false;
  late final PerspectiveCamera camera;
  final q = Uri.base.queryParameters;
  late final bool handsMode = q['hands'] == '1';
  late final bool overlay = q['overlay'] != '0';

  /// ?only=people|workers|dogs builds just that row (swiftshader is slow with everything).
  late final String? only = q['only'];
  bool show(String row) => only == null || only == row;

  /// The office's space: flutter_scene is left-handed, so the TS coordinates go under a mirror.
  final Node world = Node(name: 'world')..localTransform = vm.Matrix4.diagonal3Values(1, 1, -1);
  late final vm.Vector3 camAt;
  late final vm.Vector3 camTarget;

  final List<Person> people = [];
  Person? walker, sitter, talker, reacher;
  final List<Worker> workers = [];
  Worker? leaver;
  final List<Dog> dogs = [];
  late Hands hands;
  double t = 0;

  @override
  void initState() {
    super.initState();
    // ?cam and ?at are in office (TS) coordinates; the camera wants engine space (z negated).
    camAt = _vec(q['cam']) ?? (handsMode ? vm.Vector3(0, 1.4, 9) : vm.Vector3(0, 3.2, 11));
    camTarget = _vec(q['at']) ?? (handsMode ? vm.Vector3(0, 1.3, 7) : vm.Vector3(0, 1, 0));
    camera = PerspectiveCamera(
      fovRadiansY: 55 * math.pi / 180,
      position: vm.Vector3(camAt.x, camAt.y, -camAt.z),
      target: vm.Vector3(camTarget.x, camTarget.y, -camTarget.z),
    );
    () async {
      await Scene.initializeStaticResources();
      await Toon.init();
      scene.toneMapping = ToneMappingMode.linear;
      _build();
      // ?t=seconds runs the animation that far before the first frame (swiftshader draws few frames).
      final warm = double.tryParse(q['t'] ?? '') ?? 2;
      for (var i = 0; i < warm / 0.05; i++) {
        _tick(Duration.zero, 0.05);
      }
      if (mounted) setState(() => ready = true);
    }();
  }

  void _build() {
    scene.add(world);
    world.add(mesh(box(40, 0.2, 30), toon(hex('#f2d7b0')), 0, -0.1, 0));
    // A wall to stand up against in the hands view.
    if (handsMode) world.add(mesh(box(6, 3, 0.2), toon(hex('#8ecae6')), 0, 1.5, 8.55));

    if (show('people')) _people();
    if (show('workers')) _workers();
    if (show('dogs')) _dogs();
    _hands();
  }

  void _people() {
    // Row 1 (z = 2): every hair style, a spread of skins, hair colours and shirts.
    const shirts = ['#ef476f', '#118ab2', '#06d6a0', '#ffd166', '#8338ec', '#ff8a5b', '#3a86ff'];
    for (var i = 0; i < hairStyles.length; i++) {
      final p = Person(hairStyles[i], shirts[i], Look(skin: i, hair: (i * 3) % hairColors.length, style: i), hub);
      p.root.position = vm.Vector3(-6 + i * 2.0, 0, 2);
      world.add(p.root);
      people.add(p);
    }
    // Row 2 (z = 5): doing things.
    Person at(String name, double x, int style, String shirt) {
      final p = Person(name, shirt, Look(skin: x.round().abs() % skinTones.length, hair: 1, style: style), hub);
      p.root.position = vm.Vector3(x, 0, 5);
      world.add(p.root);
      people.add(p);
      return p;
    }

    walker = at('walking', -5, 0, '#118ab2');
    sitter = at('sitting', -3, 1, '#ef476f');
    // Something to sit on.
    world.add(mesh(box(0.7, 0.45, 0.6), toon(hex('#6c757d')), -3, 0.225, 4.9));
    sitter!.sit(0.5);
    at('mug', -1, 2, '#06d6a0').holdMug(true);
    at('smoking', 1, 3, '#8338ec').setSmoking(true);
    talker = at('talking', 3, 4, '#ffd166');
    reacher = at('reach', 5, 5, '#ff8a5b');
  }

  void _workers() {
    // Row 3 (z = -1.5): workers in each status.
    final statuses = WorkerStatus.values;
    for (var i = 0; i < statuses.length; i++) {
      final w = Worker(statuses[i].wire, ['#d97757', '#6a994e', '#4d908e', '#bc4749'][i % 4], hub);
      w.root.position = vm.Vector3(-6 + i * 2.0, 0, -1.5);
      final s = statuses[i];
      w.setStatus(s, s == WorkerStatus.needsInput || s == WorkerStatus.done);
      if (i.isEven) w.setTask(WorkerTask(name: 'Fix the ${s.wire} flow', summary: 'Reading the logs and patching the retry loop in the queue worker'));
      world.add(w.root);
      workers.add(w);
    }
    leaver = Worker('leaving', '#d97757', hub);
    leaver!.root.position = vm.Vector3(8, 0, -1.5);
    leaver!.leave('📦 welp');
    leaver!.walking = true;
    world.add(leaver!.root);
  }

  void _dogs() {
    // Row 4 (z = -4): the dog in a few poses.
    final acts = [DogAct.stand, DogAct.sit, DogAct.lie, DogAct.nap, DogAct.bark, DogAct.wag];
    for (var i = 0; i < acts.length; i++) {
      final d = Dog(_Quiet(), (_) => false, hub);
      final x = -5 + i * 2.0;
      d.sync(DogState(name: acts[i].wire, coat: i, path: [(x, -4.0)], speed: 1, elapsed: 0, act: acts[i], face: 0.6), performanceNow() - 5000);
      world.add(d.root);
      dogs.add(d);
    }
    // One trotting to and fro.
    _trot();
  }

  void _hands() {
    hands = Hands('#118ab2', skinTones[2]);
    if (!handsMode) {
      // Seen from outside: floating in front of a camera at (7, 1.4, 4) looking -z.
      hands.place(vm.Vector3(7, 1.4, 4.4), vm.Vector3(0, 0, -1));
      hands.holdMug(true);
    } else {
      hands.place(camAt, camTarget - camAt);
      hands.holdMug(true);
      hands.setSmoking(q['smoke'] == '1');
    }
    if (!overlay || !handsMode) setLayers(hands.root, kRenderLayerDefault);
    world.add(hands.root);
  }

  Dog? trotter;
  double trotAt = 0;
  bool trotBack = false;

  void _trot() {
    trotter ??= (Dog(_Quiet(), (_) => false, hub)..root.position = vm.Vector3(7, 0, -4));
    if (trotter!.root.parent == null) world.add(trotter!.root);
    final path = trotBack ? [(9.0, -4.0), (7.0, -4.0)] : [(7.0, -4.0), (9.0, -4.0)];
    trotter!.sync(DogState(name: 'trotting', coat: 2, path: path, speed: 1.2, elapsed: 0, act: DogAct.stand), performanceNow());
    trotAt = t + 2 / 1.2 + 0.4;
    trotBack = !trotBack;
  }

  void _tick(Duration elapsed, double dt) {
    dt = dt.clamp(0, 0.1);
    t += dt;
    for (final p in people) {
      p.update(dt, t, identical(p, walker), false);
    }
    talker?.setVoiceLevel(0.08 + math.sin(t * 9).abs() * 0.1);
    if ((t % 2.0) < dt) reacher?.reach();
    if ((t % 2.0) < dt) sitter?.reach();
    for (final w in workers) {
      w.update(dt, t);
    }
    leaver?.update(dt, t);
    for (final d in dogs) {
      d.update(dt);
    }
    trotter?.update(dt);
    if (trotter != null && t > trotAt) _trot();
    hands.update(dt, t, HandsInput(yaw: 0, pitch: 0, walkPhase: t * 11, walking: false));
    if ((t % 4.0) < dt && handsMode) hands.sip();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: ColoredBox(color: Swatch.sky)),
      if (ready)
        Positioned.fill(
          child: handsMode && overlay
              ? SceneView(
                  scene,
                  onTick: _tick,
                  viewsBuilder: (_) => [
                    RenderView(camera: camera, layerMask: kRenderLayerAll & ~Hands.layer),
                    hands.overlayView(),
                  ],
                )
              : SceneView(scene, camera: camera, onTick: _tick),
        ),
      if (ready) Positioned.fill(child: LabelLayer(hub: hub, camera: () => camera)),
    ],
  );
}
