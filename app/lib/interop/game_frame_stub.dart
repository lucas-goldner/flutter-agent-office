import 'package:flutter/widgets.dart';

/// Off the web there's no page to show: a dark screen.
class GameFrame extends StatelessWidget {
  const GameFrame({super.key, required this.src, required this.title, required this.width, required this.height});

  final String src;
  final String title;
  final int width;
  final int height;

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF0B1320));
}
