// The station's style of map (see office_shared's maps/station.dart for the station itself): a
// pressurised deck in orbit, windows cut through its hull onto the stars and the Earth, a bridge at one
// end with the captain's chair on it, long benches for the workers, consoles for the board agents, a
// briefing table for meetings, and an airlock to see workers off through. Everything is placed from
// the map's plan, so another map in this style is just other numbers. A port of world/station/index.ts.
//
// It goes up a part at a time, each in a file of its own beside this one: the shell (the deck, the hull
// and what's cut through it, the hatch and the solar wings), the airlock, the props (one builder for
// each kind), the seats (the benches, the consoles, the briefing table, the bridge and the boards), the
// people, and space itself, outside (space.dart). What they build with is in kit.dart.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/nav.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../labels.dart';
import '../office/geo.dart' show yaw;
import '../sky_model.dart' show Rgb;
import '../text.dart';
import '../toon.dart';
import '../world.dart';
import 'airlock.dart';
import 'kit.dart';
import 'people.dart';
import 'props.dart';
import 'seats.dart';
import 'shell.dart';
import 'space.dart';

/// Puts up the station in [plan] (a station-style map).
World buildStation(MapPlan plan, LabelHub labels) => StationWorld(plan, labels);

class StationWorld extends World {
  StationWorld(this.plan, LabelHub labels) {
    final c = plan.config ?? const {};
    final b = plan.bounds;
    final h = plan.height;
    final pal = stationPalette(plan);
    final kit = _kit = Kit(
      plan: plan,
      group: group,
      height: h,
      glow: pal.glow,
      mats: stationMaterials(hull: pal.hull, panel: pal.panel, metal: pal.metal, glow: pal.glow),
    );
    _shell = buildShell(kit, hull: pal.hull, deck: pal.deck);
    // The bridge before the props, so what stands on it stands on its top (see Kit.floorAt).
    buildBridge(kit);
    for (final p in (c['props'] as List?) ?? const []) {
      if (p is! Map) continue;
      final prop = PropConfig.fromJson(Map<String, dynamic>.from(p));
      stationProps[prop.kind]?.call(kit, prop);
    }
    buildBenches(kit);
    for (final def in plan.desks) {
      kit.desks[def.id] = placeSetting(kit, def, false).view;
    }
    for (final def in plan.overflow) {
      final s = placeSetting(kit, def, true);
      kit.desks[def.id] = s.view;
      _overflow[def.id] = s.it;
    }
    for (final def in plan.stations) {
      kit.desks[def.id] = agentConsole(kit, def);
    }
    final briefing = buildBriefing(kit);
    meetingBoard = briefing.board;
    meetingSign = briefing.sign;
    boardMeshes = buildBoards(kit);
    herald = buildHerald(kit, labels);
    _airlock = buildAirlock(kit);
    escort = buildEscort(kit, labels);
    group.add(mergeByMaterial(kit.still));
    group.add(_space.group);

    // Walking about: in through the hatch and out again, round what's in the way.
    nav = NavGrid(b, plan.obstacles!);
    final s = _shell;
    final Pt inside = (plan.door.x, plan.door.z);
    final Pt threshold = (s.doorAt.x + s.out.$1 * 0.25, s.doorAt.z + s.out.$2 * 0.25);
    final Pt beyond = (s.doorAt.x + s.out.$1 * 4.6, s.doorAt.z + s.out.$2 * 4.6);
    ways = WaysOf(
      (seat, from) => (
        way: [...(from != null ? nav.route(from, inside) : nav.wayFrom(seat, inside)), threshold, beyond],
        chute: false,
      ),
      (seat) => [beyond, threshold, ...nav.wayTo(inside, seat)],
    );
    rain = [(area: (minX: b.minX, maxX: b.maxX, minZ: b.minZ, maxZ: b.maxZ), top: (double x, double z) => h - 0.5)];
    final gongAt = kit.gong?.top;
    // Nothing outside to hear: no rain on the glass, no birds.
    acoustics = Acoustics(gong: gongAt == null ? null : vm.Vector3(gongAt.x, gongAt.y - 1.8, gongAt.z), vacuum: true);
  }

  @override
  final MapPlan plan;
  @override
  final Node group = Node(name: 'station');
  late final Kit _kit;
  late final Shell _shell;
  final Space _space = Space();
  AirlockView? _airlock;
  final Map<String, Interactable> _overflow = {};

  @override
  List<Collider> get colliders => _kit.colliders;
  @override
  List<Interactable> get interactables => _kit.interactables;
  @override
  Map<String, DeskView> get desks => _kit.desks;
  @override
  late final Map<String, Face> boardMeshes;
  @override
  Face? meetingBoard;
  @override
  Face? meetingSign;
  @override
  Gong? get gong => _kit.gong;
  @override
  late final NavGrid nav;
  @override
  late final Ways ways;
  @override
  late final List<RainArea> rain;
  @override
  WorldDevice get device => WorldDevice.laptop;
  @override
  WorldRoom get room => const WorldRoom(wall: 0.5, enclosed: true);
  @override
  late final Acoustics acoustics;
  @override
  Herald? herald;
  @override
  AirlockSite? get airlock => _airlock;
  @override
  Escort? escort;
  @override
  bool get ownSky => true;

  String _name = '';
  Node? _nameplate;
  double _doorOpen = 0;

  /// The ship's name, over the bridge's windows.
  void _christen() {
    _nameplate?.parent?.remove(_nameplate!);
    _nameplate = null;
    if (_name.isEmpty) return;
    final b = plan.bounds;
    final h = plan.height;
    final at = plan.throne;
    final x = at?.x ?? (b.minX + b.maxX) / 2, z = at?.z ?? b.minZ + 0.3, rotY = at?.rotY ?? 0.0;
    final f = _kit.mats.accent.baseColorFactor;
    String byte(double v) => (_srgb(v) * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final border = '#${byte(f.x)}${byte(f.y)}${byte(f.z)}';
    final plate = textPlane(
      '🛰️ ${_name.toUpperCase()} STATION',
      TextOpts(bg: '#0f1a26', color: '#e6f6ff', border: border, size: 64),
    );
    // On the wall behind the chair, facing down the deck.
    final bx = -math.sin(rotY), bz = -math.cos(rotY);
    double reach(double at, double d, double lo, double hi) =>
        d.abs() < 1e-6 ? double.infinity : ((d > 0 ? hi : lo) - at) / d;
    final back = math.min(reach(x, bx, b.minX, b.maxX), reach(z, bz, b.minZ, b.maxZ)) - 0.07;
    plate
      ..position = vm.Vector3(x + bx * back, h - 0.75, z + bz * back)
      ..rotation = yaw(rotY)
      ..scale = vm.Vector3.all(1.5);
    group.add(plate);
    _nameplate = plate;
  }

  static double _srgb(double c) => c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;

  @override
  List<Collider> setBeanbags(Set<String> out) {
    for (final e in _overflow.entries) {
      final show = out.contains(e.key);
      _kit.desks[e.key]!.group.visible = show;
      e.value.off = !show;
    }
    return const [];
  }

  /// The lines of light take the floor's own color, bright, so each project's deck is its own.
  @override
  void setLook(FloorPalette p) {
    final hsl = HSLColor.fromColor(hex(p.trim));
    _kit.mats.accent.baseColorFactor = linear(HSLColor.fromAHSL(1, hsl.hue, 0.9, 0.6).toColor());
    _christen();
  }

  @override
  void setProjectName(String name) {
    if (name == _name) return;
    _name = name;
    _christen();
  }

  @override
  void update(double t, double dt, Iterable<vm.Vector3> people) {
    for (final s in _kit.spinners) {
      s.angle += s.speed * dt;
      s.obj.rotation = yaw(s.angle);
    }
    for (final p in _kit.pulses) {
      p.set(0.5 + 0.5 * math.sin((t * p.rate + p.phase) * math.pi * 2));
    }
    // The hatch slides open for anyone coming up to it, from either side.
    final at = _shell.doorAt;
    var near = false;
    for (final q in people) {
      if (math.sqrt(math.pow(q.x - at.x, 2) + math.pow(q.z - at.z, 2)) < 4) near = true;
    }
    final want = near ? 1.0 : 0.0;
    if (_doorOpen != want) {
      _doorOpen = want > _doorOpen ? math.min(1, _doorOpen + dt * 1.6) : math.max(0, _doorOpen - dt * 1.1);
      _shell.slide(_doorOpen);
    }
    for (final d in _kit.desks.values) {
      if (!d.vacancy.visible || !d.group.visible || d.def.station != null) continue;
      d.vacancy.position = vm.Vector3(0, d.vacancyY + math.sin(t * 2 + d.def.x) * 0.06, 0);
      d.vacancy.rotation = yaw(t * 1.2);
    }
    _kit.gong?.update(dt);
    herald?.person.update(dt, t, false, false);
  }

  static final Color _coolSky = const Color(0xFFE3EDFF);
  static final Color _coolGround = const Color(0xFF4B566A);
  static final Color _sunlight = const Color(0xFFFFF4E0);
  static final Rgb _pod = Rgb.hex(0xe6f2ff);
  static final Rgb _alarm = Rgb.hex(0xff3b30);

  /// There's no day or night up here, and no weather: the deck's own light, and the Sun where it gets in.
  @override
  void Function(Mood m) get mood => _mood;

  void _mood(Mood m) {
    final eye = m.eye;
    if (eye != null) _space.update(m.t, eye);
    final l = m.light;
    l.officeOn = 0;
    l.officeLight.setZero();
    l.garageLight.setZero();
    l.wet = 0;
    l.snow = 0;
    // The light pods that light the deck for real, and the airlock's red lamp when its alarm's going:
    // pools of the toon shader's lamplight.
    for (var i = 0; i < 8; i++) {
      if (i < _kit.lights.length) {
        final p = _kit.lights[i];
        l.lampPos[i].setValues(p.x, p.y, p.z, 22);
        final c = _pod.scale(22 / 14);
        l.lampColor[i].setValues(c.r, c.g, c.b);
      } else {
        l.lampPos[i].setZero();
      }
    }
    final a = _airlock;
    if (a != null && a.lamp > 0) {
      final i = math.min(_kit.lights.length, 7);
      l.lampPos[i].setValues(a.lampAt.x, a.lampAt.y, a.lampAt.z, 14);
      final c = _alarm.scale(a.lamp / 12);
      l.lampColor[i].setValues(c.r, c.g, c.b);
    }
    l.sky = _coolSky;
    l.ground = _coolGround;
    l.hemiIntensity = 1.05 / math.pi;
    l.ambient = 0.42 / math.pi;
    l.sunColor = _sunlight;
    l.sunIntensity = 1.5 / math.pi;
    l.sunDirection = sunward.clone();
    // Nothing out there to haze over: the backdrop's far off, and black.
    m.fog
      ..color = vm.Vector3.zero()
      ..start = 400
      ..end = 500;
  }

  @override
  void dispose() {
    _space.group.parent?.remove(_space.group);
  }
}
