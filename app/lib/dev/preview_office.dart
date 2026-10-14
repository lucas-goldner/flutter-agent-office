// A preview of the office building on its own, for screenshots while porting it.
//
//   ?view=overview|spawn|lounge|loft|street   a preset camera, or
//   ?cam=x,y,z&at=x,y,z&fov=degrees          a camera of your own (office coordinates, as the TS).
//   &beanbags=1   brings every bean bag out;  &look=2  paints floor palette 2;
//   &elevator=1   opens the elevator;          &juke=1  plays the jukebox.
//   &roof=1       the rooftop bar instead, &dj=seconds into the DJ's set, &dark=0-1 how dark it is.
//   &dog=corgi[,act[,coat]]  the office dog of that breed in the lounge, doing that (stand, sit, lie, nap,
//                 sniff, wag, bark, walk), in that coat; &costume=halloween|christmas dresses it up.
//   &models=0     the code-built furniture instead of the models made in Blender.
//   &map=castle   a map of its own instead (castle, station), lit by its own mood; &day=0-1 how light it is.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/dog.dart';
import 'package:office_shared/floorplan.dart' show DeskLabel;
import 'package:office_shared/protocol.dart' show HolidayTheme;
import 'package:office_shared/floors.dart';
import 'package:office_shared/layout.dart' as lay;
import 'package:office_shared/layout.dart' show deskBuilt;

import '../ui/theme.dart';
import '../world/labels.dart';
import '../audio/dnb_score.dart';
import '../audio/sound_model.dart' show DogSounds;
import '../world/dog.dart';
import '../world/models.dart' show Models;
import '../world/office/office.dart';

import 'package:office_shared/maps/maps.dart' show planOf;

import '../world/styles.dart';
import '../world/world.dart';
import '../world/rooftop.dart';
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
  'colliders': [
    for (final c in o.colliders)
      [_r(c.minX), _r(c.maxX), _r(c.minZ), _r(c.maxZ), _r(c.top), c.bottom == null ? null : _r(c.bottom!)],
  ],
  'interactables': [
    for (final i in o.interactables)
      [i.kind.name, _r(i.x), _r(i.z), i.y == null ? null : _r(i.y!), _r(i.radius), i.deskId ?? i.seatId, i.off],
  ],
  'fixtures': [
    for (final f in o.fixtures()) [f.wall.wire, _r(f.u0), _r(f.u1), _r(f.y0), _r(f.y1)],
  ],
  'lamps': o.night.lamps.length,
  'halos': o.night.halos.length,
  'bulbs': o.night.bulbs.length,
});

class _Quiet implements DogSounds {
  @override
  void bark(double x, double z, int times) {}

  @override
  void yip(double x, double z) {}
}

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
  Rooftop? roof;
  World? map;
  Dog? dog;
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
      // The models made in Blender (&models=0 builds the code-built stand-ins instead).
      if (q['models'] != '0') await Models.instance.preload();
      scene.toneMapping = ToneMappingMode.linear;
      final sw = Stopwatch()..start();
      final o = buildOffice(labels: labels);
      debugPrint(
        'office built in ${sw.elapsedMilliseconds} ms: ${o.colliders.length} colliders, ${o.interactables.length} interactables',
      );
      scene.add(
        Node(name: 'mirror')
          ..localTransform = vm.Matrix4.diagonal3Values(1, 1, -1)
          ..add(o.group),
      );
      o.setProjectName('agent-office');
      if (q['beanbags'] == '1') o.setBeanbags({for (final b in lay.beanbags) b.id});
      if (q['look'] != null) o.setLook(floorPalettes[int.parse(q['look']!)]);
      if (q['elevator'] == '1') o.elevator.setOpen(true);
      if (q['juke'] == '1') o.jukebox.show(true, 'Lo-fi beats to code to');
      if (q['dump'] == '1') debugPrint('DUMP ${_dump(o)}');
      // &wing=1|2 builds the back office out that many rows, with a sign or two over the desks; &level=i,n
      // stands the office on floor i of n (&wings=0,2,1 how far each one's built out).
      final wing = int.tryParse(q['wing'] ?? '') ?? 0;
      if (wing > 0) {
        o.setWing(wing);
        o.signs.set({
          'desk-1': const DeskLabel(text: 'Operations', color: '#ffd166', by: 'Ada', at: 0),
          'desk-9': const DeskLabel(text: 'Code cleanup', color: '#118ab2', by: 'Ada', at: 0),
        }, (d) => deskBuilt(d, wing));
      }
      final level = q['level']?.split(',').map(int.parse).toList();
      if (level != null && level.length == 2) {
        o.setLevel(level[0], level[1], q['wings']?.split(',').map(int.parse).toList() ?? const []);
      }
      if (q['roof'] == '1') {
        final r = roof = buildRooftop(o.night, labels);
        o.group.visible = false;
        (scene.root.children.first).add(r.group);
        debugPrint('rooftop built: ${r.colliders.length} colliders, ${r.interactables.length} interactables');
      }
      final id = q['map'];
      final build = id == null ? null : worldBuilders[planOf(id).style];
      if (id != null && build != null) {
        final sw2 = Stopwatch()..start();
        final w = map = build(planOf(id), labels);
        debugPrint(
          '$id built in ${sw2.elapsedMilliseconds} ms: ${w.colliders.length} colliders, ${w.interactables.length} interactables',
        );
        o.group.visible = false;
        w.setProjectName('agent-office');
        if (q['look'] != null) w.setLook(floorPalettes[int.parse(q['look']!)]);
        (scene.root.children.first).add(w.group);
      }
      final d = q['dog']?.split(',');
      if (d != null) {
        final walking = d.length > 1 && d[1] == 'walk';
        final act = DogAct.values.where((a) => d.length > 1 && a.name == d[1]).firstOrNull ?? DogAct.stand;
        final pup = dog = Dog(_Quiet(), (_) => false, labels, now: () => t * 1000);
        (scene.root.children.first).add(pup.root);
        pup.sync(
          DogState(
            name: 'Biscuit',
            coat: d.length > 2 ? int.parse(d[2]) : 0,
            breed: dogBreed(d[0]),
            path: walking ? const [(9.0, 2.0), (16.0, 2.0)] : const [(12.0, 2.0)],
            speed: walking ? 1.3 : 0,
            elapsed: 0,
            act: act,
            face: math.pi / 2,
          ),
          0,
        );
        final c = q['costume'];
        if (c != null) pup.setCostume(HolidayTheme.values.byName(c));
      }
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
    dog?.update(dt);
    final q = Uri.base.queryParameters;
    final w = map;
    if (w != null) {
      w.update(t, dt, [vm.Vector3(eye.x, eye.y, -eye.z)]);
      final mood = w.mood;
      if (mood != null) {
        Toon.light.officeOn = 0;
        mood((
          light: Toon.light,
          fog: scene.fog,
          daylight: double.tryParse(q['day'] ?? '') ?? 1,
          t: t,
          eye: vm.Vector3(eye.x, eye.y, -eye.z),
        ));
        scene.fog
          ..enabled = true
          ..mode = FogMode.linear;
        Toon.updateLight();
      }
    }
    roof?.update(
      t,
      dt,
      djFrame(t + (double.tryParse(q['dj'] ?? '') ?? 0)),
      RoofEnv(dark: double.tryParse(q['dark'] ?? '') ?? 0.3, motion: true),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: ColoredBox(color: map?.ownSky == true ? const Color(0xFF000000) : Swatch.sky)),
      if (office != null) ...[
        Positioned.fill(
          child: SceneView(scene, camera: camera, onTick: _tick),
        ),
        Positioned.fill(
          child: LabelLayer(hub: labels, camera: () => camera),
        ),
      ],
    ],
  );
}
