// A .btn with any content (a dot, a name and a small status, say), for the places where the old
// windows put more than a label in a button. Looks and presses like OfficeButton; it can take focus,
// and Enter or Space presses it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class ChildButton extends StatefulWidget {
  const ChildButton({
    super.key,
    required this.child,
    this.onPressed,
    this.kind = BtnKind.plain,
    this.tooltip,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    this.fontSize = 13,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final double fontSize;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<ChildButton> createState() => _ChildButtonState();
}

class _ChildButtonState extends State<ChildButton> {
  bool _hover = false;
  bool _down = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (Swatch.accent, Colors.white),
      BtnKind.on => (Swatch.good, Colors.white),
      BtnKind.danger => (Swatch.bad, Colors.white),
      BtnKind.plain => (_hover ? Swatch.paper2 : Colors.white, Swatch.ink),
    };
    Widget b = FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      shortcuts: const {SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(), SingleActivator(LogicalKeyboardKey.space): ActivateIntent()},
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed?.call())},
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _focused ? Swatch.accent : Swatch.ink, width: kBorder),
            boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, _down ? 0 : 2))],
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: DefaultTextStyle(
              style: heavy(widget.fontSize, color: fg),
              child: IconTheme(
                data: IconThemeData(color: fg, size: widget.fontSize + 2),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// The .spinner: a 16px ring that turns.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 16, this.color = Swatch.ink});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(strokeWidth: 3, color: color, backgroundColor: color.withValues(alpha: 0.2)),
  );
}

/// A multi-line box where Enter sends and Shift+Enter starts a new line (the prompt textareas).
class PromptField extends StatelessWidget {
  const PromptField({
    super.key,
    required this.controller,
    required this.onSend,
    this.focusNode,
    this.hint,
    this.minLines = 5,
    this.maxLines = 12,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final FocusNode? focusNode;
  final String? hint;
  final int minLines;
  final int maxLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, e) {
      if (e is KeyDownEvent &&
          e.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed &&
          !controller.value.composing.isValid) {
        onSend();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: TextInputType.multiline,
      style: heavy(15, weight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: heavy(15, color: Swatch.muted, weight: FontWeight.w600),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
  );
}

/// The footer's grow text: 12px muted.
class FooterNote extends StatelessWidget {
  const FooterNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Text(
      text,
      style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
    ),
  );
}
