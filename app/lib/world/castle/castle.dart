// The castle's style of map (see office_shared's maps/castle.dart for the castle itself): a long stone
// hall under a timber roof, pillars and pointed arches down both sides, stained glass high in the
// walls, a dais at one end with a throne of iron blades on it, long tables with benches for the
// workers, lecterns for the board agents, a round table for meetings, and fire everywhere. Everything
// is placed from the map's plan, so another map in this style is just other numbers. A port of
// world/castle/index.ts.
//
// It goes up a part at a time, each in a file of its own beside this one: the shell (the floor, the
// walls, the great doors and the roof), the throne on its dais, the props (one builder for each kind),
// the seats (the tables, the lecterns and the council's round table), the boards, and the herald and
// the Kingsguard (people.dart). What they all build with is in kit.dart.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/nav.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../dungeon.dart';
import '../labels.dart';
import '../office/geo.dart' show setToonTexture;
import '../office/parts.dart' show canvasTexture;
import '../sky_model.dart' show Rgb;
import '../toon.dart';
import '../world.dart';
import 'boards.dart';
import 'kit.dart';
import 'people.dart';
import 'props.dart';
import 'seats.dart';
import 'shell.dart';
import 'textures.dart';
import 'throne.dart';

/// Puts up the hall in [plan] (a castle-style map).
World buildCastle(MapPlan plan, LabelHub labels) => CastleWorld(plan, labels);

class CastleWorld extends World {
  CastleWorld(this.plan, LabelHub labels) {
    final c = plan.config ?? const {};
    final b = plan.bounds;
    final h = plan.height;
    final custom = c['palette'] is Map ? Map<String, dynamic>.from(c['palette'] as Map) : const <String, dynamic>{};
    String pal(String k, String d) => custom[k] is String ? custom[k] as String : d;
    final stone = pal('stone', '#9a9186'), floor = pal('floor', '#7b746a');
    final kit = _kit = Kit(
      group: group,
      height: h,
      mats: castleMaterials(
        stone: stone,
        wood: pal('wood', '#6b4526'),
        trim: pal('trim', '#d9ab2e'),
        carpet: pal('carpet', '#8e1b1b'),
      ),
    );
    _shell = buildShell(kit, plan, floorColor: floor, stoneColor: stone);
    // The dais before the props, so what stands on it stands on its top (see Kit.floorAt).
    buildDais(kit, plan);
    final props = [
      for (final p in (c['props'] as List?) ?? const [])
        if (p is Map) PropConfig.fromJson(Map<String, dynamic>.from(p)),
    ];
    for (final p in props) {
      castleProps[p.kind]?.call(kit, p);
    }
    arcade(kit, props.where((p) => p.kind == 'pillar').toList());
    buildTables(kit, plan);
    for (final def in plan.desks) {
      kit.desks[def.id] = placeSetting(kit, def, false).view;
    }
    for (final def in plan.overflow) {
      final s = placeSetting(kit, def, true);
      kit.desks[def.id] = s.view;
      _overflow[def.id] = s.it;
    }
    for (final def in plan.stations) {
      kit.desks[def.id] = lectern(kit, def);
    }
    final council = buildCouncil(kit, plan);
    meetingBoard = council.board;
    meetingSign = council.sign;
    boardMeshes = buildBoards(kit, plan);
    herald = buildHerald(kit, plan, labels);
    // The dungeon under the floor, the torches down there, and whoever keeps watch over it.
    final d = plan.dungeon;
    if (d != null) {
      dungeon = buildDungeon(
        DungeonKit(
          group: group,
          still: kit.still,
          colliders: kit.colliders,
          stone: kit.mats.stone,
          stoneDark: kit.mats.stoneDark,
          iron: kit.mats.iron,
          woodDark: kit.mats.woodDark,
          wall: texToon(painted(512, 256, ashlar(shade(stone, -0.16), 11))),
          flags: texToon(painted(512, 512, flagstones(shade(floor, -0.2)))),
        ),
        d,
      );
      for (final t in d.torches) {
        torch(kit, PropConfig(kind: 'torch', x: t.x, z: t.z, y: d.floor + 2.3, rotY: t.rotY));
      }
    }
    escort = buildEscort(kit, plan, labels);
    group.add(mergeByMaterial(kit.still));

    // Walking about: in through the doors and out again, round what's in the way.
    nav = NavGrid(b, plan.obstacles!);
    final s = _shell;
    final Pt inside = (plan.door.x, plan.door.z);
    final Pt threshold = (s.doorAt.x + s.out.$1 * 0.2, s.doorAt.z + s.out.$2 * 0.2);
    final Pt beyond = (s.doorAt.x + s.out.$1 * 3, s.doorAt.z + s.out.$2 * 3);
    ways = WaysOf(
      (seat, from) => (
        way: [...(from != null ? nav.route(from, inside) : nav.wayFrom(seat, inside)), threshold, beyond],
        chute: false,
      ),
      (seat) => [beyond, threshold, ...nav.wayTo(inside, seat)],
    );
    rain = [
      (
        area: (minX: b.minX, maxX: b.maxX, minZ: b.minZ, maxZ: b.maxZ),
        top: (double x, double z) => math.min(h - 1, 9.0),
      ),
    ];
    room = WorldRoom(wall: castleWall, enclosed: true, vault: d == null ? null : Vault(d.bounds, d.ceiling));
    final gongAt = kit.gong?.top;
    acoustics = Acoustics(
      gong: gongAt == null ? null : vm.Vector3(gongAt.x, gongAt.y - 1.8, gongAt.z),
      windows: [
        for (final p in props)
          if (p.kind == 'window') vm.Vector3(p.x, (p.y ?? 6) + (p.height ?? 5) / 2, p.z),
      ],
    );
    _look = FloorPalette(name: '', wall: stone, trim: '#9b1c1c', floor: floor, floorAlt: floor, seam: floor);
    _repaint();
  }

  @override
  final MapPlan plan;
  @override
  final Node group = Node(name: 'castle');
  late final Kit _kit;
  late final Shell _shell;
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
  WorldDevice get device => WorldDevice.tome;
  @override
  late final WorldRoom room;
  @override
  late final Acoustics acoustics;
  @override
  Herald? herald;
  @override
  DungeonView? dungeon;
  @override
  Escort? escort;

  /// What setLook and setProjectName were last told, which the great banner shows.
  String _name = '';
  late FloorPalette _look;
  double _doorOpen = 0;

  /// Whether the hall's fires are lent to the dungeon's torches (you're down there).
  bool _lampsDown = false;

  void _repaint() {
    final color = heraldry(_look);
    for (final bn in _kit.banners) {
      canvasTexture(
        bn.w,
        bn.h,
        (c) => paintBanner(c, bn.w.toDouble(), bn.h.toDouble(), color, bn.great ? _name : null),
      ).then((t) => setToonTexture(bn.material, t)).catchError((Object _) {});
    }
    for (final s in _kit.shields) {
      setToonColor(s, hex(color));
    }
  }

  @override
  List<Collider> setBeanbags(Set<String> out) {
    for (final e in _overflow.entries) {
      final show = out.contains(e.key);
      _kit.desks[e.key]!.group.visible = show;
      e.value.off = !show;
    }
    return const [];
  }

  /// The banners and shields take the floor's own color, so each project's hall is its own.
  @override
  void setLook(FloorPalette p) {
    _look = p;
    _repaint();
  }

  @override
  void setProjectName(String name) {
    if (name == _name) return;
    _name = name;
    _repaint();
  }

  @override
  void update(double t, double dt, Iterable<vm.Vector3> people) {
    for (final f in _kit.flames) {
      final k = 0.85 + 0.12 * math.sin(t * 13 + f.phase) + 0.08 * math.sin(t * 29 + f.phase * 2);
      f.mesh.scale = vm.Vector3(
        f.size * (0.95 + 0.08 * math.sin(t * 17 + f.phase)),
        f.size * k,
        f.size * (0.95 + 0.08 * math.cos(t * 19 + f.phase)),
      );
      f.mesh.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), t * 2 + f.phase);
      f.glow.scale = vm.Vector3.all(f.size * (1.2 + 0.3 * k));
    }
    for (final l in _kit.lights) {
      l.intensity = l.base * (0.82 + 0.1 * math.sin(t * 11 + l.phase) + 0.08 * math.sin(t * 23 + l.phase * 3));
    }
    // The doors swing in for anyone coming up to them, from either side.
    final at = _shell.doorAt;
    var near = false;
    for (final q in people) {
      if (math.sqrt(math.pow(q.x - at.x, 2) + math.pow(q.z - at.z, 2)) < 4) near = true;
    }
    final want = near ? 1.0 : 0.0;
    if (_doorOpen != want) {
      _doorOpen = want > _doorOpen ? math.min(1, _doorOpen + dt * 1.2) : math.max(0, _doorOpen - dt * 0.8);
      _shell.swing(_doorOpen);
    }
    for (final d in _kit.desks.values) {
      if (!d.vacancy.visible || !d.group.visible || d.def.station != null) continue;
      d.vacancy.position = vm.Vector3(0, d.vacancyY + math.sin(t * 2 + d.def.x) * 0.06, 0);
      d.vacancy.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), t * 1.2);
    }
    _kit.gong?.update(dt);
    herald?.person.update(dt, t, false, false);
  }

  static final Rgb _warmSky = Rgb.hex(0xffe2bc);
  static final Rgb _warmGround = Rgb.hex(0x4a3322);
  static final Rgb _haze = Rgb.hex(0x2a1e16);
  static final Rgb _dank = Rgb.hex(0x0c0907);
  static final Rgb _glassDay = Rgb.hex(0xffffff);
  static final Rgb _glassNight = Rgb.hex(0x5a4a6a);
  static final Rgb _fire = Rgb.hex(0xffae5c);

  /// Torchlit: a warm, dim hall whatever the weather, a little brighter by day through the glass; down in
  /// the dungeon, dark but for the torches, which the hall's fires are lent to.
  @override
  void Function(Mood m) get mood => _mood;

  void _mood(Mood m) {
    final l = m.light;
    final d = plan.dungeon;
    final eye = m.eye;
    final below = d != null && eye != null && eye.y < d.ceiling - 0.1;
    final dv = dungeon;
    if (dv != null && d != null && eye != null) {
      final (o0, o1, p0, p1) = d.opening;
      final near = eye.x > o0 - 7 && eye.x < o1 + 7 && eye.z > p0 - 7 && eye.z < p1 + 7;
      dv.inside.visible = below || near;
    }
    if (below || _lampsDown) {
      final lamps = below
          ? ([...dv!.lamps]..sort((p, q) => p.distanceToSquared(eye).compareTo(q.distanceToSquared(eye))))
          : <vm.Vector3>[];
      for (var i = 0; i < _kit.lights.length; i++) {
        _kit.lights[i].at = i < lamps.length ? lamps[i].clone() : _kit.lights[i].home.clone();
      }
      _lampsDown = below;
    }
    // The fires' pools of light (the toon shader's eight lamps), however the sky's set them.
    l.officeOn = 0;
    l.officeLight.setZero();
    l.garageLight.setZero();
    l.wet = 0;
    l.snow = 0;
    for (var i = 0; i < 8; i++) {
      if (i < _kit.lights.length) {
        final f = _kit.lights[i];
        l.lampPos[i].setValues(f.at.x, f.at.y, f.at.z, 16);
        final c = _fire.scale(f.intensity / 12);
        l.lampColor[i].setValues(c.r, c.g, c.b);
      } else {
        l.lampPos[i].setZero();
      }
    }
    l.sky = _warmSky.color;
    l.ground = _warmGround.color;
    final fog = m.fog;
    if (below) {
      l.hemiIntensity = 0.5 / math.pi;
      l.ambient = 0.34 / math.pi;
      l.sunIntensity = 0;
      fog
        ..color = _dank.vector
        ..start = 6
        ..end = 34;
      return;
    }
    l.hemiIntensity = (0.45 + 0.4 * m.daylight) / math.pi;
    l.ambient = (0.24 + 0.12 * m.daylight) / math.pi;
    l.sunIntensity *= 0.4;
    fog
      ..color = _haze.vector
      ..start = 45
      ..end = 140;
    final glass = _glassNight.lerp(_glassDay, 0.25 + 0.75 * m.daylight);
    for (final g in _kit.glass) {
      g.baseColorFactor = vm.Vector4(glass.r, glass.g, glass.b, 1);
    }
  }
}
