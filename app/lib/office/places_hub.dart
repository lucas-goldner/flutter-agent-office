// The places round the building, wired into the office (upstream's features/telescope, bargames,
// cars, and the desk signs and back office): the loft's telescope, darts and axes up at the rooftop
// bar, the cars in the garage, and the signs over the desks. Like RoomsHub, the controller hands it
// the keys you press, the mouse, what you aim at and the camera, and it takes what's its own.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:office_shared/bargames.dart';
import 'package:office_shared/protocol.dart' show ServerMsg;

import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../world/collider.dart';
import 'bar_games_play.dart';
import 'cars_play.dart';
import 'controller.dart';
import 'interaction.dart' show DeskKey;
import 'telescope.dart';
import 'throwing.dart';

class PlacesHub {
  PlacesHub(this.c);

  final OfficeController c;

  late final TelescopeView telescope = TelescopeView(
    onEnter: () {
      final p = c.player;
      p.enabled = false;
      p.input.clear();
      p.stopWalking();
      c.yieldMouse();
      c.staleHint();
    },
    onExit: () {
      c.player
        ..enabled = !ModalStack.instance.open
        ..input.clear();
      c.staleHint();
      if (!ModalStack.instance.open) Future(c.backToGame);
    },
  );

  /// Darts and axes at the rooftop bar.
  late final BarGamesPlay bar = BarGamesPlay(c);

  Thrower get thrower => bar.thrower;

  /// The cars in the garage.
  late final CarsPlay cars = CarsPlay(c);

  void init() {
    // A window opening takes you away from the eyepiece.
    ModalStack.instance.changes.addListener(_onModals);
    bar.init();
    cars.init();
  }

  void dispose() {
    ModalStack.instance.changes.removeListener(_onModals);
    bar.dispose();
    cars.dispose();
  }

  void _onModals() {
    if (ModalStack.instance.open) telescope.exit();
    // Drawn back when a window opened: the key never comes back up, so it's no throw.
    if (ModalStack.instance.open && thrower.doing == ThrowStage.wind) thrower.putBack();
  }

  bool _wasUp = false;

  /// Off to another floor, up to the roof or down from it: whatever you were doing here stops.
  void placeChanged() {
    telescope.exit();
    final up = c.roofHub.upTop;
    if (up && !_wasUp) bar.freshBoards();
    _wasUp = up;
  }

  /// Off in the elevator (or straight to another floor, or climbing): away from the eyepiece, back from
  /// the line, and out of the car.
  void stopAll() {
    stopOthers();
    cars.getOut(true);
  }

  /// Starting something else here (into a car): away from the eyepiece and back from the line.
  void stopOthers() {
    telescope.exit();
    thrower.stop();
  }

  /// A message from the office about one of these places.
  void onMessage(ServerMsg msg) {
    cars.onMessage(msg);
    bar.onMessage(msg);
  }

  /// Whether something here has the camera, so nothing else is aimed at and no hands cover it.
  bool get busy => telescope.active || thrower.active || cars.active;

  /// Something here has the whole screen: the HUD steps aside.
  ValueListenable<bool> get hudHidden => telescope.showing;

  /// A key (down or up) before the office's own. True when it was taken here.
  bool key(KeyEvent e) {
    // Looking through the telescope, Esc, E or F takes you away from it, and no key does anything else.
    if (telescope.active) {
      final k = e.physicalKey;
      if (e is KeyDownEvent &&
          (k == PhysicalKeyboardKey.escape || k == PhysicalKeyboardKey.keyE || k == PhysicalKeyboardKey.keyF)) {
        telescope.exit();
      }
      return true;
    }
    return cars.key(e) || bar.key(e);
  }

  /// The captured mouse moved by [dx], [dy] pixels: true when it aims something here.
  bool look(double dx, double dy) {
    if (telescope.active) {
      telescope.look(dx, dy);
      return true;
    }
    return thrower.look(dx, dy);
  }

  /// The free mouse moved by [delta] to [at] (in a view of [view] size): true when it aims something here.
  bool pointer(Offset at, Offset delta, Size view) {
    if (telescope.active) {
      telescope.look(delta.dx, delta.dy);
      return true;
    }
    if (thrower.active) return bar.pointAt(c.camera.screenPointToRay(at, view));
    return false;
  }

  /// The mouse button went down (or up) on the scene: true when it was taken here.
  bool pointerDown() {
    if (!thrower.active) return false;
    bar.pointerDown();
    return true;
  }

  bool pointerUp() {
    if (!thrower.active) return false;
    bar.pointerUp();
    return true;
  }

  /// A click on the scene: true when it was taken here.
  bool click() => telescope.active || thrower.active;

  /// E (or another key) at [it]: true when it's one of the places' things.
  bool interact(Interactable it, DeskKey key) {
    switch (it.kind) {
      case InteractKind.telescope:
        if (key == DeskKey.e) telescope.enter();
        return true;
      case InteractKind.darts || InteractKind.axe:
        if (key == DeskKey.e) bar.interact(it);
        return true;
      case InteractKind.car when it.car != null:
        if (key == DeskKey.e) cars.getIn(it.car!);
        return true;
      default:
        return false;
    }
  }

  /// What the hint says at [it], or null when it's not one of these.
  (String, List<HintPart>)? hint(Interactable it) => switch (it.kind) {
    InteractKind.telescope => (
      '',
      const [HintTitle('🔭 Office telescope'), HintAside('overlooks the worker floor'), HintKey('E', 'Look through')],
    ),
    InteractKind.darts => bar.hint(BarGame.darts),
    InteractKind.axe => bar.hint(BarGame.axe),
    InteractKind.car => cars.carHint(it),
    _ => null,
  };

  /// What the hint says whatever you look at, while something here has you (null otherwise).
  (String, List<HintPart>)? heldHint() {
    if (telescope.active) return ('telescope', const <HintPart>[]);
    if (thrower.active) return bar.throwHint();
    if (cars.active) return cars.driveHint();
    return null;
  }

  /// Every frame, once you've moved: returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, double t) {
    bar.update(dt);
    cars.tick(dt);
    camera = thrower.camera(camera, dt);
    camera = telescope.update(camera);
    // Knocked about by a crunch.
    final jolt = cars.jolt();
    if (jolt.length2 == 0) return camera;
    return PerspectiveCamera(
      fovRadiansY: camera.fovRadiansY,
      position: camera.position + jolt,
      target: camera.target + jolt * 0.5,
      up: camera.up,
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
  }
}
