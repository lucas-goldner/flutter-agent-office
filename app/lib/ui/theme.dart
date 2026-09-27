// The office's chunky cartoon look, from the old client's style.css: paper panels with a 3px ink
// border and a hard offset shadow, heavy rounded type (Nunito 800/900), and bright status colours.

import 'package:flutter/material.dart';

abstract final class Swatch {
  static const ink = Color(0xFF2B2D42);
  static const paper = Color(0xFFFFFAF3);
  static const paper2 = Color(0xFFFFF1DE);
  static const accent = Color(0xFFFF8A5B);
  static const muted = Color(0xFF7A6F65);
  static const good = Color(0xFF06D6A0);
  static const warn = Color(0xFFFFD166);
  static const bad = Color(0xFFEF476F);
  static const info = Color(0xFF5BC0EB);
  static const sky = Color(0xFFBFE3FF);
  static const termBg = Color(0xFF1E1F2E);
  static const backdrop = Color(0x732B2D42); // rgba(43,45,66,.45)
}

const kFont = 'Nunito';
const kBorder = 3.0;

ThemeData officeTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: kFont,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Swatch.accent,
      primary: Swatch.accent,
      surface: Swatch.paper,
      onSurface: Swatch.ink,
      error: Swatch.bad,
    ),
    scaffoldBackgroundColor: Swatch.sky,
  );
  OutlineInputBorder box(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: kBorder),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Swatch.ink, displayColor: Swatch.ink, fontFamily: kFont),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: box(Swatch.ink),
      enabledBorder: box(Swatch.ink),
      focusedBorder: box(Swatch.accent),
      labelStyle: const TextStyle(fontWeight: FontWeight.w800, color: Swatch.ink),
    ),
    tooltipTheme: const TooltipThemeData(
      textStyle: TextStyle(fontFamily: kFont, fontWeight: FontWeight.w700, color: Colors.white, fontSize: 12),
      decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.all(Radius.circular(8))),
    ),
  );
}

/// Heavy text in the office's type.
TextStyle heavy(double size, {Color color = Swatch.ink, FontWeight weight = FontWeight.w800}) =>
    TextStyle(fontFamily: kFont, fontSize: size, fontWeight: weight, color: color, height: 1.25);

/// A paper panel: 3px ink border, rounded, with a hard shadow straight down (no blur).
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = 16,
    this.shadow = 4,
    this.color = Swatch.paper,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double shadow;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Swatch.ink, width: kBorder),
      boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, shadow))],
    ),
    child: child,
  );
}

enum BtnKind { plain, primary, on, danger }

/// The .btn: white, ink border, radius 12, 14px/800. It sinks 2px while pressed.
class OfficeButton extends StatefulWidget {
  const OfficeButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = BtnKind.plain,
    this.tooltip,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final String? tooltip;
  final bool dense;

  @override
  State<OfficeButton> createState() => _OfficeButtonState();
}

class _OfficeButtonState extends State<OfficeButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (Swatch.accent, Colors.white),
      BtnKind.on => (Swatch.good, Colors.white),
      BtnKind.danger => (Swatch.bad, Colors.white),
      BtnKind.plain => (_hover ? Swatch.paper2 : Colors.white, Swatch.ink),
    };
    final shadow = _down ? 0.0 : 2.0;
    Widget b = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
          padding: widget.dense
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Swatch.ink, width: kBorder),
            boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, shadow))],
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Text(widget.label, style: heavy(widget.dense ? 12 : 14, color: fg)),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// A small status pill: 11px/900 with a 2px border.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = Colors.white, this.textColor = Swatch.ink});

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: Text(text, style: heavy(11, color: textColor, weight: FontWeight.w900)),
  );
}

/// A 12px colour dot with a 2px ink ring.
class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Swatch.ink, width: 2),
    ),
  );
}

/// A labelled text field, the way the old forms laid them out: bold label above the input.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.autofocus = false,
    this.readOnly = false,
    this.maxLength,
    this.focusNode,
    this.onSubmitted,
    this.autofillHints,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool autofocus;
  final bool readOnly;
  final int? maxLength;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: heavy(14)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          autofocus: autofocus,
          readOnly: readOnly,
          maxLength: maxLength,
          autofillHints: autofillHints,
          style: heavy(15, weight: FontWeight.w700),
          decoration: const InputDecoration(counterText: ''),
          onSubmitted: onSubmitted,
        ),
      ],
    ),
  );
}
