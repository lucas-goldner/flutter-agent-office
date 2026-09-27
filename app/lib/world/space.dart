// Office space and engine space. The office's coordinates are three.js's (right-handed, +y up),
// ported one for one from the old client; flutter_scene is left-handed. Everything in the office
// hangs under [officeRoot], which mirrors z (as flutter_scene's own glTF importer does), so office
// code keeps the old numbers. Only what talks to the engine directly (the camera, raycasts) goes
// through [toEngine] / [fromEngine].

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The node everything in the office hangs under.
Node officeRoot({String name = 'office-space'}) =>
    Node(name: name, localTransform: vm.Matrix4.diagonal3Values(1, 1, -1));

/// An office-space point or direction in engine space (and back: the flip is its own inverse).
vm.Vector3 toEngine(vm.Vector3 v) => vm.Vector3(v.x, v.y, -v.z);
vm.Vector3 fromEngine(vm.Vector3 v) => vm.Vector3(v.x, v.y, -v.z);
