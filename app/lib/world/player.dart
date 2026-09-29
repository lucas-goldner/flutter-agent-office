// You: walking, running, jumping, stairs, sitting, and the camera that follows you. A port of
// player.ts. The physics and camera maths are pure (tested in test/world/player_test.dart); keys,
// the mouse and pointer lock come in through [PlayerInput] from office_view.dart.

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart';
import 'collider.dart';
import 'drunk.dart' show drunkStagger, drunkSway;

const double kRadius = 0.32;

/// Top of your head above your feet, for walking under the loft.
const double kHeight = 1.7;

/// The tallest ledge you walk up (or down) without jumping, like a stair.
const double kStep = 0.3;
const double kWalk = 4.6;
const double kRun = 7.5;
const double kJumpV = 6.4;
const double kGravity = 18;

/// Camera height above your feet in first person (the Person's eyes).
const double kEyeHeight = 1.4;

/// The Person's hips above their feet, standing.
const double kHips = 0.42;

const double kLookSpeed = 0.0022; // radians per pixel while the pointer is locked
const double kDragLookSpeed = 0.005;

enum ViewMode { first, third }

/// What the keyboard is doing this frame, as physical keys (layout-independent, like e.code).
class PlayerInput {
  bool forward = false, back = false, left = false, right = false;
  bool run = false, jump = false;

  bool get any => forward || back || left || right || jump;

  void clear() => forward = back = left = right = run = jump = false;
}

class PlayerController {
  PlayerController(this.colliders);

  List<Collider> colliders;
  final vm.Vector3 pos = vm.Vector3.zero();
  double vy = 0;
  double facing = math.pi;
  bool moving = false;
  bool grounded = true;

  /// Heading of the camera. You look along (-sin, -cos) of it on the XZ plane.
  double camYaw = math.pi * 0.15;
  double camPitch = 0.42;
  double camDist = 7.5;

  /// First-person look up (+) / down (-).
  double lookPitch = -0.08;
  ViewMode view = ViewMode.first;

  /// Walk cycle phase, shared by the camera bob and the first-person hands.
  double walkPhase = 0;
  double _bob = 0;

  /// Eased out after a step up or down, so the camera glides up stairs instead of popping.
  double stepOffset = 0;

  /// Walking and running speed, as a multiple of normal (a coffee's buzz).
  double speedBoost = 1;
  double jumpBoost = 1;

  /// 0 (steady) to 1: how hard the view trembles after one coffee too many.
  double jitter = 0;

  /// How drunk you are (see booze.dart): the view rolls and sways, and you stagger as you walk.
  double drunk = 0;
  double _jitterT = 0;

  /// Where you're sitting, or null on your feet.
  SeatPlace? seat;

  /// You got up by walking off or jumping (not by [stand]).
  void Function()? onStand;
  bool enabled = true;
  final PlayerInput input = PlayerInput();

  /// The camera this frame: where it is and what it looks at.
  final vm.Vector3 camPos = vm.Vector3.zero();
  final vm.Vector3 camTarget = vm.Vector3.zero();

  void setView(ViewMode v) {
    if (v == view) return;
    if (v == ViewMode.first) {
      lookPitch = -0.08;
      facing = camYaw + math.pi;
    } else {
      // Start the orbit camera behind where you were looking.
      camYaw = facing - math.pi;
    }
    view = v;
    updateCamera(snap: true);
  }

  /// Mouse look: [dx], [dy] in radians.
  void look(double dx, double dy) {
    camYaw -= dx;
    lookPitch = (lookPitch - dy).clamp(-1.45, 1.45);
  }

  /// Third-person orbit by a drag of [dx], [dy] pixels.
  void orbit(double dx, double dy) {
    camYaw -= dx * 0.006;
    camPitch = (camPitch + dy * 0.004).clamp(0.05, 1.3);
  }

  void zoom(double deltaY) {
    if (view == ViewMode.third) camDist = (camDist + deltaY * 0.01).clamp(2.5, 16);
  }

  /// Sits you down in [place], facing the way it does.
  void sit(SeatPlace place) {
    seat = place;
    pos.setValues(place.x, place.y, place.z);
    vy = 0;
    grounded = true;
    moving = false;
    stepOffset = 0;
    _bob = 0;
    facing = place.rotY;
    if (view == ViewMode.first) {
      camYaw = place.rotY - math.pi;
      lookPitch = -0.08;
    }
  }

  /// Gets you up off your seat onto the floor beside it: out in front (or behind), else wherever there's room.
  void stand() {
    final s = seat;
    if (s == null) return;
    seat = null;
    final ahead = s.rotY + (s.out < 0 ? math.pi : 0);
    final d = s.out.abs();
    for (final turn in [0.0, 0.6, -0.6, 1.2, -1.2, math.pi / 2, -math.pi / 2, math.pi]) {
      final x = s.x + math.sin(ahead + turn) * d;
      final z = s.z + math.cos(ahead + turn) * d;
      if (_blocker(x, z, s.y) != null) continue;
      pos.setValues(x, s.y, z);
      return;
    }
  }

  /// How far sitting moves your hips (and eyes) from where they are standing.
  double get _lift => seat == null ? 0 : seat!.hips - kHips;

  void update(double dt) {
    dt = math.min(dt, 0.05);
    final k = input;
    if (seat != null) {
      if (!enabled || !k.any) {
        moving = false;
        facing = seat!.rotY;
        _jitterT += dt;
        updateCamera();
        return;
      }
      stand();
      onStand?.call();
    }
    var ix = 0.0, iz = 0.0;
    if (enabled) {
      if (k.forward) iz -= 1;
      if (k.back) iz += 1;
      if (k.left) ix -= 1;
      if (k.right) ix += 1;
    }
    moving = ix != 0 || iz != 0;
    if (view == ViewMode.first) facing = math.atan2(math.sin(camYaw + math.pi), math.cos(camYaw + math.pi));
    if (moving) {
      final len = math.sqrt(ix * ix + iz * iz);
      ix /= len;
      iz /= len;
      // Camera-relative: "forward" is where the camera looks.
      // Drunk, your feet wander off to one side and then the other.
      final stagger = drunkStagger(drunk, _jitterT);
      final sin = math.sin(camYaw + stagger), cos = math.cos(camYaw + stagger);
      final dx = ix * cos + iz * sin;
      final dz = -ix * sin + iz * cos;
      final speed = (k.run ? kRun : kWalk) * speedBoost;
      _tryMove(pos.x + dx * speed * dt, pos.z);
      _tryMove(pos.x, pos.z + dz * speed * dt);
      if (view == ViewMode.third) {
        final want = math.atan2(dx, dz);
        var diff = want - facing;
        diff = math.atan2(math.sin(diff), math.cos(diff));
        facing += diff * math.min(1, dt * 14);
      }
    }

    final ground = groundAt(colliders, pos.x, pos.z, pos.y);
    final jump = enabled && k.jump && grounded;
    if (jump) {
      vy = kJumpV * jumpBoost;
      grounded = false;
    } else if (grounded && pos.y > ground && pos.y - ground <= kStep + 0.02) {
      // Walking down a stair: stay on your feet rather than falling a step.
      stepOffset += pos.y - ground;
      pos.y = ground;
    }
    vy -= kGravity * dt;
    pos.y += vy * dt;
    if (pos.y <= ground) {
      pos.y = ground;
      vy = 0;
      grounded = true;
    } else if (pos.y > ground + 0.02) {
      grounded = false;
    }
    final ceiling = ceilingAt(colliders, pos.x, pos.z, pos.y);
    if (pos.y + kHeight > ceiling) {
      pos.y = math.max(ground, ceiling - kHeight);
      vy = math.min(vy, 0);
    }
    stepOffset *= math.exp(-dt * 16);
    final walking = moving && grounded;
    walkPhase += dt * (walking ? (k.run ? 14 : 11) * speedBoost : 0);
    final bob = walking ? math.sin(walkPhase).abs() * 0.035 : 0.0;
    _bob += (bob - _bob) * math.min(1, dt * 18);
    _jitterT += dt;
    updateCamera();
  }

  void updateCamera({bool snap = false}) {
    if (view == ViewMode.first) {
      camPos.setValues(pos.x, pos.y + kEyeHeight + _bob + stepOffset + _lift, pos.z);
      final (shakenYaw, shakenPitch) = _shaken(camYaw, lookPitch);
      final sway = drunkSway(drunk, _jitterT);
      final yaw = shakenYaw + sway.yaw, pitch = shakenPitch + sway.pitch;
      // three.js's camera with rotation (pitch, yaw, 0) in YXZ order looks down -z turned by yaw.
      final dir = vm.Vector3(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch));
      camTarget.setFrom(camPos + dir);
      return;
    }
    final target = vm.Vector3(pos.x, pos.y + stepOffset + _lift + 1.3, pos.z);
    final off = vm.Vector3(
      math.sin(camYaw) * math.cos(camPitch),
      math.sin(camPitch),
      math.cos(camYaw) * math.cos(camPitch),
    )..scale(camDist);
    final cam = target + off;
    // Keep the camera on your side of the outside walls, so they never block the view: inside the
    // room while you're in the office, out of the building while you're outside or on the balcony.
    // And under the loft, its roof or the garage ceiling.
    const m = 0.4;
    final indoors = pos.y > -slab - 0.5 && pos.x > Floor.minX && pos.x < Floor.maxX && pos.z > Floor.minZ && pos.z < Floor.maxZ;
    if (indoors) {
      cam.x = cam.x.clamp(Floor.minX + m, Floor.maxX - m);
      cam.z = cam.z.clamp(Floor.minZ + m, Floor.maxZ - m);
    }
    final floorY = groundAt(colliders, pos.x, pos.z, pos.y);
    final roof = ceilingAt(colliders, cam.x, cam.z, floorY) - 0.3;
    cam.y = cam.y.clamp(floorY + 0.6, math.max(floorY + 0.6, math.min(floorY + 3.5, roof)));
    // Down on the street, stay under the garage ceiling so its edge never cuts across the view.
    if (pos.y < -slab - 1) cam.y = math.min(cam.y, math.max(floorY + 0.6, -slab - 0.3));
    // How far you are out past each outside wall (west, east, north, south), and how far inside them the camera is.
    const e = wallT + m;
    final out = [Floor.minX - wallT - pos.x, pos.x - Floor.maxX - wallT, Floor.minZ - wallT - pos.z, pos.z - Floor.maxZ - wallT];
    final side = out.indexOf(out.reduce(math.max));
    final camIn = [cam.x - (Floor.minX - e), Floor.maxX + e - cam.x, cam.z - (Floor.minZ - e), Floor.maxZ + e - cam.z].reduce(math.min) > 0;
    // Outside, back the camera out through the wall you're standing beyond.
    if (!indoors && out[side] > 0 && camIn && (cam.y > -slab || side == 0 || side == 2)) {
      switch (side) {
        case 0:
          cam.x = Floor.minX - e;
        case 1:
          cam.x = Floor.maxX + e;
        case 2:
          cam.z = Floor.minZ - e;
        default:
          cam.z = Floor.maxZ + e;
      }
    }
    if (snap) {
      camPos.setFrom(cam);
    } else {
      camPos.setFrom(camPos + (cam - camPos) * 0.25);
    }
    camTarget.setFrom(target);
    if (jitter > 0) {
      final (yaw, pitch) = _shaken(0, 0);
      camTarget.add(vm.Vector3(yaw, pitch, 0) * camDist);
    }
    if (drunk > 0) {
      final sway = drunkSway(drunk, _jitterT);
      camTarget.add(vm.Vector3(sway.yaw, sway.pitch, 0) * camDist);
    }
  }

  /// Drunk, the view rolls this far (radians) about where you look: for the camera's up.
  double get roll => drunkSway(drunk, _jitterT).roll;

  /// The jitters: the view trembles a little, on top of wherever you're looking.
  (double, double) _shaken(double yaw, double pitch) {
    if (jitter <= 0) return (yaw, pitch);
    final a = jitter * 0.01, t = _jitterT;
    return (
      yaw + a * (math.sin(t * 89 + 2) + 0.6 * math.sin(t * 157)),
      pitch + a * (math.sin(t * 71) + 0.6 * math.sin(t * 131 + 1)),
    );
  }

  /// Unit vector the character is facing, on the XZ plane.
  vm.Vector2 forward() => vm.Vector2(math.sin(facing), math.cos(facing));

  /// What stands in your way at (x, z) with your feet at [y], or null.
  Collider? _blocker(double x, double z, double y, {bool allowEscape = false}) {
    Collider? hit;
    for (final c in colliders) {
      // Stood on top of it, or passing beneath it.
      if (y >= c.top - 0.05 || y + kHeight <= (c.bottom ?? 0)) continue;
      // A spawn or height change can leave the body overlapping a solid. Only allow escape toward
      // its near side, never through it to the far side.
      if (allowEscape && touches(c, pos.x, pos.z, kRadius)) {
        if (_escapes(c, pos.x, pos.z, x, z)) continue;
      } else if (!touches(c, x, z, kRadius)) {
        continue;
      }
      if (hit == null || c.top > hit.top) hit = c;
    }
    return hit;
  }

  void _tryMove(double x, double z) {
    final hit = _blocker(x, z, pos.y, allowEscape: true);
    if (hit == null) {
      pos.x = x;
      pos.z = z;
      return;
    }
    // A stair: step up onto it if there's room there.
    final up = hit.top - pos.y;
    if (grounded && up <= kStep && _blocker(x, z, hit.top) == null && pos.y + kHeight + up <= ceilingAt(colliders, x, z, pos.y)) {
      pos.setValues(x, hit.top, z);
      stepOffset -= up;
      return;
    }
    // Use the free part of this axis's step instead of throwing it all away. The other axis can
    // then slide along the surface, even on slower frames.
    final dx = x - pos.x, dz = z - pos.z;
    var free = 0.0, blocked = 1.0;
    for (var i = 0; i < 12; i++) {
      final fraction = (free + blocked) / 2;
      if (_blocker(pos.x + dx * fraction, pos.z + dz * fraction, pos.y, allowEscape: true) != null) {
        blocked = fraction;
      } else {
        free = fraction;
      }
    }
    pos.x += dx * free;
    pos.z += dz * free;
  }
}

/// Whether the whole axis step moves out of an existing overlap.
bool _escapes(Collider c, double fromX, double fromZ, double x, double z) {
  if (_penetration(c, x, z) >= _penetration(c, fromX, fromZ) - 1e-8) return false;
  final nx = fromX - fromX.clamp(c.minX, c.maxX);
  final nz = fromZ - fromZ.clamp(c.minZ, c.maxZ);
  if (nx != 0 || nz != 0) return nx * (x - fromX) + nz * (z - fromZ) >= 0;
  // Inside the footprint, head toward a nearest face. An endpoint with less overlap alone is
  // insufficient: a long step could cross a thin wall first.
  final nearest = [fromX - c.minX, c.maxX - fromX, fromZ - c.minZ, c.maxZ - fromZ].reduce(math.min);
  return (nearest == fromX - c.minX && x < fromX) ||
      (nearest == c.maxX - fromX && x > fromX) ||
      (nearest == fromZ - c.minZ && z < fromZ) ||
      (nearest == c.maxZ - fromZ && z > fromZ);
}

/// Signed overlap depth, including when the center is inside the footprint.
double _penetration(Collider c, double x, double z) {
  final dx = [c.minX - x, 0.0, x - c.maxX].reduce(math.max);
  final dz = [c.minZ - z, 0.0, z - c.maxZ].reduce(math.max);
  if (dx != 0 || dz != 0) return kRadius - math.sqrt(dx * dx + dz * dz);
  return kRadius + [x - c.minX, c.maxX - x, z - c.minZ, c.maxZ - z].reduce(math.min);
}

/// Whether a body of radius [r] at (x, z) overlaps the collider's footprint.
bool touches(Collider c, double x, double z, double r) {
  final nx = x.clamp(c.minX, c.maxX);
  final nz = z.clamp(c.minZ, c.maxZ);
  return (x - nx) * (x - nx) + (z - nz) * (z - nz) < r * r;
}

/// The floor under someone standing at (x, z) with their feet at [y]: the highest top they're on or above, else the street.
double groundAt(List<Collider> colliders, double x, double z, double y) {
  var g = streetY;
  for (final c in colliders) {
    if (c.top > 50 || y < c.top - 0.1 || c.top <= g) continue;
    if (touches(c, x, z, kRadius)) g = c.top;
  }
  return g;
}

/// The underside of whatever is overhead at (x, z) for feet at [y] (the loft, its roof), or infinity.
double ceilingAt(List<Collider> colliders, double x, double z, double y) {
  var top = double.infinity;
  for (final c in colliders) {
    final b = c.bottom ?? 0;
    if (b <= y + 0.1 || b >= top) continue;
    if (touches(c, x, z, kRadius)) top = b;
  }
  return top;
}
