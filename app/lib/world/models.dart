// The things in the world modelled in Blender rather than built in code: a port of world/models.ts
// (#177, #186). Each .glb in assets/models/ is exported by a script in upstream's blender/scripts/
// (blender/README.md there has the conventions they keep); add it to [ModelName] by name.
// `preload` ones are loaded before the world is built, for builders that take theirs with [model] and
// [piece]; the rest load the first time [loadModel] asks for them (a floor's dog is only ever one breed).
//
// Handedness: flutter_scene's GLB importer hangs the model under a root that flips z (glTF is
// right-handed, the engine left-handed). The office already hangs under a root that does that flip
// (world/space.dart), and its numbers are three.js's, the same space a .glb is in. So a model's own
// nodes are taken out from under the importer's root: placed under the office they come out the way
// three.js placed them, not mirrored twice.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_scene/scene.dart';

import 'toon.dart';

enum ModelName {
  dogPup('dog-pup'),
  dogCorgi('dog-corgi'),
  dogDachshund('dog-dachshund'),
  dogPug('dog-pug'),
  dogShiba('dog-shiba'),
  dogPomeranian('dog-pomeranian'),
  deskProps('desk_props', preload: true),
  kitchen('kitchen', preload: true),
  lounge('lounge', preload: true),
  plants('plants', preload: true);

  const ModelName(this.file, {this.preload = false});

  /// Its name in assets/models/, without the .glb.
  final String file;

  /// Loaded before the world is built (see [Models.preload]).
  final bool preload;

  String get asset => 'assets/models/$file.glb';
}

/// One copy of a model to pose and dress on its own.
class Model {
  Model(this.scene, this.clips);

  /// This copy's nodes and bones, sharing the geometry with every other copy: the model's top-level
  /// nodes, out from under the importer's flipped root (see the top of this file).
  final Node scene;

  /// Its animations, shared: a clip only reads them.
  final List<Animation> clips;

  Animation? clip(String name) => clips.where((a) => a.name == name).firstOrNull;
}

/// How far the model files have got: how many have been asked for so far, and how many of those are
/// done (loaded, or given up on). Counted by file rather than by byte.
typedef ModelsProgress = ({int asked, int done});

/// Reads a model's file and imports it; the importer's root comes back, flipped (see the top).
typedef ModelLoader = Future<Node> Function(ModelName name);

Future<Node> _loadAsset(ModelName name) async {
  final data = await rootBundle.load(name.asset);
  return Node.fromGlbBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

class Models {
  Models({ModelLoader? loader}) : _loader = loader ?? _loadAsset;

  /// The office's models.
  static Models instance = Models();

  final ModelLoader _loader;
  final Map<ModelName, Future<Node>> _loading = {};
  final Map<ModelName, Node> _loaded = {};
  int _asked = 0, _done = 0;
  final Set<void Function(ModelsProgress)> _watchers = {};

  ModelsProgress get progress => (asked: _asked, done: _done);

  /// Calls [fn] with the files' progress now, and again each time a file is asked for or is done. The
  /// loading screen fills its bar with it. Returns a function that stops the calls.
  VoidCallback onProgress(void Function(ModelsProgress) fn) {
    _watchers.add(fn);
    fn(progress);
    return () => _watchers.remove(fn);
  }

  void _tell() {
    for (final fn in [..._watchers]) {
      fn(progress);
    }
  }

  /// Each file loads once, the first time something asks for it.
  Future<Node> _fetch(ModelName name) {
    final had = _loading[name];
    if (had != null) return had;
    final p = _loader(name).then((root) => _loaded[name] = root);
    _loading[name] = p;
    _asked++;
    _tell();
    // Done either way: one that failed still fails for whoever asked for it.
    void done() {
      _done++;
      _tell();
    }

    p.then((_) => done(), onError: (Object _) => done());
    return p;
  }

  static Model _copy(Node root) {
    final scene = Node(name: 'model');
    for (final c in root.children) {
      // Node.clone binds a copy's skin to its own bones.
      scene.add(c.clone());
    }
    return Model(scene, root.parsedAnimations);
  }

  /// A copy of a model, once it has loaded.
  Future<Model> load(ModelName name) async => _copy(await _fetch(name));

  /// Loads every `preload` model, so the world can be built with them straight away (see [model]). One
  /// that doesn't load is logged and left out: whatever it was for goes missing, the office still opens.
  Future<void> preload() => Future.wait([
    for (final name in ModelName.values)
      if (name.preload)
        _fetch(name).then<void>((_) {}, onError: (Object e) => debugPrint("${name.file}.glb didn't load: $e")),
  ]);

  /// A copy of a `preload` model (see [preload]), or null if it couldn't be loaded.
  Model? model(ModelName name) {
    final root = _loaded[name];
    return root == null ? null : _copy(root);
  }

  /// Is [name] loaded?
  bool has(ModelName name) => _loaded.containsKey(name);

  /// A painted copy of one piece of a `preload` model, the node called [part] in it, for a model that
  /// holds several things placed each on their own (a plant of each species, the lounge's sofa and its
  /// table). [paint] gives the material for each name, as for [paintModel]. If the model didn't load,
  /// or has no such piece, an empty node: the office opens without it.
  Node piece(ModelName name, String part, Material Function(String name) paint) {
    final found = _loaded[name]?.getChildByName(part);
    if (found == null) return Node(name: part);
    final copy = found.clone();
    paintModel(copy, paint);
    return copy;
  }
}

/// The office's models: see [Models.load].
Future<Model> loadModel(ModelName name) => Models.instance.load(name);

/// See [Models.model].
Model? model(ModelName name) => Models.instance.model(name);

/// See [Models.piece].
Node piece(ModelName name, String part, Material Function(String name) paint) =>
    Models.instance.piece(name, part, paint);

/// Every node under [root] (and [root]), depth first.
Iterable<Node> walk(Node root) sync* {
  yield root;
  for (final c in root.children) {
    yield* walk(c);
  }
}

/// Paints a model the office's way: every material it came with is only a name (see blender/README.md),
/// and [paint] gives the material to use for each.
void paintModel(Node root, Material Function(String name) paint) {
  for (final n in walk(root)) {
    final mesh = n.mesh;
    if (mesh == null) continue;
    for (final p in mesh.primitives) {
      p.material = paint(p.material.name);
    }
  }
}

/// The usual paint: a toon material of the palette's colour ('#rrggbb') for each name. A name the
/// palette has no colour for comes out magenta, so a part the script and the code disagree on shows.
Material Function(String name) palette(Map<String, String> colors) =>
    (name) => toon(hex(colors[name] ?? '#ff00ff'));
