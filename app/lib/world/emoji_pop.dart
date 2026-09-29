// The emoji an emote pops up over someone's head (the old textSprite of size 72): it pops in,
// wobbles, and fades at the end. The character drives [scale], [angle] and [opacity] every frame.

import 'package:flutter/widgets.dart';

import '../ui/theme.dart' show heavy;
import 'label_widgets.dart' show kLabelPx;

class EmojiPop extends StatelessWidget {
  const EmojiPop(this.emoji, {super.key, this.scale = 1, this.angle = 0, this.opacity = 1, this.size = 72});

  final String emoji;
  final double scale;
  final double angle;
  final double opacity;

  /// The old canvas font size.
  final double size;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity.clamp(0.0, 1.0),
    child: Transform.rotate(
      angle: angle,
      child: Transform.scale(
        scale: scale.clamp(0.001, 2.0),
        child: Text(emoji, style: heavy(size * kLabelPx).copyWith(height: 1.1, decoration: TextDecoration.none)),
      ),
    ),
  );
}
