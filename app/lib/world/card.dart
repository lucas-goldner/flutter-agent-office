// An issue's sticky note taken off the issues board, held in someone's hands: a thin card in the
// note's colour with the pin, the number and the title on its front (+z). A port of world/card.ts.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../ui/gh_logic.dart' show kNoteColors, kPins;
import '../ui/theme.dart' show kFallback, kFont;
import 'geo.dart' show box;
import 'text.dart' show pictureTexture, verticalPlane;
import 'toon.dart';

const int _w = 320, _h = 240;

/// The note's front: its colour, pin, number and up to four lines of title.
ui.Picture _paintCard(CarriedIssue card) {
  final rec = ui.PictureRecorder();
  final g = Canvas(rec);
  g.drawRect(
    const Rect.fromLTWH(0, 0, _w * 1.0, _h * 1.0),
    Paint()..color = kNoteColors[card.issue % kNoteColors.length],
  );
  TextStyle style(double size, FontWeight weight) => TextStyle(
    fontFamily: kFont,
    fontFamilyFallback: kFallback,
    fontSize: size,
    fontWeight: weight,
    color: const Color(0xFF2B2D42),
  );
  final number = TextPainter(
    text: TextSpan(text: '#${card.issue}', style: style(52, FontWeight.w900)),
    textDirection: TextDirection.ltr,
  )..layout();
  number.paint(g, const Offset(22, 32));
  final title = TextPainter(
    text: TextSpan(
      text: card.title,
      style: style(28, FontWeight.w700).copyWith(height: 30 / 28),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 4,
    ellipsis: '…',
  )..layout(maxWidth: _w - 44);
  title.paint(g, const Offset(22, 104));
  const pin = Offset(_w / 2, 20);
  g.drawCircle(pin, 12, Paint()..color = kPins[card.issue % kPins.length]);
  g.drawCircle(
    pin,
    12,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF2B2D42),
  );
  return rec.endRecording();
}

/// A card [width] meters wide: paper in the note's colour, the note on its front.
Node issueCard(CarriedIssue card, double width) {
  final height = width * _h / _w;
  final color = kNoteColors[card.issue % kNoteColors.length];
  final node = Node(name: 'card:${card.issue}');
  node.add(mesh(box(width, height, width * 0.02), toon(color), 0, 0, 0, false));
  final face = UnlitMaterial()..baseColorFactor = linear(color, 1);
  node.add(mesh(verticalPlane(width, height), face, 0, 0, width * 0.011, false));
  pictureTexture(_paintCard(card), _w, _h).then((tex) {
    face.baseColorTexture = tex;
    face.baseColorFactor = vm.Vector4(1, 1, 1, 1);
  });
  return node;
}

/// The issue card someone holds, under [parent]: swapped for another card, or dropped (null).
class HeldCard {
  HeldCard(this.parent, this.width, {this.onAdd});

  final Node parent;
  final double width;

  /// Called with a new card's node once it's under [parent] (the hands put it on their layer).
  final void Function(Node node)? onAdd;
  Node? _node;
  int _issue = 0;

  bool get held => _node != null;

  void set(CarriedIssue? card) {
    if ((card?.issue ?? 0) == _issue) return;
    _node?.detach();
    _node = null;
    _issue = card?.issue ?? 0;
    if (card == null) return;
    final n = issueCard(card, width);
    parent.add(n);
    _node = n;
    onAdd?.call(n);
  }
}
