// The widgets that float over the office on WorldLabels, drawn like the old canvas sprites:
// [TagPill] is textSprite() (a pill with an ink border: name tags, bubbles) and [TaskCard] is
// cardSprite() (a speech-bubble card with a status chip, a title and a body, and a tail).

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'toon.dart' show hex;

/// Canvas pixels of the old sprites to logical pixels here. The old 5px canvas border is 3px.
const double kLabelPx = 0.6;

/// A textSprite: [text] in heavy Nunito on a pill of [bg] with a 3px [border], sized from the old
/// canvas `size`.
class TagPill extends StatelessWidget {
  const TagPill(this.text, {super.key, this.bg, this.color = '#2b2d42', this.size = 48, this.border = '#2b2d42'});

  final String text;

  /// No pill, just the text, when null.
  final String? bg;
  final String color;
  final double size;
  final String border;

  @override
  Widget build(BuildContext context) {
    final h = size * 1.6 * kLabelPx;
    return Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: size * 0.5 * kLabelPx),
      alignment: Alignment.center,
      decoration: bg == null
          ? null
          : BoxDecoration(
              color: hex(bg!),
              borderRadius: BorderRadius.circular(h / 2),
              border: Border.all(color: hex(border), width: kBorder),
            ),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: heavy(size * kLabelPx, color: hex(color)).copyWith(height: 1.1, decoration: TextDecoration.none),
      ),
    );
  }
}

/// The status pill across a task card's top edge: "⌨️ WORKING".
class CardChip {
  const CardChip(this.text, this.bg, this.color);

  final String text;
  final String bg;
  final String color;
}

/// A cardSprite: a speech-bubble card with an optional [chip] over its top edge, a bold [title] (up
/// to 2 lines) and a smaller [body] (up to 3), and a tail pointing down. Hang it with
/// Alignment.bottomCenter so the tail's tip is on the anchor.
class TaskCard extends StatelessWidget {
  const TaskCard({super.key, this.chip, required this.title, this.body, required this.bg, this.maxWidth = 400});

  final CardChip? chip;
  final String title;
  final String? body;
  final String bg;

  /// Widest a line may get, in old canvas pixels.
  final double maxWidth;

  static const double _s = kLabelPx;
  static const double pad = 16 * _s;
  static const double lw = kBorder;
  static const double tail = 14 * _s;
  static const double chipH = 30 * _s;

  @override
  Widget build(BuildContext context) {
    final maxW = maxWidth * _s;
    final c = chip;
    final top = c != null ? lw / 2 : lw + pad;
    return CustomPaint(
      painter: _CardPainter(hex(bg), top: c != null ? chipH / 2 : lw),
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, top, pad, pad * 0.7 + tail + lw),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (c != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: pad),
                  child: Container(
                    height: chipH,
                    padding: const EdgeInsets.symmetric(horizontal: 12 * _s),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: hex(c.bg),
                      borderRadius: BorderRadius.circular(chipH / 2),
                      border: Border.all(color: Swatch.ink, width: 4 * _s),
                    ),
                    child: Text(c.text, maxLines: 1, style: heavy(19 * _s, color: hex(c.color)).copyWith(height: 1.1, decoration: TextDecoration.none)),
                  ),
                ),
                const SizedBox(height: 6 * _s),
              ],
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textWidthBasis: TextWidthBasis.longestLine,
                style: heavy(30 * _s).copyWith(height: 36 / 30, decoration: TextDecoration.none),
              ),
              if (body != null && body!.isNotEmpty) ...[
                const SizedBox(height: 4 * _s),
                Text(
                  body!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: heavy(23 * _s, color: hex('#5c5f77'), weight: FontWeight.w700).copyWith(height: 29 / 23, decoration: TextDecoration.none),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The card and its tail in one outline, so the border runs unbroken down the tail.
class _CardPainter extends CustomPainter {
  _CardPainter(this.bg, {required this.top});

  final Color bg;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    const lw = TaskCard.lw, tail = TaskCard.tail, r = 18 * kLabelPx;
    final x0 = lw / 2, x1 = size.width - lw / 2, cx = size.width / 2;
    final bottom = size.height - tail - lw;
    final path = Path()
      ..moveTo(x0 + r, top)
      ..lineTo(x1 - r, top)
      ..arcToPoint(Offset(x1, top + r), radius: const Radius.circular(r))
      ..lineTo(x1, bottom - r)
      ..arcToPoint(Offset(x1 - r, bottom), radius: const Radius.circular(r))
      ..lineTo(cx + tail, bottom)
      ..lineTo(cx, bottom + tail)
      ..lineTo(cx - tail, bottom)
      ..lineTo(x0 + r, bottom)
      ..arcToPoint(Offset(x0, bottom - r), radius: const Radius.circular(r))
      ..lineTo(x0, top + r)
      ..arcToPoint(Offset(x0 + r, top), radius: const Radius.circular(r))
      ..close();
    canvas.drawPath(path, Paint()..color = bg);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lw
        ..strokeJoin = StrokeJoin.round
        ..color = Swatch.ink,
    );
  }

  @override
  bool shouldRepaint(_CardPainter old) => old.bg != bg || old.top != top;
}
