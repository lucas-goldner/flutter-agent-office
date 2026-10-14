// The tab bar over a worker's terminal (ui/termtabs.ts): 💻 Terminal, any web pages pinned beside it, and
// "+ Web page" to pin another. The terminal keeps running while a page shows.

import 'package:flutter/material.dart';

import '../interop/browser.dart' show serverOrigin;
import '../interop/open_link.dart';
import 'modal.dart' show clip, toast, ToastKind;
import 'term_tabs_logic.dart';
import 'theme.dart';
import 'web_page.dart' as page;
import 'window_parts.dart' show BoxInput;

/// Stands in for the page view in tests, where there's no web view.
@visibleForTesting
Widget Function(WebTab tab)? debugWebPage;

class TermTabs extends StatefulWidget {
  const TermTabs({super.key, required this.workerId, required this.terminal, required this.focusTerm});
  final String workerId;
  final Widget terminal;

  /// Back on the terminal's tab.
  final VoidCallback focusTerm;

  @override
  State<TermTabs> createState() => _TermTabsState();
}

class _TermTabsState extends State<TermTabs> {
  late final List<WebTab> _tabs = tabsByWorker.putIfAbsent(widget.workerId, () => []);
  String _active = 'main';
  bool _adding = false;
  final _name = TextEditingController();
  final _url = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _show(String id) {
    setState(() => _active = id);
    if (id == 'main') widget.focusTerm();
  }

  void _close(WebTab t) {
    setState(() {
      _tabs.remove(t);
      if (_active == t.id) _active = 'main';
    });
    if (_active == 'main') widget.focusTerm();
  }

  void _closeForm() => setState(() {
    _adding = false;
    _name.clear();
    _url.clear();
  });

  void _add() {
    final r = newWebTab(_name.text, _url.text, officeOrigin: serverOrigin);
    if (r.tab == null) return toast(r.problem!, ToastKind.warn);
    _tabs.add(r.tab!);
    _closeForm();
    _show(r.tab!.id);
  }

  Widget _tab(String id, String label, {String? tooltip, VoidCallback? onClose, String? closeLabel}) {
    final on = _active == id;
    Widget b = InkWell(
      key: ValueKey('term-tab-$id'),
      borderRadius: BorderRadius.circular(9),
      onTap: () => _show(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(label, style: heavy(13, color: on ? Swatch.ink : Colors.white70)),
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip, child: b);
    return Semantics(
      selected: on,
      child: Container(
        decoration: BoxDecoration(
          color: on ? Swatch.paper : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? Swatch.ink : Colors.white24, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            b,
            if (onClose != null)
              Semantics(
                label: closeLabel,
                button: true,
                child: InkWell(
                  key: ValueKey('term-tab-close-$id'),
                  onTap: onClose,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('×', style: heavy(15, color: on ? Swatch.ink : Colors.white70)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bar() {
    final shown = _tabs.where((t) => t.id == _active).firstOrNull;
    final dim = heavy(13, color: Colors.white70);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, right: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _tab('main', '💻 Terminal'),
          for (final t in _tabs)
            _tab(
              t.id,
              '🌐 ${clip(t.title, 18)}',
              tooltip: t.url,
              onClose: () => _close(t),
              closeLabel: 'Close ${t.title} tab',
            ),
          // Plenty of sites won't show inside another page (chatgpt.com doesn't): this opens the one
          // showing in a tab of its own.
          if (shown != null)
            Tooltip(
              message: "Open this page in a browser tab of its own (for a site that won't show here)",
              child: InkWell(
                key: const ValueKey('term-tab-out'),
                onTap: () => openInNewTab(shown.url),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text('↗ New tab', style: dim),
                ),
              ),
            ),
          if (!_adding)
            Tooltip(
              message: 'Pin a web page open beside this terminal (a linked chat, docs, anything with an address)',
              child: InkWell(
                key: const ValueKey('term-tab-add'),
                onTap: () => setState(() => _adding = true),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text('+ Web page', style: dim),
                ),
              ),
            )
          else ...[
            SizedBox(
              width: 180,
              child: Semantics(
                label: 'Tab name',
                textField: true,
                child: BoxInput(
                  key: const ValueKey('term-tab-name'),
                  controller: _name,
                  hint: 'Tab name (e.g. ChatGPT)',
                  autofocus: true,
                  onSubmitted: (_) => _add(),
                ),
              ),
            ),
            SizedBox(
              width: 260,
              child: Semantics(
                label: 'Web page address',
                textField: true,
                child: BoxInput(
                  key: const ValueKey('term-tab-url'),
                  controller: _url,
                  hint: 'https://…',
                  onSubmitted: (_) => _add(),
                ),
              ),
            ),
            OfficeButton(label: 'Add', kind: BtnKind.primary, dense: true, onPressed: _add),
            OfficeButton(label: 'Cancel', dense: true, onPressed: _closeForm),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final at = _active == 'main' ? 0 : 1 + _tabs.indexWhere((t) => t.id == _active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bar(),
        Expanded(
          // Every page stays loaded while another shows, and the terminal keeps running.
          child: IndexedStack(
            index: at,
            sizing: StackFit.expand,
            children: [
              widget.terminal,
              for (final t in _tabs)
                KeyedSubtree(key: ValueKey(t.id), child: debugWebPage?.call(t) ?? page.webPageView(t.url, t.title)),
            ],
          ),
        ),
      ],
    );
  }
}
