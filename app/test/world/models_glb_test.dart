import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_office/world/kitchen.dart' show kitchenColors;
import 'package:agent_office/world/models.dart';
import 'package:agent_office/world/office/props.dart';
import 'package:flutter_test/flutter_test.dart';

// Every .glb the office loads (world/models.dart) has the nodes, materials, bones and clips the code looks
// for. This takes the place of upstream's tests/*-model.test.ts: it reads each file's JSON chunk.

class Glb {
  Glb(this.json);

  factory Glb.read(ModelName m) {
    final b = File(m.asset).readAsBytesSync();
    final d = ByteData.sublistView(b);
    expect(d.getUint32(0, Endian.little), 0x46546C67, reason: '${m.file}.glb is a glTF binary');
    final len = d.getUint32(12, Endian.little);
    expect(d.getUint32(16, Endian.little), 0x4E4F534A, reason: 'its first chunk is JSON');
    return Glb(jsonDecode(utf8.decode(b.sublist(20, 20 + len))) as Map<String, dynamic>);
  }

  final Map<String, dynamic> json;

  List<Map<String, dynamic>> _list(String key) => [
    for (final e in (json[key] as List? ?? const [])) e as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> get nodes => _list('nodes');
  Set<String> get nodeNames => {for (final n in nodes) n['name'] as String};
  Set<String> get materials => {for (final m in _list('materials')) m['name'] as String};
  Set<String> get clips => {for (final a in _list('animations')) a['name'] as String};
  List<String> get roots => [
    for (final i in (_list('scenes').first['nodes'] as List)) nodes[i as int]['name'] as String,
  ];
  Map<String, dynamic> node(String name) => nodes.firstWhere((n) => n['name'] == name);
  List<String> childrenOf(String name) => [
    for (final i in (node(name)['children'] as List? ?? const [])) nodes[i as int]['name'] as String,
  ];

  /// The highest any of [name]'s own mesh reaches, in its own space.
  double meshTop(String name) {
    final mesh = (json['meshes'] as List)[node(name)['mesh'] as int] as Map<String, dynamic>;
    var top = double.negativeInfinity;
    for (final p in mesh['primitives'] as List) {
      final acc = (json['accessors'] as List)[(p as Map)['attributes']['POSITION'] as int] as Map;
      top = top > (acc['max'] as List)[1] ? top : ((acc['max'] as List)[1] as num).toDouble();
    }
    return top;
  }

  Set<String> get extensions => {for (final e in (json['extensionsRequired'] as List? ?? const [])) e as String};
}

void main() {
  test('every model is listed as an asset and has nothing the importer would need an extension for', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/models/'));
    for (final m in ModelName.values) {
      expect(File(m.asset).existsSync(), isTrue, reason: m.asset);
      expect(Glb.read(m).extensions, isEmpty, reason: m.file);
    }
    // Only the furniture is loaded before the office is built; the dogs come when a floor has one.
    expect(
      [
        for (final m in ModelName.values)
          if (m.preload) m.file,
      ],
      ['desk_props', 'kitchen', 'lounge', 'plants'],
    );
  });

  test('the kitchen: the counter, the machine and the fridge, each painted by name', () {
    final g = Glb.read(ModelName.kitchen);
    expect(g.roots.toSet(), {'counter', 'coffee_machine', 'fridge'});
    expect(g.materials.difference({...kitchenColors.keys, 'Glow'}), isEmpty);
    // Facing +z: turned round against the south wall, the machine ends up at x -15.7, the fridge at -11.3.
    expect((g.node('coffee_machine')['translation'] as List)[0], closeTo(1.2, 1e-6));
    expect((g.node('fridge')['translation'] as List)[0], closeTo(-3.2, 1e-6));
  });

  test('the plants: a pot for each species with its leaves hung under it', () {
    final g = Glb.read(ModelName.plants);
    for (final s in PlantSpecies.values) {
      expect(g.roots, contains(s.part));
      expect(g.childrenOf(s.part), contains('${s.part}_leaves'));
    }
    expect(g.materials.difference(plantColors.keys.toSet()), isEmpty);
  });

  test('the lounge: the sofa, a pillow, a pouf and the coffee table at their old sizes', () {
    final g = Glb.read(ModelName.lounge);
    expect(g.roots.toSet(), {'sofa', 'pillow', 'pouf', 'coffee_table'});
    expect(g.materials.difference({...loungeColors.keys, 'Cloth'}), isEmpty);
    expect(g.meshTop('pouf'), closeTo(0.42, 0.03));
    expect(g.meshTop('coffee_table'), closeTo(0.46, 0.02));
  });

  test('the desk props: a mug and the arrangements of books', () {
    final g = Glb.read(ModelName.deskProps);
    expect(g.roots.toSet(), {'mug', ...deskBookArrangements});
    expect(g.materials.difference({...deskPropColors.keys, 'Mug'}), isEmpty);
    expect(g.meshTop('mug'), lessThan(0.16));
  });

  test('every breed of dog has the same bones, sockets, materials and clips', () {
    final bones = [
      'root', 'hips', 'spine', 'chest', 'neck', 'head', 'jaw', 'eye_L', 'eye_R', //
      'tail_1', 'tail_2', 'tail_3',
      for (final s in ['L', 'R']) ...[
        'front_upper_$s', 'front_lower_$s', 'front_paw_$s', //
        'back_upper_$s', 'back_lower_$s', 'back_paw_$s', 'ear_$s', 'ear_tip_$s',
      ],
    ];
    const sockets = ['socket_head', 'socket_back', 'socket_nose', 'socket_neck'];
    const clips = {'stand', 'walk', 'run', 'wag', 'sniff', 'sit', 'bark', 'lie', 'nap'};
    const materials = {'Fur', 'Light', 'Ear', 'Ink', 'Shine', 'Nose', 'Tongue', 'Collar', 'Tag'};
    for (final m in ModelName.values.where((m) => m.file.startsWith('dog-'))) {
      final g = Glb.read(m);
      expect(g.nodeNames, containsAll([...bones, ...sockets]), reason: m.file);
      expect(g.clips, clips, reason: m.file);
      expect(g.materials, materials, reason: m.file);
      expect(g.nodes.where((n) => n.containsKey('skin')), hasLength(1), reason: '${m.file}: one skinned mesh');
    }
  });
}
