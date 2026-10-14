// The command palette (Ctrl+K, ⌘K on a Mac; ui/palette.ts): a few letters find a worker, an issue, a pull
// request, a board, a teammate or an action, and Enter opens it the way clicking it in the office does.
// Shift+Enter walks you over to it first. What there is to find comes from office/palette_entries.dart; the
// matching and ranking are office_shared's palette.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:office_shared/palette.dart';

import 'modal.dart';
import 'theme.dart';

/// One thing the palette finds.
class PaletteRow implements PaletteItem {
  PaletteRow({
    required this.icon,
    required this.kind,
    required this.title,
    this.detail,
    this.keywords = const [],
    required this.open,
    this.walk,
  });

  final String icon;

  /// What kind of thing it is, shown on the right: "Worker", "PR", "Action".
  final String kind;
  @override
  final String title;
  @override
  final String? detail;
  @override
  final List<String?> keywords;

  /// Opens it, as clicking it (or E in front of it) in the office does.
  final VoidCallback open;

  /// Walks you over to it and then opens it; null for things that aren't anywhere in the room.
  final VoidCallback? walk;
}

ModalHandle? _current;

bool paletteOpen() => _current != null && !_current!.closed;

/// The palette's own text box, so Ctrl+K there puts it away rather than being the box's.
final FocusNode paletteFocus = FocusNode(debugLabel: 'palette');

/// Opens the palette over [entries], or puts it away if it's open already.
void togglePalette(List<PaletteRow> Function() entries) {
  final cur = _current;
  if (cur != null && !cur.closed) return cur.close();
  final all = entries();
  _current = ModalStack.instance.show(
    (modal) => _PaletteWindow(modal: modal, all: all),
    onClose: () => _current = null,
  );
}

class _PaletteWindow extends StatefulWidget {
  const _PaletteWindow({required this.modal, required this.all});
  final ModalHandle modal;
  final List<PaletteRow> all;

  @override
  State<_PaletteWindow> createState() => _PaletteWindowState();
}

class _PaletteWindowState extends State<_PaletteWindow> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late List<PaletteMatch<PaletteRow>> _found = rankItems('', widget.all);
  int _at = 0;

  static const double _rowH = 46;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => paletteFocus.requestFocus());
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _render() => setState(() {
    _found = rankItems(_query.text, widget.all);
    _at = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  void _select(int i) {
    if (_found.isEmpty) return;
    setState(() => _at = (i + _found.length) % _found.length);
    // Keep it in view.
    if (!_scroll.hasClients) return;
    final top = _at * (_rowH + 2), p = _scroll.position;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowH > p.pixels + p.viewportDimension) {
      _scroll.jumpTo((top + _rowH - p.viewportDimension).clamp(0, p.maxScrollExtent));
    }
  }

  void _go(int i, bool walk) {
    if (i < 0 || i >= _found.length) return;
    final e = _found[i].item;
    widget.modal.close();
    if (walk && e.walk != null) {
      e.walk!();
    } else {
      e.open();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _select(_at + 1);
      case LogicalKeyboardKey.arrowUp:
        _select(_at - 1);
      case LogicalKeyboardKey.pageDown:
        _select((_at + 8).clamp(0, _found.isEmpty ? 0 : _found.length - 1));
      case LogicalKeyboardKey.pageUp:
        _select((_at - 8).clamp(0, _found.isEmpty ? 0 : _found.length - 1));
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (e is KeyDownEvent) _go(_at, shift);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final muted = heavy(12, color: Swatch.muted, weight: FontWeight.w700);
    // Up near the top, so it doesn't jump about as the list narrows.
    return SizedBox.expand(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: screen.height * 0.12 - 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: (screen.height * 0.88 - 32).clamp(200, 560)),
            child: ModalWindow(
              modal: widget.modal,
              width: 640,
              closable: false,
              scrollBody: false,
              bodyPadding: EdgeInsets.zero,
              title: const Text('🔎 Find anything'),
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: Focus(
                      onKeyEvent: _onKey,
                      skipTraversal: true,
                      child: Semantics(
                        label: 'Find anything in the office',
                        textField: true,
                        child: TextField(
                          key: const ValueKey('palette-input'),
                          controller: _query,
                          focusNode: paletteFocus,
                          autofocus: true,
                          autocorrect: false,
                          onChanged: (_) => _render(),
                          style: heavy(16, weight: FontWeight.w700),
                          decoration: const InputDecoration(
                            hintText: 'Find a worker, issue, PR, board, teammate or action…',
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_found.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                      child: Text('Nothing here matches that.', style: heavy(13, color: Swatch.muted)),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        itemCount: _found.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, i) => _row(i, muted),
                      ),
                    ),
                ],
              ),
              footer: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (k, what) in const [
                    ('↵', 'open'),
                    ('⇧↵', 'walk there first'),
                    ('↑↓', 'choose'),
                    ('Esc', 'close'),
                  ])
                    Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(child: _Key(k)),
                          TextSpan(text: ' $what  '),
                        ],
                      ),
                      style: muted,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(int i, TextStyle muted) {
    final m = _found[i];
    final e = m.item;
    final on = i == _at;
    return Tooltip(
      message: e.walk != null ? 'Enter opens it · Shift+Enter walks you there first' : 'Enter opens it',
      waitDuration: const Duration(milliseconds: 800),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (_) {
          if (!on) setState(() => _at = i);
        },
        child: GestureDetector(
          key: ValueKey('palette-row-$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _go(i, HardwareKeyboard.instance.isShiftPressed),
          child: Container(
            height: _rowH,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: on ? Colors.white : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: on ? Swatch.accent : Colors.transparent, width: 2),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(e.icon, textAlign: TextAlign.center, style: heavy(18)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: marked(e.title, m.field == PaletteField.title ? m.hits : const [])),
                        style: heavy(14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (e.detail != null && e.detail!.isNotEmpty)
                        Text.rich(
                          TextSpan(children: marked(e.detail!, m.field == PaletteField.detail ? m.hits : const [])),
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(e.kind.toUpperCase(), style: heavy(11, color: Swatch.muted).copyWith(letterSpacing: 0.4)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [text] with the characters at [hits] marked.
List<InlineSpan> marked(String text, List<int> hits) {
  if (hits.isEmpty) return [TextSpan(text: text)];
  final on = hits.toSet();
  final out = <InlineSpan>[];
  final run = StringBuffer();
  var inHit = false;
  void flush() {
    if (run.isEmpty) return;
    out.add(
      TextSpan(
        text: run.toString(),
        style: inHit ? const TextStyle(backgroundColor: Swatch.warn, color: Swatch.ink) : null,
      ),
    );
    run.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final hit = on.contains(i);
    if (hit != inHit) {
      flush();
      inHit = hit;
    }
    run.write(text[i]);
  }
  flush();
  return out;
}

class _Key extends StatelessWidget {
  const _Key(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: Swatch.ink, width: 1.5),
    ),
    child: Text(label, style: heavy(11)),
  );
}
