// Windows over the office, and the little helpers every window uses: a port of ui/dom.ts.
//
// Modals are a stack in an overlay: Esc closes the top one (unless it says not to), a click on
// the backdrop closes it, and [ModalStack.changes] tells the game when any are open so it lets go
// of the keyboard and the mouse.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class ModalHandle {
  ModalHandle._(this._stack, this._entry, this.onClose);

  final ModalStack _stack;
  final OverlayEntry _entry;
  final VoidCallback? onClose;
  bool _closed = false;

  bool get closed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _entry.remove();
    _stack._stack.remove(this);
    onClose?.call();
    _stack.changes.value = _stack._stack.isNotEmpty;
  }
}

class ModalStack {
  ModalStack._();

  static final ModalStack instance = ModalStack._();

  final List<ModalHandle> _stack = [];
  OverlayState? _overlay;

  /// True while any window is open.
  final ValueNotifier<bool> changes = ValueNotifier(false);

  bool get open => _stack.isNotEmpty;

  /// Where windows go: the office page's overlay. Set once by the page.
  void attach(OverlayState overlay) => _overlay = overlay;

  /// Opens [child] (usually a [ModalWindow]) over everything.
  ModalHandle show(
    Widget Function(ModalHandle modal) builder, {
    bool escCloses = true,
    bool backdropCloses = true,
    VoidCallback? onClose,
    bool clear = false,
  }) {
    late ModalHandle handle;
    final entry = OverlayEntry(
      builder: (context) => _Backdrop(
        onTapOutside: backdropCloses ? () => handle.close() : null,
        onEsc: escCloses ? () => handle.close() : null,
        isTop: () => _stack.isNotEmpty && identical(_stack.last, handle),
        clear: clear,
        child: builder(handle),
      ),
    );
    handle = ModalHandle._(this, entry, onClose);
    _stack.add(handle);
    _overlay!.insert(entry);
    changes.value = true;
    return handle;
  }

  void closeAll() {
    while (_stack.isNotEmpty) {
      _stack.last.close();
    }
  }
}

/// The dimmed backdrop, centring its window, with Esc and click-outside.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.child, this.onTapOutside, this.onEsc, required this.isTop, this.clear = false});

  final Widget child;

  /// Not dimmed, and the window gets the whole page to lay itself out in (DEADFALL over the monitor).
  final bool clear;
  final VoidCallback? onTapOutside;
  final VoidCallback? onEsc;
  final bool Function() isTop;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (isTop()) onEsc?.call();
      },
    },
    child: FocusScope(
      autofocus: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTapOutside == null ? null : (_) => onTapOutside!(),
        child: clear
            ? child
            : ColoredBox(
          color: Swatch.backdrop,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                // Taps inside the window stay inside it.
                child: GestureDetector(onTapDown: (_) {}, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The .modal: a paper window with a header (title and ✕), a body and an optional footer.
class ModalWindow extends StatelessWidget {
  const ModalWindow({
    super.key,
    required this.modal,
    required this.title,
    required this.body,
    this.footer,
    this.headerExtras = const [],
    this.width = 560,
    this.height,
    this.bodyPadding = const EdgeInsets.all(16),
    this.background = Swatch.paper,
    this.scrollBody = true,
    this.closable = true,
  });

  final ModalHandle modal;
  final Widget title;
  final Widget body;
  final Widget? footer;
  final List<Widget> headerExtras;
  final double width;

  /// Fixed height for big windows (a terminal, a board); null sizes to the content.
  final double? height;
  final EdgeInsetsGeometry bodyPadding;
  final Color background;
  final bool scrollBody;

  /// Shows the ✕ in the header. Off for windows that must be answered (a confirm, the restart).
  final bool closable;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final maxH = screen.height - 32;
    Widget content = Padding(padding: bodyPadding, child: body);
    if (scrollBody) content = SingleChildScrollView(child: content);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width, maxHeight: maxH),
      child: SizedBox(
        width: width,
        height: height?.clamp(0, maxH),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Swatch.ink, width: kBorder),
            boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 6))],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: height == null ? MainAxisSize.min : MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    color: Swatch.paper2,
                    border: Border(bottom: BorderSide(color: Swatch.ink, width: kBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle(
                          style: heavy(18, weight: FontWeight.w900),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: title,
                        ),
                      ),
                      ...headerExtras.map((w) => Padding(padding: const EdgeInsets.only(left: 8), child: w)),
                      if (closable) ...[
                        const SizedBox(width: 8),
                        OfficeButton(label: '✕', onPressed: modal.close, tooltip: 'Close', dense: true),
                      ],
                    ],
                  ),
                ),
                if (height == null) Flexible(child: content) else Expanded(child: content),
                if (footer != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      color: Swatch.paper2,
                      border: Border(top: BorderSide(color: Swatch.ink, width: kBorder)),
                    ),
                    child: footer,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Toasts -----------------------------------------------------------------------------------

enum ToastKind { info, warn, error }

class ToastItem {
  ToastItem(this.text, this.kind);
  final String text;
  final ToastKind kind;
  final int id = _nextId++;
  static int _nextId = 0;
}

/// Short messages that pop up under the top bar for 3.5 seconds.
class Toasts {
  Toasts._();
  static final Toasts instance = Toasts._();

  final ValueNotifier<List<ToastItem>> items = ValueNotifier(const []);

  void show(String text, [ToastKind kind = ToastKind.info]) {
    final t = ToastItem(text, kind);
    items.value = [...items.value, t];
    Future.delayed(const Duration(milliseconds: 3800), () {
      items.value = items.value.where((x) => x.id != t.id).toList();
    });
  }
}

/// toast() from the old dom.ts.
void toast(String text, [ToastKind kind = ToastKind.info]) => Toasts.instance.show(text, kind);

class ToastLayer extends StatelessWidget {
  const ToastLayer({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder(
      valueListenable: Toasts.instance.items,
      builder: (context, items, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in items)
            Padding(
              key: ValueKey(t.id),
              padding: const EdgeInsets.only(bottom: 8),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 250),
                builder: (context, v, child) => Opacity(
                  opacity: v,
                  child: Transform.translate(offset: Offset(0, (1 - v) * -10), child: child),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: switch (t.kind) {
                      ToastKind.warn => const Color(0xFFFFF3C4),
                      ToastKind.error => const Color(0xFFFFD6E0),
                      ToastKind.info => Swatch.paper,
                    },
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Swatch.ink, width: kBorder),
                    boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
                  ),
                  child: Text(t.text, style: heavy(14)),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

// ---- Little helpers ----------------------------------------------------------------------------

String timeAgo(Object isoOrMs) {
  final t = isoOrMs is num ? isoOrMs.toInt() : DateTime.tryParse('$isoOrMs')?.millisecondsSinceEpoch ?? 0;
  final s = ((DateTime.now().millisecondsSinceEpoch - t) / 1000).clamp(0, double.infinity);
  if (s < 60) return 'just now';
  if (s < 3600) return '${(s / 60).floor()}m ago';
  if (s < 86400) return '${(s / 3600).floor()}h ago';
  return '${(s / 86400).floor()}d ago';
}

/// [text] cut to at most [max] characters, with an ellipsis when it was longer.
String clip(String text, int max) => text.length > max ? '${text.substring(0, max - 1)}…' : text;
