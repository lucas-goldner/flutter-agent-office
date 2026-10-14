// The office telescope up on the boss's loft, overlooking the worker floor (features/telescope): E
// looks through it. The view is the telescope's, narrow and magnified; the mouse (or a drag) aims it a
// little either way, and Esc, E or F (or the Exit button) takes you away from it again.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:vector_math/vector_math.dart' as vm;

import '../world/space.dart';

/// Just beyond the objective lens and the loft's corner post: from the eyepiece both pieces of
/// foreground geometry fill the narrow field of view, while this still reads as the telescope's sightline.
final vm.Vector3 telescopeEye = vm.Vector3(8.45, 3.95, 7.75);
final vm.Vector3 _target = vm.Vector3(-3.5, 0.75, -1.5);

/// The field of view through it, in degrees.
const double telescopeFov = 16;
const double _lookSpeed = 0.0015;
const double _yawRange = 0.42;
const double _minPitch = -0.5;
const double _maxPitch = 0.08;

/// Looking through the loft's telescope: where it points, and the camera it gives.
class TelescopeView {
  TelescopeView({required this.onEnter, required this.onExit}) {
    final d = _target - telescopeEye;
    // The camera looks down its -z, the way three.js's lookAt turns it: yaw about y, then pitch.
    baseYaw = math.atan2(-d.x, -d.z);
    _basePitch = math.asin(d.y / d.length);
  }

  final VoidCallback onEnter;
  final VoidCallback onExit;

  /// Whether you're looking through it (the page hides the HUD and shows the eyepiece).
  final ValueNotifier<bool> showing = ValueNotifier(false);
  bool get active => showing.value;

  late final double baseYaw;
  late final double _basePitch;
  double yaw = 0;
  double pitch = 0;

  /// Up to the eyepiece. False when you're there already.
  bool enter() {
    if (active) return false;
    yaw = baseYaw;
    pitch = _basePitch;
    showing.value = true;
    onEnter();
    return true;
  }

  /// Away from it. False when you weren't looking through it.
  bool exit() {
    if (!active) return false;
    showing.value = false;
    onExit();
    return true;
  }

  /// The mouse moved [dx], [dy] pixels: the telescope swings round, only so far either way.
  void look(double dx, double dy) {
    if (!active) return;
    yaw = (yaw - dx * _lookSpeed).clamp(baseYaw - _yawRange, baseYaw + _yawRange);
    pitch = (pitch - dy * _lookSpeed).clamp(_minPitch, _maxPitch);
  }

  /// Which way it looks (office space).
  vm.Vector3 get forward =>
      vm.Vector3(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch));

  /// The camera to draw with: [camera] as it is, unless you're at the eyepiece.
  PerspectiveCamera update(PerspectiveCamera camera) {
    if (!active) return camera;
    return PerspectiveCamera(
      fovRadiansY: telescopeFov * math.pi / 180,
      position: toEngine(telescopeEye),
      target: toEngine(telescopeEye + forward),
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
  }
}
