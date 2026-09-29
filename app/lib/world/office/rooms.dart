// The games and rooms upstream added to the office (office.ts, world/cabinet.ts): the board agents'
// kiosks by the boards, the arcade cabinet in the lounge, the machine monitor on the west wall, and
// (in their own files) the bookshelf, the basketball hoop, the golf tee and the meeting room. They are
// built into an already-built Office by [addRooms], so the rest of the building stays as it was.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/decor.dart' show WallRect;
import 'package:office_shared/hoop.dart' show Hoop;
import 'package:office_shared/layout.dart';
import 'package:office_shared/nav.dart' show deskPoint;
import 'package:vector_math/vector_math.dart' as vm;

import '../../ui/screen_paint.dart';
import '../collider.dart';
import '../hoop.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office.dart';
import 'parts.dart';

/// The pieces' colors, for the cabinet's side art and marquee.
const _pieces = ['#4cc9f0', '#ffd166', '#b388eb', '#06d6a0', '#ef476f', '#4f86f7', '#ff8a5b'];

const Map<StationKind, String> _kioskSign = {
  StationKind.issues: '📌 Ask me',
  StationKind.pulls: '🔀 Ask me',
  StationKind.queue: '📋 Ask me',
};

/// What [addRooms] built that the office needs to reach later.
class RoomsView {
  RoomsView({
    required this.cabinetScreen,
    required this.machineScreen,
    required this.idleAgentSpots,
    required this.hoop,
  });

  /// The basketball hoop on the west wall (the ball is office/ball_play.dart's).
  final HoopView hoop;

  /// The arcade cabinet's screen: 4:3, leaning back a little.
  final Face cabinetScreen;

  /// The machine monitor's screen on the west wall.
  final Face machineScreen;

  /// Where each board agent waits before anyone has asked it anything, by kiosk id: the office puts
  /// a worker model in there (see the controller).
  final Map<String, Node> idleAgentSpots;
}

/// Adds the kiosks, the cabinet and the machine monitor to [office].
RoomsView addRooms(Office office) {
  final group = office.group;
  final fixtures = office.fixtures();
  void fixture(Side wall, double u, double y, double w, double h) =>
      fixtures.add(WallRect(wall: wall, u0: u - w / 2, u1: u + w / 2, y0: y - h / 2, y1: y + h / 2));

  // The board agents' kiosks, each just west of its board.
  final spots = <String, Node>{};
  for (final def in stations) {
    final view = _buildKiosk(def);
    group.add(view.group);
    office.desks[def.id] = view;
    spots[def.id] = view.vacancy.children.first;
    // Walk up to its front.
    final (fx, fz) = deskPoint(def, 0, -1);
    final it = Interactable(kind: InteractKind.station, deskId: def.id, x: fx, z: fz, radius: 1.3);
    office.interactables.add(it);
    tagInteract(view.group, it);
    // The agent, its name tag and the card over its head, up against the wall.
    fixture(Side.north, def.x, 1.45, 1.4, 2.9);
  }

  // The machine monitor between the west windows, facing the desks.
  final monitor = Node(name: 'machine-monitor');
  monitor.add(
    place(
      mesh(roundedBox(MachineMonitor.width + 0.16, 0.1, MachineMonitor.height + 0.16, 0.06), tc(Palette.ink)),
      rot: euler(math.pi / 2),
    ),
  );
  final machineMat = flat('#1b1d2e');
  final machineNode = mesh(planeXY(MachineMonitor.width, MachineMonitor.height), machineMat, 0, 0, 0.06, false);
  monitor.add(machineNode);
  group.add(
    place(monitor, x: MachineMonitor.x + 0.07, y: MachineMonitor.y, z: MachineMonitor.z, rot: yaw(math.pi / 2)),
  );
  fixture(Side.west, MachineMonitor.z, MachineMonitor.y, MachineMonitor.width + 0.2, MachineMonitor.height + 0.2);

  // The arcade cabinet in the lounge.
  final cabinet = _buildCabinet();
  group.add(cabinet.group);
  office.interactables.add(cabinet.interactable);
  fixture(Side.east, Cabinet.z, Cabinet.height / 2, Cabinet.width + 0.1, Cabinet.height);

  // The basketball hoop, on the west wall between the exit door and the kitchen.
  final hoop = buildHoop();
  group.add(hoop.group);
  fixture(
    Side.west,
    Hoop.z,
    (Hoop.board.bottom - 0.6 + Hoop.board.top + 0.1) / 2,
    Hoop.board.width + 0.2,
    Hoop.board.top - Hoop.board.bottom + 0.7,
  );

  return RoomsView(
    hoop: hoop,
    cabinetScreen: cabinet.screen,
    machineScreen: Face(machineNode, machineMat, MachineMonitor.width, MachineMonitor.height),
    idleAgentSpots: spots,
  );
}

// ---- Board agents' kiosks -------------------------------------------------------------------------

/// A board agent's kiosk: a little counter in its color with a sign on the front, and the agent
/// standing behind it. Its `vacancy` is where the agent waits before anyone has asked it anything
/// (the controller puts one there), in the same spot and pose as the one who gets hired.
DeskView _buildKiosk(DeskDef def) {
  final kind = def.station!;
  final group = Node(name: def.id);
  group.position = vm.Vector3(def.x, 0, def.z);
  group.rotation = yaw(def.rotY);
  const width = Kiosk.width, depth = Kiosk.depth, height = Kiosk.height;
  final body = Node(name: 'kiosk');
  // Narrower at the foot, like a lectern, with a lip round the top.
  body.add(
    mesh(
      roundedBox(width - 0.16, height - 0.1, depth - 0.12, 0.06),
      tc(stationAgent[kind]!.color),
      0,
      (height - 0.1) / 2 + 0.04,
      0,
    ),
  );
  body.add(mesh(roundedBox(width - 0.02, 0.06, depth + 0.02, 0.05), tc(Palette.ink), 0, 0.03, 0));
  body.add(mesh(roundedBox(width, 0.06, depth, 0.05), tc(Palette.desk), 0, height - 0.03, 0));
  group.add(mergeByMaterial(body));
  group.add(
    place(
      textPlane(_kioskSign[kind]!, const TextOpts(bg: '#fffaf3', size: 56)),
      y: height * 0.55,
      z: -(depth - 0.12) / 2 - 0.012,
      rot: yaw(math.pi),
      scale: 0.62,
    ),
  );

  // No laptop: its lid would hide the agent's face from whoever walks up, and its screen would face
  // the wall. The agent's terminal is a key press away (O).
  final laptopAnchor = Node(name: 'laptop-anchor')..visible = false;
  group.add(laptopAnchor);

  // On its feet behind the kiosk, facing it and the room beyond.
  Node stand() => place(
    Node(name: 'stand'),
    y: -0.07 * 1.1,
    z: Kiosk.stand,
    rot: yaw(math.pi),
    scale: 1.1,
  );
  final seatAnchor = stand();
  group.add(seatAnchor);
  final vacancy = Node(name: 'vacancy')..add(stand());
  group.add(vacancy);
  return DeskView(
    def: def,
    group: group,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    chair: Node(name: 'no-chair'),
    vacancy: vacancy,
    vacancyY: 0,
  );
}

// ---- The arcade cabinet ---------------------------------------------------------------------------

// An upright in blue side panels, a lit marquee on top, the screen leaning back under it (ui/cabinet.dart
// paints the game on it), a joystick and buttons, and a coin door.

/// The cabinet from the side, front toward +u: floor to marquee, round the control panel and the screen.
const List<(double, double)> _body = [
  (-0.4, 0),
  (0.26, 0),
  (0.26, 0.84),
  (0.4, 0.9),
  (0.4, 0.98),
  (0.13, 1.05),
  (0.01, 1.57),
  (0.19, 1.63),
  (0.19, 1.9),
  (-0.4, 1.9),
];

/// The side panels: the same, standing a little proud of it all round.
const List<(double, double)> _side = [
  (-0.4, 0),
  (0.29, 0),
  (0.29, 0.83),
  (0.43, 0.89),
  (0.43, 1.0),
  (0.16, 1.07),
  (0.04, 1.58),
  (0.22, 1.64),
  (0.22, 1.93),
  (-0.4, 1.93),
];
const double _sideT = 0.04;

/// Where the screen is on the slope under the marquee, and how far back it leans.
const _screenBottom = (0.13, 1.05);
const _screenTop = (0.01, 1.57);
final double _lean = math.atan2(_screenBottom.$1 - _screenTop.$1, _screenTop.$2 - _screenBottom.$2);

/// The control panel's top, which rises a little toward the screen.
const _panelFront = (0.4, 0.98);
const _panelBack = (0.13, 1.05);

/// A side-view outline pulled out [thick] wide across the cabinet, from [x0].
Geometry _slab(List<(double, double)> points, double thick, double x0) {
  final shape = Shape2();
  shape.moveTo(points.first.$1, points.first.$2);
  for (final (u, v) in points.skip(1)) {
    shape.lineTo(u, v);
  }
  // Outline in u (front) and v (up), extruded along w: turn it so u runs along z and w along x.
  return transformed(
    extrudeShape(shape, thick),
    vm.Matrix4.translationValues(x0 + thick, 0, 0)..multiply(vm.Matrix4.rotationY(-math.pi / 2)),
  );
}

({Node group, Interactable interactable, Face screen}) _buildCabinet() {
  const w = Cabinet.width;
  final group = Node(name: 'cabinet');
  final stat = Node(name: 'cabinet-body');
  const inner = w - 2 * _sideT;
  stat.add(mesh(_slab(_body, inner, -inner / 2), tc('#1b1d3a')));
  final sideMat = tc('#4361ee');
  for (final x0 in [-w / 2, w / 2 - _sideT]) {
    stat.add(mesh(_slab(_side, _sideT, x0), sideMat));
  }

  // Falling blocks down each side, as side art: a Z, an L and a T.
  const art = [
    (0.02, 1.62, 4),
    (-0.09, 1.62, 4),
    (-0.09, 1.51, 4),
    (-0.2, 1.51, 4),
    (0.02, 1.39, 6),
    (0.02, 1.28, 6),
    (0.02, 1.17, 6),
    (-0.09, 1.17, 6),
    (-0.12, 0.62, 2),
    (-0.01, 0.62, 2),
    (0.1, 0.62, 2),
    (-0.01, 0.51, 2),
  ];
  for (final (u, v, c) in art) {
    for (final sx in [-1, 1]) {
      stat.add(mesh(box(0.02, 0.1, 0.1), tc(_pieces[c]), sx * (w / 2 + 0.01), v, u, false));
    }
  }

  // The screen, in a black bezel on the slope.
  final (bu, bv) = _screenBottom;
  final (tu, tv) = _screenTop;
  final out = (math.cos(_lean), math.sin(_lean));
  stat.add(
    place(
      mesh(planeXY(inner - 0.04, 0.5), tc('#0b1320'), 0, 0, 0, false),
      y: (bv + tv) / 2 + out.$2 * 0.002,
      z: (bu + tu) / 2 + out.$1 * 0.002,
      rot: euler(-_lean),
    ),
  );

  // The control panel: a joystick and three buttons.
  final (fu, fv) = _panelFront;
  final (pu, pv) = _panelBack;
  final panel = Node(name: 'panel');
  panel.add(
    mesh(box(inner, 0.012, math.sqrt(math.pow(fu - pu, 2) + math.pow(fv - pv, 2))), tc('#ffd166'), 0, 0.006, 0, false),
  );
  panel.add(mesh(cyl(0.045, 0.05, 0.02, 16), tc('#2b2d42'), -0.16, 0.02, 0.01, false));
  panel.add(mesh(cyl(0.012, 0.012, 0.11, 8), tc('#adb5bd'), -0.16, 0.075, 0.01, false));
  panel.add(mesh(sphere(0.035, 14, 10), tc('#ef476f'), -0.16, 0.135, 0.01));
  const buttons = ['#ef476f', '#4cc9f0', '#06d6a0'];
  for (var i = 0; i < buttons.length; i++) {
    panel.add(
      mesh(
        cyl(0.026, 0.026, 0.025, 14),
        tc(buttons[i], emissive: buttons[i]),
        0.02 + i * 0.1,
        0.02,
        i == 1 ? -0.03 : 0.02,
        false,
      ),
    );
  }
  stat.add(place(panel, y: (fv + pv) / 2, z: (fu + pu) / 2, rot: euler(math.atan2(pv - fv, fu - pu))));

  // The coin door, with its two slots lit, and a kick plate.
  stat.add(mesh(roundedBox(0.34, 0.32, 0.02, 0.02), tc('#2b2d42'), 0, 0.5, 0.265, false));
  for (final sx in [-1, 1]) {
    stat.add(mesh(box(0.035, 0.075, 0.012), tc('#ff8a5b', emissive: '#ff5a1f'), sx * 0.07, 0.56, 0.278, false));
  }
  stat.add(mesh(box(0.1, 0.02, 0.012), tc('#8d99ae'), 0, 0.43, 0.278, false));
  stat.add(mesh(box(inner, 0.1, 0.01), tc('#0b1320'), 0, 0.05, 0.266, false));
  group.add(mergeByMaterial(stat));

  // The marquee: the game's name, lit from behind.
  final marqueeMat = flat('#3a0ca3');
  group.add(mesh(planeXY(inner, 0.25), marqueeMat, 0, 1.765, 0.192, false));
  canvasTexture(512, 160, _paintMarquee).then((t) {
    marqueeMat
      ..baseColorTexture = t
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
  });

  final screenMat = flat('#070b14');
  final screen = place(
    mesh(planeXY(0.56, 0.42), screenMat, 0, 0, 0, false),
    y: (bv + tv) / 2 + out.$2 * 0.005,
    z: (bu + tu) / 2 + out.$1 * 0.005,
    rot: euler(-_lean),
  );
  group.add(screen);

  // Built facing +z; it stands against the east wall facing into the room (-x).
  group.position = vm.Vector3(Cabinet.x, 0, Cabinet.z);
  group.rotation = yaw(-math.pi / 2);
  final it = Interactable(kind: InteractKind.cabinet, x: Cabinet.x - 1.2, z: Cabinet.z, radius: 1.3);
  tagInteract(group, it);
  return (group: group, interactable: it, screen: Face(screen, screenMat, 0.56, 0.42));
}

void _paintMarquee(Canvas c) {
  const w = 512.0, h = 160.0;
  c.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, h), [css('#3a0ca3'), css('#1b1d3a')]),
  );
  final g = Pen(c);
  const letters = 'BLOCKFALL';
  final styles = [
    for (var i = 0; i < letters.length; i++)
      g.style(
        84,
        weight: FontWeight.w900,
        color: css(_pieces[i % _pieces.length]),
        shadows: [Shadow(color: css(_pieces[i % _pieces.length]), blurRadius: 16)],
      ),
  ];
  final widths = [for (var i = 0; i < letters.length; i++) g.measure(letters[i], styles[i])];
  var x = w / 2 - widths.fold<double>(0, (a, b) => a + b) / 2;
  for (var i = 0; i < letters.length; i++) {
    g.text(letters[i], x + widths[i] / 2, h / 2 + 4, styles[i]);
    x += widths[i];
  }
}
