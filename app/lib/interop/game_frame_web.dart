import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// [src] in an iframe drawn at a fixed [width]×[height] and scaled to fill the box it's laid in,
/// so the game costs the same whatever the window size. Keys go straight to it once it loads.
class GameFrame extends StatefulWidget {
  const GameFrame({super.key, required this.src, required this.title, required this.width, required this.height});

  final String src;
  final String title;
  final int width;
  final int height;

  @override
  State<GameFrame> createState() => _GameFrameState();
}

class _GameFrameState extends State<GameFrame> {
  web.HTMLIFrameElement? _frame;
  double _scale = 1;

  void _created(Object host) {
    final div = host as web.HTMLDivElement;
    div.style
      ..overflow = 'hidden'
      ..background = '#0b1320';
    final frame = web.document.createElement('iframe') as web.HTMLIFrameElement;
    frame
      ..src = widget.src
      ..title = widget.title
      ..allow = 'autoplay; fullscreen; gamepad';
    frame.style
      ..display = 'block'
      ..border = '0'
      ..width = '${widget.width}px'
      ..height = '${widget.height}px'
      ..transformOrigin = '0 0'
      ..transform = 'scale($_scale)';
    frame.addEventListener('load', ((web.Event _) => frame.focus()).toJS);
    div.append(frame);
    _frame = frame;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _scale = box.maxWidth / widget.width;
      _frame?.style.transform = 'scale($_scale)';
      return HtmlElementView.fromTagName(tagName: 'div', onElementCreated: _created);
    },
  );
}
