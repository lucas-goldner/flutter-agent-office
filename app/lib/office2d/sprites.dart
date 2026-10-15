// The 2D map's people and workers as 16-bit sprites (retro.dart), on the same pixel grid as the map:
// workers are the 3D office's beans (world/character.dart: their color, big eyes, a headset, and the
// antenna whose bulb says how they're doing), people the character screen's chibis (ui/chibi.dart:
// a big head with its hair style, the shirt, little legs). Each look, pose and frame is drawn once
// into a small image and kept.

import 'dart:math' as math;
import 'dart:ui';

import 'package:office_shared/avatar.dart';

import 'map_painter.dart' show MapStatus, mapColor;
import 'retro.dart';

/// The bulb on a worker's antenna, as in 3D (world/character.dart's statusBulb).
const Map<MapStatus, Color> kBulb = {
  MapStatus.starting: Color(0xFFADB5BD),
  MapStatus.idle: Color(0xFF8ECAE6),
  MapStatus.working: Color(0xFFFFD166),
  MapStatus.needsInput: Color(0xFFEF476F),
  MapStatus.done: Color(0xFF06D6A0),
  MapStatus.off: Color(0xFF6C757D),
};

const _dark = Color(0xFF2B2D42);
const _white = Color(0xFFFFFFFF);
const _blush = Color(0xFFFF8FA3);

/// A sprite and the pixel its feet stand on.
typedef Sprite = ({Image image, int footX, int footY});

/// Makes and keeps the sprites.
class SpriteBook {
  final Map<String, Sprite> _cache = {};

  Sprite _keep(String key, Sprite Function() make) => _cache.putIfAbsent(key, make);

  /// A worker on its chair: [blink] with its eyes shut, [lit] with its bulb glinting.
  Sprite worker(Color body, MapStatus status, {bool blink = false, bool lit = false}) =>
      _keep('w|${body.toARGB32()}|${status.index}|$blink|$lit', () {
        final g = SpriteGrid(18, 23);
        const top = 3; // the antenna and its bulb above the bean
        // Arms and feet, then the bean over them.
        g.ball(2.2, top + 11.5, 1.6, 2.6, body);
        g.ball(15.8, top + 11.5, 1.6, 2.6, body);
        g.ball(5.5, top + 18.2, 2.4, 1.5, body);
        g.ball(12.5, top + 18.2, 2.4, 1.5, body);
        g.ball(9, top + 10, 6.6, 8, body);
        // The headset: its band over the top of the bean and the cups at the sides.
        for (var x = 3; x <= 14; x++) {
          final nx = (x + 0.5 - 9) / 6.9;
          final y = (top + 10 - 8.3 * math.sqrt(math.max(0, 1 - nx * nx))).round();
          g.set(x, y, ramp(_dark)[2], _dark);
        }
        g.ball(2.7, top + 8, 1.5, 1.8, _dark);
        g.ball(15.3, top + 8, 1.5, 1.8, _dark);
        // The antenna, and its bulb in the worker's status color.
        for (var y = 2; y < top + 2; y++) {
          g.set(9, y, ramp(_dark)[3], _dark);
        }
        final bulb = kBulb[status]!;
        g.ball(9, 1.6, 1.7, 1.7, bulb);
        if (lit) g.set(8, 1, ramp(bulb)[4], bulb);
        // Big eyes: whites with a dark pupil and a glint, or shut in a blink.
        for (final ex in [6, 11]) {
          if (blink) {
            for (var x = ex - 1; x <= ex + 1; x++) {
              g.set(x, top + 9, ramp(body)[0], body);
            }
            continue;
          }
          for (var y = top + 7; y <= top + 10; y++) {
            for (var x = ex - 1; x <= ex + 1; x++) {
              g.set(x, y, _white, _dark);
            }
          }
          g.set(ex, top + 8, _dark);
          g.set(ex + 1, top + 8, _dark);
          g.set(ex, top + 9, _dark);
          g.set(ex + 1, top + 9, _dark);
          g.set(ex, top + 8, _white, _dark);
        }
        // Blush and a little smile.
        g.set(4, top + 11, _blush, body);
        g.set(13, top + 11, _blush, body);
        g.set(8, top + 12, ramp(body)[0], body);
        g.set(9, top + 12, ramp(body)[0], body);
        g.outline();
        return (image: g.toImage(), footX: 9, footY: 22);
      });

  /// A person: [back] from behind (walking up the map), [step] which foot is forward while walking.
  Sprite person(Look look, Color shirt, {bool back = false, int step = 0, bool sitting = false}) =>
      _keep('p|${look.skin}|${look.hair}|${look.style}|${shirt.toARGB32()}|$back|$step|$sitting', () {
        final skin = mapColor(skinTones[look.skin.clamp(0, skinTones.length - 1)]);
        final hair = mapColor(hairColors[look.hair.clamp(0, hairColors.length - 1)]);
        final g = SpriteGrid(16, 23);
        const cx = 8.0, hy = 8.0; // the middle of the head
        // Hair that hangs behind: long hair down the back, a ponytail.
        if (look.style == 1) g.box(2, 7, 13, 14, hair);
        if (look.style == 5) g.ball(back ? 8 : 14, 11, 1.6, 3, hair);
        // Legs (or a lap, sitting), then the shirt and hands.
        if (!sitting) {
          final l = step == 1 ? 1 : 0, r = step == 2 ? 1 : 0;
          g.box(5, 18 - l, 6, 21 - l, _dark, flat: true);
          g.box(9, 18 - r, 10, 21 - r, _dark, flat: true);
        } else {
          g.box(5, 18, 10, 19, _dark, flat: true);
        }
        g.box(4, 14, 11, 18, shirt);
        g.ball(3.2, 16.5, 1.3, 1.3, skin);
        g.ball(12.8, 16.5, 1.3, 1.3, skin);
        // The big head.
        g.ball(cx, hy, 6.4, 5.8, back ? hair : skin);
        if (!back) {
          g.ball(1.8, hy + 1, 1.1, 1.5, skin);
          g.ball(14.2, hy + 1, 1.1, 1.5, skin);
        }
        // Hair on top, by style.
        final r = ramp(hair);
        void cap(double upTo) {
          for (var y = 0; y < 23; y++) {
            for (var x = 0; x < 16; x++) {
              final nx = (x + 0.5 - cx) / 6.6, ny = (y + 0.5 - hy) / 6.0;
              if (nx * nx + ny * ny > 1 || y + 0.5 > hy + upTo) continue;
              // A side fringe: lower on the left.
              if (y + 0.5 > hy - 1.2 && x > 6) continue;
              g.set(x, y, r[litShade(nx, ny, math.sqrt(math.max(0, 1 - nx * nx - ny * ny)))], hair);
            }
          }
        }

        switch (look.style) {
          case 6: // Bald: a shine instead.
            if (!back) g.set(5, 4, ramp(skin)[4], skin);
          case 3: // Spiky
            cap(0);
            for (final x in [3, 6, 9, 12]) {
              g.set(x, 1, r[3], hair);
              g.set(x, 0, r[4], hair);
              g.set(x + 1, 1, r[2], hair);
            }
          case 4: // Curly
            cap(0);
            for (var i = 0; i < 6; i++) {
              final a = math.pi + 0.2 + i * (math.pi - 0.4) / 5;
              g.ball(cx + math.cos(a) * 6.2, hy + math.sin(a) * 5.4, 1.7, 1.7, hair);
            }
          default:
            cap(0);
            if (look.style == 2) g.ball(cx, 1.4, 2.2, 1.6, hair); // a bun
        }
        if (!back) {
          // Eyes, blush and a little mouth.
          for (final ex in [5, 10]) {
            g.set(ex, 9, _dark);
            g.set(ex, 10, _dark);
          }
          g.set(4, 11, _blush, skin);
          g.set(11, 11, _blush, skin);
          g.set(7, 12, ramp(skin)[0], skin);
          g.set(8, 12, ramp(skin)[0], skin);
        }
        g.outline();
        return (image: g.toImage(), footX: 8, footY: 22);
      });

  /// The office dog, trotting ([step]) or still, facing [left] or right.
  Sprite dog({int step = 0, bool left = false}) => _keep('d|$step|$left', () {
    const coat = Color(0xFFC68642), dark = Color(0xFF6F4E37);
    final g = SpriteGrid(16, 11);
    g.ball(7, 6, 4.6, 2.8, coat);
    g.ball(12, 3.6, 2.6, 2.4, coat);
    g.ball(14.3, 4.4, 1.3, 1, coat); // the snout
    g.set(15, 4, _dark);
    g.ball(10.8, 2, 1, 1.6, dark); // an ear
    g.set(12, 3, _dark);
    for (final (x, up) in [(4, step == 1), (6, step == 2), (9, step == 2), (11, step == 1)]) {
      g.box(x, up ? 7 : 8, x, up ? 9 : 10, dark, flat: true);
    }
    g.ball(2.2, step == 0 ? 3.5 : 4.5, 1, 1.6, coat); // the tail
    g.outline();
    var image = g.toImage();
    if (left) {
      final rec = PictureRecorder();
      Canvas(rec)
        ..translate(16, 0)
        ..scale(-1, 1)
        ..drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.none);
      image = rec.endRecording().toImageSync(16, 11);
    }
    return (image: image, footX: 8, footY: 10);
  });

  /// A worker's bubble: ! when it needs you, a tick when it's done, dots while it works ([dots] of 3).
  Sprite bubble(MapStatus s, {int dots = 3}) => _keep('b|${s.index}|$dots', () {
    final g = SpriteGrid(11, 11);
    final bg = switch (s) {
      MapStatus.needsInput => const Color(0xFFFFD166),
      MapStatus.done => const Color(0xFF06D6A0),
      _ => _white,
    };
    g.box(1, 1, 9, 7, bg);
    g.set(4, 8, ramp(bg)[2], bg);
    g.set(5, 8, ramp(bg)[2], bg);
    g.set(4, 9, ramp(bg)[1], bg);
    switch (s) {
      case MapStatus.needsInput:
        for (var y = 2; y <= 4; y++) {
          g.set(5, y, _dark);
        }
        g.set(5, 6, _dark);
      case MapStatus.done:
        for (final (x, y) in [(3, 4), (4, 5), (5, 4), (6, 3), (7, 2)]) {
          g.set(x, y, _white, bg);
        }
      default:
        for (var i = 0; i < dots; i++) {
          g.set(3 + i * 2, 4, _dark);
        }
    }
    g.outline();
    return (image: g.toImage(), footX: 5, footY: 10);
  });

  /// The yellow arrow over your head.
  Sprite marker() => _keep('m', () {
    const y = Color(0xFFFFD166);
    final g = SpriteGrid(9, 6);
    for (var row = 0; row < 4; row++) {
      for (var x = 1 + row; x <= 7 - row; x++) {
        g.set(x, row + 1, ramp(y)[row == 0 ? 4 : (x == 1 + row ? 3 : 2)], y);
      }
    }
    g.outline();
    return (image: g.toImage(), footX: 4, footY: 5);
  });
}

final Paint _pixels = Paint()..filterQuality = FilterQuality.none;

/// Draws [s] with its feet on map pixel (x, y), in the map's pixels (the canvas scaled to them).
void drawSprite(Canvas canvas, Sprite s, double x, double y) =>
    canvas.drawImage(s.image, Offset((x - s.footX).roundToDouble(), (y - s.footY).roundToDouble()), _pixels);
