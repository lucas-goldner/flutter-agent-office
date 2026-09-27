// Bits the HUD's windows share, from style.css: the bold field label, the muted notes, the
// coloured status boxes, a command block with its Copy button, the OS tabs, and the spinner.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

const kMono = 'monospace';

/// The .modal label: bold, above what it names.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.top = 0});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 6),
    child: Text(text, style: heavy(14)),
  );
}

/// The muted explanation under a setting (.setting-note, .note).
class Note extends StatelessWidget {
  const Note(this.text, {super.key, this.top = 10, this.size = 13, this.bad = false, this.rich});

  final String text;
  final double top;
  final double size;
  final bool bad;

  /// In place of [text], for notes with code in them.
  final List<InlineSpan>? rich;

  @override
  Widget build(BuildContext context) {
    final style = heavy(size, color: bad ? Swatch.bad : Swatch.muted, weight: FontWeight.w600).copyWith(height: 1.45);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: rich == null ? Text(text, style: style) : Text.rich(TextSpan(children: rich), style: style),
    );
  }
}

/// Inline code in a note.
InlineSpan codeSpan(String text) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(color: Swatch.paper2, borderRadius: BorderRadius.circular(5)),
    child: Text(
      text,
      style: const TextStyle(fontFamily: kMono, fontSize: 12, color: Swatch.ink),
    ),
  ),
);

enum StatusKind { busy, ok, error }

/// The .team-status / .upgrade-status box: blue while busy, green when it worked, pink when not.
class StatusBox extends StatelessWidget {
  const StatusBox(
    this.text, {
    super.key,
    this.kind = StatusKind.busy,
    this.spinner = false,
    this.top = 10,
    this.center = false,
  });

  final String text;
  final StatusKind kind;
  final bool spinner;
  final double top;
  final bool center;

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(top: top),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: switch (kind) {
        StatusKind.busy => const Color(0xFFE0F2FE),
        StatusKind.ok => const Color(0xFFD8F5E3),
        StatusKind.error => const Color(0xFFFFD6E0),
      },
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: Row(
      mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        if (spinner) ...[const Spinner(), const SizedBox(width: 8)],
        Flexible(child: Text(text, style: heavy(14))),
      ],
    ),
  );
}

/// The .spinner: a 16px ring with an ink arc going round.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.light = false});

  final bool light;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(
      strokeWidth: 3,
      color: light ? Colors.white : Swatch.ink,
      backgroundColor: light ? Colors.white.withValues(alpha: 0.25) : Swatch.ink.withValues(alpha: 0.2),
    ),
  );
}

/// Copies [text] to the clipboard; false when the browser wouldn't.
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// A button that copies, and says so for a moment.
class CopyButton extends StatefulWidget {
  const CopyButton({super.key, required this.label, required this.text, this.kind = BtnKind.plain, this.dense = false});

  final String label;
  final String Function() text;
  final BtnKind kind;
  final bool dense;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  String? _said;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final ok = await copyText(widget.text());
    if (!mounted) return;
    setState(() => _said = ok ? '✓ Copied' : 'Copy failed');
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _said = null);
    });
  }

  @override
  Widget build(BuildContext context) =>
      OfficeButton(label: _said ?? widget.label, kind: widget.kind, dense: widget.dense, onPressed: _copy);
}

/// A command to run, dark like a terminal, with Copy beside it (.cmd).
class CommandBlock extends StatelessWidget {
  const CommandBlock(this.command, {super.key, this.top = 8});

  final String command;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Swatch.termBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Swatch.ink, width: 2),
            ),
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: kMono, fontSize: 13, height: 1.5, color: Color(0xFFE9ECEF)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        CopyButton(label: 'Copy', text: () => command),
      ],
    ),
  );
}

/// A row of small toggle buttons (.os-tabs, .seg).
class SegButtons<T> extends StatelessWidget {
  const SegButtons({
    super.key,
    required this.options,
    required this.value,
    required this.onPick,
    this.small = true,
    this.gap = 4,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onPick;
  final bool small;
  final double gap;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: gap,
    runSpacing: gap,
    children: [
      for (final (v, label) in options)
        SmallButton(
          label: label,
          kind: v == value ? BtnKind.on : BtnKind.plain,
          small: small,
          onPressed: () => onPick(v),
        ),
    ],
  );
}

/// A .btn with the smaller padding the lists and tabs use (3px 10px, 13px).
class SmallButton extends StatefulWidget {
  const SmallButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = BtnKind.plain,
    this.small = true,
    this.tooltip,
    this.leading,
  });

  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool small;
  final String? tooltip;
  final Widget? leading;

  @override
  State<SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<SmallButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (Swatch.accent, Colors.white),
      BtnKind.on => (Swatch.good, Colors.white),
      BtnKind.danger => (Swatch.bad, Colors.white),
      BtnKind.plain => (_hover && enabled ? Swatch.paper2 : Colors.white, Swatch.ink),
    };
    Widget b = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
            padding: widget.small
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 3)
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Swatch.ink, width: kBorder),
              boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, _down ? 1 : 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 6)],
                Text(widget.label, style: heavy(widget.small ? 13 : 14, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// The .modal text input: white, 3px ink border turning orange with focus, 15px.
class BoxInput extends StatelessWidget {
  const BoxInput({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint,
    this.maxLength,
    this.autofocus = false,
    this.readOnly = false,
    this.enabled = true,
    this.onSubmitted,
    this.onChanged,
    this.tooltip,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;
  final int? maxLength;
  final bool autofocus;
  final bool readOnly;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      readOnly: readOnly,
      enabled: enabled,
      maxLength: maxLength,
      autocorrect: false,
      enableSuggestions: false,
      style: heavy(15, weight: FontWeight.w400),
      cursorColor: Swatch.ink,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: heavy(15, color: Swatch.muted, weight: FontWeight.w400),
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      ),
      onSubmitted: onSubmitted,
      onChanged: onChanged,
    );
    return tooltip == null ? field : Tooltip(message: tooltip!, child: field);
  }
}

/// The footer's left side: small muted text that takes the room (.grow).
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

/// A footer: [left] grows, the buttons sit right, 8px apart.
Widget footerRow(List<Widget> children) => Row(
  children: [
    for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(width: 8), c],
  ],
);

/// A small heading inside a window (.team h4): uppercase, with a muted count.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.count, this.top = 18, this.bottom = 8});

  final String title;
  final int? count;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: bottom),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title.toUpperCase()),
          if (count != null)
            TextSpan(
              text: ' $count',
              style: const TextStyle(color: Swatch.muted),
            ),
        ],
      ),
      style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.56),
    ),
  );
}

/// Calls [fn] on every change of any of [listenables] while the widget is up.
mixin ListenTo<T extends StatefulWidget> on State<T> {
  final List<VoidCallback> _offs = [];

  void listenTo(Listenable l, VoidCallback fn) {
    l.addListener(fn);
    _offs.add(() => l.removeListener(fn));
  }

  void listenStream<E>(Stream<E> s, void Function(E) fn) {
    final sub = s.listen(fn);
    _offs.add(sub.cancel);
  }

  @override
  void dispose() {
    for (final off in _offs) {
      off();
    }
    super.dispose();
  }
}

/// A rebuild every [every], for "3m ago".
mixin Ticking<T extends StatefulWidget> on State<T> {
  Timer? _tick;

  void tickEvery(Duration every) {
    _tick?.cancel();
    _tick = Timer.periodic(every, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}
