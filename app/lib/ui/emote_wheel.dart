// The emote wheel: a port of ui/emotes.ts. Hold G, point the mouse at an emote and let go (or click
// it); a quick tap on G leaves it open until you pick one, press G or Esc, or click outside it.
// Also [EmotePop]: in first person you can't see the emoji over your head, so it pops up on screen.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:office_shared/emotes.dart';

import 'theme.dart';

/// How far (px) the mouse has to go from the middle of the wheel before it points at an emote.
const double kEmoteDeadZone = 26;

/// From the middle of the wheel to the middle of each emote, px.
const double kEmoteRadius = 104;

/// Letting go of G sooner than this (ms) leaves the wheel open to click; holding it picks on release.
const double kEmoteTapMs = 250;

/// The emotes go round clockwise from the top, a slice each.
final double _slice = math.pi * 2 / emotes.length;

/// Which emote the mouse points at, ([x], [y]) px from the middle of the wheel (y down), or -1.
int emoteAt(double x, double y) {
  if (math.sqrt(x * x + y * y) < kEmoteDeadZone) return -1;
  final a = math.atan2(y, x) + math.pi / 2;
  final n = emotes.length;
  return ((a / _slice).round() % n + n) % n;
}

/// Where emote [i] sits on the wheel, px from its middle (y down).
Offset emoteSpot(int i) {
  final a = i * _slice - math.pi / 2;
  return Offset(math.cos(a) * kEmoteRadius, math.sin(a) * kEmoteRadius);
}

class EmoteWheel extends ChangeNotifier {
  EmoteWheel({required this.onPick, this.onToggle, double Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch.toDouble());

  final void Function(Emote e) onPick;

  /// The wheel opened or closed: while it's open, the mouse is for picking, not for looking around.
  final void Function(bool open)? onToggle;
  final double Function() _now;

  bool isOpen = false;

  /// The emote the mouse points at, or -1.
  int at = -1;

  /// Mouse movement since the wheel opened, while the mouse is captured (there's no cursor then).
  Offset _aim = Offset.zero;

  /// When G went down to open it, while it's held; null once it stays open on its own.
  double? _heldAt;

  bool get held => _heldAt != null;

  /// G went down.
  void press() {
    if (isOpen) return close();
    isOpen = true;
    _heldAt = _now();
    _aim = Offset.zero;
    at = -1;
    onToggle?.call(true);
    notifyListeners();
  }

  /// G came back up: pick what it points at, or stay open after a quick tap.
  void release() {
    final heldAt = _heldAt;
    if (!isOpen || heldAt == null) return;
    if (at >= 0) {
      pick(at);
    } else if (_now() - heldAt < kEmoteTapMs) {
      _heldAt = null;
      notifyListeners();
    } else {
      close();
    }
  }

  /// A click with the mouse captured (first person): there's no cursor, so it picks what the wheel points at.
  void click() => pick(at);

  void close() {
    if (!isOpen) return;
    isOpen = false;
    _heldAt = null;
    onToggle?.call(false);
    notifyListeners();
  }

  /// Plays emote [i] (-1 picks nothing) and closes the wheel.
  void pick(int i) {
    close();
    if (i >= 0 && i < emotes.length) onPick(emotes[i]);
  }

  /// The captured mouse moved: kept within the ring, so turning back toward another emote answers straight away.
  void move(double dx, double dy) {
    if (!isOpen) return;
    var a = _aim + Offset(dx, dy);
    final d = a.distance;
    if (d > kEmoteRadius) a = a * (kEmoteRadius / d);
    _aim = a;
    aimAt(a.dx, a.dy);
  }

  /// The mouse is at ([x], [y]) px from the middle of the wheel.
  void aimAt(double x, double y) => point(emoteAt(x, y));

  void point(int i) {
    if (i == at) return;
    at = i;
    notifyListeners();
  }

  /// What the middle of the wheel says.
  ({String title, String how}) get caption {
    final e = at >= 0 ? emotes[at] : null;
    final how = e == null ? 'Point at one, or 1–6' : (held ? 'Let go of G' : 'Click');
    return (title: e?.label ?? 'Emote', how: how);
  }
}

/// The wheel over the middle of the screen while it's open.
class EmoteWheelView extends StatelessWidget {
  const EmoteWheelView({super.key, required this.wheel});

  final EmoteWheel wheel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: wheel,
    builder: (context, _) {
      if (!wheel.isOpen) return const SizedBox.shrink();
      final cap = wheel.caption;
      return LayoutBuilder(
        builder: (context, box) {
          final mid = box.biggest.center(Offset.zero);
          return MouseRegion(
            onHover: (e) => wheel.aimAt(e.localPosition.dx - mid.dx, e.localPosition.dy - mid.dy),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (e) {
                final i = emoteAt(e.localPosition.dx - mid.dx, e.localPosition.dy - mid.dy);
                final hit = i >= 0 && (e.localPosition - mid - emoteSpot(i)).distance < 40;
                wheel.pick(hit ? i : wheel.at);
              },
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(colors: [Color(0x472B2D42), Color(0x002B2D42)], stops: [0, 0.45]),
                ),
                child: Center(
                  child: SizedBox(
                    width: 288,
                    height: 288,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xE0FFFAF3),
                              shape: BoxShape.circle,
                              border: Border.all(color: Swatch.ink, width: kBorder),
                              boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
                            ),
                          ),
                        ),
                        for (final (i, e) in emotes.indexed) _item(i, e),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(cap.title, style: heavy(17, weight: FontWeight.w900)),
                              Text(cap.how, style: heavy(12, color: Swatch.muted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  Widget _item(int i, Emote e) {
    final at = emoteSpot(i) + const Offset(144, 144);
    final on = wheel.at == i;
    return Positioned(
      left: at.dx - 32,
      top: at.dy - 32,
      child: AnimatedScale(
        scale: on ? 1.18 : 1,
        duration: const Duration(milliseconds: 80),
        child: Tooltip(
          message: '${e.label} (${i + 1})',
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Swatch.accent : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Swatch.ink, width: kBorder),
              boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Text(e.emoji, style: heavy(30).copyWith(height: 1)),
                Positioned(
                  right: -10,
                  bottom: -10,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 20),
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      '${i + 1}',
                      style: heavy(12, color: Swatch.paper, weight: FontWeight.w900).copyWith(height: 1),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Your own emote's emoji in first person, popping up over the bottom of the screen.
class EmotePop extends StatelessWidget {
  const EmotePop({super.key, required this.pop});

  /// The emote to pop, and a count that goes up with each one (so the same emote twice pops twice).
  final ValueListenable<(Emote, int)?> pop;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder<(Emote, int)?>(
      valueListenable: pop,
      builder: (context, p, _) {
        if (p == null) return const SizedBox.shrink();
        final (e, n) = p;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 96),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(n),
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: (e.seconds * 1000).round()),
              builder: (context, u, _) {
                // Pops up big, settles, rises a little and fades at the end.
                final scale = u < 0.12 ? u / 0.12 * 1.25 : (u < 0.25 ? 1.25 - (u - 0.12) / 0.13 * 0.25 : 1.0);
                final fade = u > 0.8 ? (1 - u) / 0.2 : 1.0;
                return Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, -u * 40),
                    child: Transform.scale(
                      scale: scale,
                      child: Text(e.emoji, style: heavy(56).copyWith(height: 1)),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );
}
