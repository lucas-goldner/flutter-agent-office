// The lounge jukebox: a cherry-red cabinet with a rounded top, a neon tube round its face that
// glows to the beat while it plays, a little display saying what's on, and notes floating up (as
// labels over the scene).

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/material.dart' show Icon, Icons, Opacity;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' as lay;
import '../../ui/theme.dart' show kFont;
import '../collider.dart';
import '../labels.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';

// Music notes from the bundled Material icons: the app's font has no ♪, and the web build fetches
// no fallback fonts.
const _notes = [Icons.music_note, Icons.queue_music, Icons.music_note, Icons.audiotrack, Icons.queue_music];
const _noteColors = ['#ef476f', '#4f86f7', '#06d6a0', '#9d4edd', '#ff8a5b'];

class JukeboxView {
  JukeboxView._(this.group, this.collider, this.interactable, this._neon, this._screen, this._notes);

  final Node group;
  final Collider collider;
  final Interactable interactable;
  final PreprocessedMaterial _neon;
  final UnlitMaterial _screen;
  final List<WorldLabel> _notes;
  bool _on = false;
  String _shown = '';
  int _paints = 0;

  /// What the display says, and whether the lights are on.
  void show(bool playing, String title) {
    final k = '$playing|$title';
    if (k == _shown) return;
    _shown = k;
    _on = playing;
    _paint(title);
    // Lit, the glow is the colour; dark, it's dull glass.
    setToonColor(_neon, hex(_on ? '#1b1d2e' : '#b8b2a7'));
    if (!_on) {
      setEmissive(_neon, const Color(0xFF000000), 0);
      for (final n in _notes) {
        n.visible = false;
      }
    }
  }

  void _paint(String title) {
    final on = _on;
    final ticket = ++_paints;
    canvasTexture(512, 256, (g) {
      g.drawRect(
        const Rect.fromLTWH(0, 0, 512, 256),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [hex(on ? '#3a0ca3' : '#2b2d42'), hex('#1b1d2e')],
          ).createShader(const Rect.fromLTWH(0, 0, 512, 256)),
      );
      void text(String s, double size, FontWeight w, Color color, double y, {bool notes = false}) {
        var sz = size;
        TextPainter tp;
        do {
          final style = TextStyle(fontFamily: kFont, fontSize: sz--, fontWeight: w, color: color);
          final note = TextSpan(
            text: String.fromCharCode(Icons.music_note.codePoint),
            style: style.copyWith(fontFamily: Icons.music_note.fontFamily),
          );
          tp = TextPainter(
            text: TextSpan(style: style, children: [if (notes) note, TextSpan(text: notes ? ' $s ' : s), if (notes) note]),
            textDirection: TextDirection.ltr,
          )..layout();
        } while (tp.width > 470 && sz > 26);
        tp.paint(g, Offset(256 - tp.width / 2, y - tp.height / 2));
      }

      text(on ? 'NOW PLAYING' : 'JUKEBOX', 44, FontWeight.w900, hex(on ? '#ffd166' : '#8d99ae'), 70, notes: on);
      text(on ? title : 'press E to play', 58, FontWeight.w800, hex(on ? '#ffffff' : '#8d99ae'), 160);
    }).then((t) {
      if (ticket == _paints) _screen.baseColorTexture = t;
    });
  }

  /// [beat] runs 1 → 0 after each beat while music plays (see OfficeSound.beat).
  void update(double t, double dt, double beat) {
    if (!_on) return;
    // The tube slowly runs through the colours and flares on every beat.
    final c = HSLColor.fromAHSL(1, (t * 0.05) % 1 * 360, 0.85, 0.55).toColor();
    setEmissive(_neon, c, 0.55 + 0.9 * beat);
    for (var i = 0; i < _notes.length; i++) {
      final n = _notes[i];
      final k = (t * 0.35 + i / _notes.length) % 1;
      n.visible = true;
      n.offset = vm.Vector3(math.sin(t * 1.3 + i * 2.1) * 0.35, lay.Jukebox.height + 0.1 + k * 1.3, 0.1);
      n.child = _note(i, math.min(1, k * 5) * (1 - k));
    }
  }
}

Opacity _note(int i, double opacity) => Opacity(
  opacity: opacity.clamp(0, 1),
  child: Icon(_notes[i], size: 44, color: hex(_noteColors[i])),
);

JukeboxView buildJukebox({required LabelHub labels}) {
  const w = lay.Jukebox.width, d = lay.Jukebox.depth, h = lay.Jukebox.height;
  const r = w / 2;
  final group = Node(name: 'jukebox');
  // All but the display (which keeps its UVs) is merged at the end.
  final stat = Node(name: 'cabinet');

  // The cabinet: a tombstone shape, straight sides under a half-round top.
  final shape = Shape2(24)
    ..moveTo(-r, 0)
    ..lineTo(r, 0)
    ..lineTo(r, h - r)
    ..absarc(0, h - r, r, 0, math.pi, false)
    ..lineTo(-r, 0);
  final body = transformed(extrudeShape(shape, d, bevel: 0.03), vm.Matrix4.translationValues(0, 0, -d / 2));
  stat.add(mesh(body, tc('#d64545')));
  stat.add(mesh(box(w + 0.12, 0.1, d + 0.12), tc('#2b2d42'), 0, 0.05, 0));

  const front = d / 2 + 0.035;
  // The neon tube: up one side, over the arch and down the other.
  final neon = toonUnique(hex('#ffd166'), emissive: hex('#ffd166'));
  const tubeR = r - 0.1;
  const legLen = h - r - 0.3;
  stat.add(mesh(torusXY(tubeR, 0.045, 8, 36, math.pi), neon, 0, h - r, front, false));
  for (final sx in [-1, 1]) {
    stat.add(mesh(cyl(0.045, 0.045, legLen, 8), neon, sx * tubeR, 0.3 + legLen / 2, front, false));
  }

  // The display in the arch: what's playing.
  final screenMat = UnlitMaterial();
  group.add(mesh(planeXY(0.82, 0.41), screenMat, 0, h - r + 0.02, front + 0.005, false));

  // Selector buttons, and the speaker grille below them.
  const buttons = ['#ef476f', '#ffd166', '#06d6a0', '#4cc9f0', '#9d4edd'];
  for (var i = 0; i < buttons.length; i++) {
    stat.add(mesh(roundedBox(0.1, 0.05, 0.05, 0.02), tc(buttons[i]), (i - 2) * 0.14, 0.98, front, false));
  }
  stat.add(mesh(box(0.82, 0.52, 0.03), tc('#2b2d42'), 0, 0.58, front - 0.01, false));
  for (var i = 0; i < 5; i++) {
    stat.add(mesh(box(0.78, 0.035, 0.03), tc('#dfe6ee'), 0, 0.38 + i * 0.1, front + 0.01, false));
  }

  group.add(mergeByMaterial(stat));

  // Built facing +z; it stands against the east wall facing into the room (-x).
  group.position = vm.Vector3(lay.Jukebox.x, 0, lay.Jukebox.z);
  group.rotation = yaw(-math.pi / 2);

  // Notes drift up out of the top while it plays.
  final notes = [
    for (var i = 0; i < _notes.length; i++)
      labels.add(WorldLabel(anchor: group, child: _note(i, 0), alignment: Alignment.center, maxDistance: 25)..visible = false),
  ];

  final interactable = Interactable(kind: InteractKind.jukebox, x: lay.Jukebox.x - 1.3, z: lay.Jukebox.z, radius: 1.6);
  tagInteract(group, interactable);
  final view = JukeboxView._(group, jukeboxCollider(), interactable, neon, screenMat, notes);
  view.show(false, '');
  return view;
}
