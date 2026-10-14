// The cars in the garage (features/cars/index.ts): getting in (behind the wheel, or beside whoever's
// driving), driving, the horn, laps of the scenic loop, and a car shoving you out of its way. Placing
// you anywhere gets you out first (see the controller's _placeAt).

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:office_shared/garage.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/scenic.dart' show placeAt;
import 'package:vector_math/vector_math.dart' as vm;

import '../audio/sound.dart' show Engine, TossSound;
import '../interop/browser.dart' show onPageHide;
import '../interop/portable.dart' show storageGet, storageSet;
import '../state/store.dart' show nowMs;
import '../ui/hud_parts.dart';
import '../ui/modal.dart' show ToastKind, clip, toast;
import '../world/collider.dart';
import '../world/office/fleet.dart';
import 'controller.dart';
import 'driving.dart';
import 'laps.dart';

const _lapKey = 'agent-office.bestLap';

class CarsPlay {
  CarsPlay(this.c);

  final OfficeController c;

  Fleet get fleet => c.office.fleet;

  /// Behind the wheel of one of the garage's cars.
  late final Driver driver = Driver(
    c.player,
    fleet,
    DriveHooks(
      moved: (car, p) =>
          c.net.send(CarDriveCmd(car: car, x: p.x, z: p.z, rotY: p.rotY, speed: p.speed, steer: p.steer)),
      bump: (at, speed) {
        c.sound.crash(at.x, c.player.street + 0.5, at.z, speed);
        shake(math.min(0.8, speed / 15));
      },
    ),
  );

  /// car.enter and car.leave of yours the office hasn't answered yet: until it has, you're where you say you are.
  int _pending = 0;

  /// Laps of the scenic loop you've driven, and your fastest, kept in this browser.
  final LapTimer laps = LapTimer(() {
    try {
      final best = double.tryParse(storageGet(_lapKey) ?? '');
      return best != null && best > 0 ? best : null;
    } catch (_) {
      return null;
    }
  }());

  /// How hard the camera's knocked about (a crunch, a shove), dying away.
  double _thud = 0;
  final math.Random _rnd = math.Random();
  double _honkedAt = 0;
  double _shovedAt = 0;

  /// Who was sitting in a car last time round, to stand them up when they get out.
  final Set<String> _riders = {};
  void Function()? _offPageHide;

  void init() {
    c.store.cars.changed.addListener(_carsChanged);
    // Closing the tab mid-drive: the car stops right where you left it, not where the office last heard it was.
    _offPageHide = onPageHide(() {
      final p = driver.driving ? driver.pose : null;
      if (p != null) {
        c.net.send(CarDriveCmd(car: driver.car!, x: p.x, z: p.z, rotY: p.rotY, speed: 0, steer: p.steer));
      }
    });
  }

  void dispose() {
    c.store.cars.changed.removeListener(_carsChanged);
    _offPageHide?.call();
  }

  bool get active => driver.active;

  /// Knocks the camera about, [k] hard (0–1).
  void shake(double k) {
    if (_calm) return;
    _thud = math.max(_thud, k);
  }

  /// Where car [i] is, at about the height of its horn.
  vm.Vector3 carAt(int i) {
    final p = i >= 0 && i < fleet.views.length ? fleet.views[i].pose : null;
    return vm.Vector3(p?.x ?? cars[i].x, c.player.street + 0.6, p?.z ?? cars[i].z);
  }

  /// E at a car: behind the wheel if nobody's driving it, else beside whoever is.
  void getIn(int i) {
    final slots = c.store.cars.cars;
    if (c.travelling || c.climber.active || driver.active || i < 0 || i >= slots.length || i >= cars.length) return;
    final s = slots[i];
    final def = cars[i];
    if (c.carrying != null) return toast('🗂️ Your hands are full: put the card back first (Q)', ToastKind.warn);
    if (c.rooms.ball.holding) return toast('🏀 Put the ball down first (Q)', ToastKind.warn);
    final seat = s.driver == null
        ? CarSeat.driver
        : s.passenger == null
        ? CarSeat.passenger
        : null;
    if (seat == null) return toast('🏎️ The ${def.name} is full', ToastKind.warn);
    if (c.player.seat != null) c.standUp();
    c.places.stopOthers();
    c.stopWalkingThere();
    driver.enter(i, seat);
    c.me.sit(seatHips);
    _pending++;
    c.net.send(CarEnterCmd(i, seat));
    final at = carAt(i);
    c.sound.carDoor(at.x, at.y, at.z);
    c.staleHint();
  }

  /// E in a car: out onto your feet beside it; [anyway], even with no room there. False if you couldn't.
  bool getOut([bool anyway = false]) {
    final i = driver.car;
    if (i == null) return true;
    if (!driver.leave(anyway)) {
      toast('🚪 No room to open the door here', ToastKind.warn);
      return false;
    }
    _leftCar(i);
    return true;
  }

  /// Out of the car wherever you are: something else is moving you (to another floor, a desk).
  void dropCar() {
    final i = driver.car;
    if (i == null) return;
    driver.drop();
    _leftCar(i);
  }

  void _leftCar(int i) {
    c.me.sit(null);
    _pending++;
    c.net.send(const CarLeaveCmd());
    final at = carAt(i);
    c.sound.carDoor(at.x, at.y, at.z);
    c.staleHint();
  }

  /// H in a car: its horn, for everyone on the floor.
  void honk() {
    final i = driver.car;
    final now = nowMs();
    if (i == null || now - _honkedAt < 300) return;
    _honkedAt = now;
    final at = carAt(i);
    c.sound.honk(at.x, at.y, at.z, cars[i].kind == CarKind.lambo);
    c.net.send(const CarHonkCmd());
  }

  void _lapDone(double time) {
    final done = laps.done;
    final best = done?.best ?? false;
    if (best) {
      try {
        storageSet(_lapKey, '$time');
      } catch (_) {
        // a private window: it's only for this visit then
      }
      final p = c.player.pos;
      c.sound.toss(TossSound.cheer, p.x, p.y + 1, p.z);
    } else {
      c.sound.arcade('clear');
    }
    toast(
      best
          ? '🏁 Lap of the scenic loop: ${lapTime(time)}, your best yet!'
          : '🏁 Lap of the scenic loop: ${lapTime(time)} (best ${lapTime(laps.best ?? time)})',
    );
  }

  /// In a car: E gets you out and H honks (W A S D and Space drive, see Driver); nothing else is in reach.
  bool key(KeyEvent e) {
    if (!driver.active) return false;
    final k = e.physicalKey;
    const desk = [
      PhysicalKeyboardKey.keyP,
      PhysicalKeyboardKey.keyR,
      PhysicalKeyboardKey.keyX,
      PhysicalKeyboardKey.keyB,
      PhysicalKeyboardKey.keyC,
      PhysicalKeyboardKey.keyO,
      PhysicalKeyboardKey.keyL,
    ];
    if (k != PhysicalKeyboardKey.keyE && k != PhysicalKeyboardKey.keyH && k != PhysicalKeyboardKey.keyF) {
      if (!desk.contains(k)) return false;
    }
    if (e is! KeyDownEvent) return true;
    if (k == PhysicalKeyboardKey.keyE) {
      getOut();
    } else if (k == PhysicalKeyboardKey.keyH) {
      honk();
    }
    return true;
  }

  /// Each frame, before you move: the cars first, so whoever's riding in one sits in it where it's got to.
  void tickCars(double dt, vm.Vector3 eye) {
    final st = c.store.cars;
    fleet.update(dt, st.cars, st.at, nowMs(), driver.active ? (car: driver.car!, driving: driver.driving) : null, eye);
  }

  /// Each frame, once you've moved: the lap, a car shoving you out of its way, and the engines.
  void tick(double dt) {
    final now = nowMs();
    _thud *= math.exp(-dt * 8);
    // Timing a lap of the scenic loop, behind the wheel.
    final pose = driver.pose;
    if (driver.driving && pose != null) {
      final lap = laps.update(pose.x, pose.z, now / 1000);
      if (lap != null) _lapDone(lap);
    } else {
      laps.reset();
    }
    // A car coming at you where you stand: out of its way, with a thump if it was going.
    final p = c.player;
    final here = c.inOffice && !c.roofHub.upTop;
    if (here && !driver.active && !c.travelling) {
      final hit = fleet.shove(p.pos, null);
      if (hit > 1.5 && now - _shovedAt > 600) {
        _shovedAt = now;
        c.sound.crash(p.pos.x, p.pos.y + 0.8, p.pos.z, hit / 2);
        shake(math.min(0.7, hit / 12));
      }
    }
    // The engines of the cars being driven on this floor, yours (by how hard you're on the gas) and theirs.
    final engines = <Engine>[];
    if (here) {
      for (final (i, s) in c.store.cars.cars.indexed) {
        final mine = driver.car == i && driver.driving;
        if (s.driver == null && !mine) continue;
        final at = i < fleet.views.length ? fleet.views[i].pose : null;
        final speed = at?.speed ?? s.speed;
        engines.add((
          car: i,
          x: at?.x ?? s.x,
          y: p.street + 0.5,
          z: at?.z ?? s.z,
          speed: speed,
          gas: mine ? driver.gas : math.min(1.0, speed.abs() / 10),
        ));
      }
    }
    c.sound.setEngines(engines);
  }

  /// The camera knocked about by a crunch: [camPos] moved a little, this frame.
  vm.Vector3 jolt() {
    if (_thud < 0.01) return vm.Vector3.zero();
    double r() => (_rnd.nextDouble() * 2 - 1) * _thud * 0.12;
    return vm.Vector3(r(), r(), r());
  }

  /// A message about the cars: a floor's cars snap to where they are, who's in which, and horns.
  void onMessage(ServerMsg msg) {
    switch (msg) {
      // A floor's cars where they are before anything asks if there's room to stand beside one.
      case WelcomeMsg _:
        fleet.snap(c.store.cars.cars);
        // The office let go of your seat in a car while you were away.
        _carAgain();
      case FloorEnterMsg _:
        fleet.snap(c.store.cars.cars);
      case CarHonkMsg m:
        if (m.car >= 0 && m.car < cars.length) {
          final at = carAt(m.car);
          c.sound.honk(at.x, at.y, at.z, cars[m.car].kind == CarKind.lambo);
        }
      default:
        break;
    }
  }

  /// The office said who's in which car (answering a car.enter or car.leave of yours, or not). Once it has
  /// answered them all, where it has you is where you are: out, if someone got in first.
  void _carsChanged() {
    final news = c.store.cars.changed.value;
    if (news.answer) _pending = math.max(0, _pending - 1);
    _syncRiders();
    if (_pending > 0) return;
    final st = c.store.cars;
    final mine = st.carOf(c.store.you);
    if (driver.active) {
      if (mine?.car == driver.car && mine?.seat == driver.seat) return;
      final who = st.cars[driver.car!].who(driver.seat!);
      getOut(true);
      toast('🏎️ ${(who != null ? c.store.peers[who]?.name : null) ?? 'Someone'} got in there first', ToastKind.warn);
    } else if (mine != null) {
      // You got out while it was answering something else of yours.
      _pending++;
      c.net.send(const CarLeaveCmd());
    }
  }

  /// Everyone on your floor sitting in a car (or back on their feet, out of one).
  void _syncRiders() {
    final now = <String>{};
    for (final s in c.store.cars.cars) {
      for (final id in [s.driver, s.passenger]) {
        if (id != null && id != c.store.you) now.add(id);
      }
    }
    for (final id in now) {
      c.personOf(id)?.sit(seatHips);
    }
    for (final id in _riders.difference(now)) {
      c.personOf(id)?.sit(null);
    }
    _riders
      ..clear()
      ..addAll(now);
  }

  /// Back after a reconnect, which let go of your seat for you: back into it if it's still free.
  void _carAgain() {
    _pending = 0;
    final i = driver.car;
    final seat = driver.seat;
    if (i == null || seat == null) return;
    final slots = c.store.cars.cars;
    if (i >= slots.length || slots[i].who(seat) != null) {
      getOut(true);
      return;
    }
    _pending++;
    c.net.send(CarEnterCmd(i, seat));
    final p = driver.driving ? driver.pose : null;
    if (p != null) c.net.send(CarDriveCmd(car: i, x: p.x, z: p.z, rotY: p.rotY, speed: p.speed, steer: p.steer));
  }

  /// Where someone on your floor is sitting in a car, if they're in one.
  ({double x, double y, double z, double rotY})? rideOf(String id) {
    final at = c.store.cars.carOf(id);
    return at == null ? null : fleet.seatAt(at.car, at.seat);
  }

  /// The hint at a car: who's in it, and E to drive or hop in.
  (String, List<HintPart>) carHint(Interactable it) {
    final i = it.car ?? -1;
    final slots = c.store.cars.cars;
    if (i < 0 || i >= slots.length || i >= cars.length) return ('', const []);
    final s = slots[i];
    final def = cars[i];
    String name(String? id) => id == null ? '' : clip(c.store.peers[id]?.name ?? 'Someone', 20);
    final at = name(s.driver), beside = name(s.passenger);
    final k = '$i|$at|$beside';
    if (at.isEmpty) {
      return (
        k,
        [
          HintTitle('🏎️ ${def.name}'),
          HintAside(beside.isNotEmpty ? '$beside is waiting in it' : 'keys in the ignition'),
          const HintKey('E', 'Drive it'),
        ],
      );
    }
    if (beside.isEmpty) {
      return (k, [HintTitle('🏎️ ${def.name}'), HintAside('$at is driving'), const HintKey('E', 'Hop in')]);
    }
    return (k, [HintTitle('🏎️ ${def.name}'), HintAside('$at and $beside · full')]);
  }

  /// In a car: how fast, who with, where on the scenic loop, how the lap's going, and the keys.
  (String, List<HintPart>) driveHint() {
    final i = driver.car!;
    final s = c.store.cars.cars[i];
    String name(String? id) => id == null || id == c.store.you ? '' : (c.store.peers[id]?.name ?? '');
    final pose = fleet.views[i].pose;
    final place = placeAt(pose.x, pose.z);
    final where = place != null ? ' · ${place.icon} ${place.title}' : '';
    if (driver.driving) {
      final kmh = (pose.speed.abs() * 3.6).round();
      final other = name(s.passenger);
      final now = nowMs() / 1000;
      final done = laps.done != null && now - laps.done!.at < 6 ? laps.done : null;
      final running = laps.running(now);
      final lap = done != null
          ? ' · 🏁 ${lapTime(done.time)}${done.best ? ' best!' : ''}'
          : running != null
          ? ' · ⏱ ${lapTime(running)}'
          : '';
      return (
        'drive|$kmh|$other|$where|$lap',
        [
          HintTitle('🏎️ ${cars[i].name}'),
          HintAside('$kmh km/h$where$lap${other.isNotEmpty ? ' · with ${clip(other, 20)}' : ''}'),
          const HintKey('W A S D', 'Drive'),
          const HintKey('Space', 'Brake'),
          const HintKey('H', 'Honk'),
          const HintKey('E', 'Get out'),
        ],
      );
    }
    final at = name(s.driver);
    return (
      'ride|$at|$where',
      [
        HintTitle('🏎️ ${cars[i].name}'),
        HintAside('${at.isNotEmpty ? '${clip(at, 24)} is driving' : 'nobody at the wheel'}$where'),
        const HintKey('H', 'Honk'),
        const HintKey('E', 'Get out'),
      ],
    );
  }
}

/// Whether the system asks for less motion (no knocking the camera about).
bool get _calm => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
