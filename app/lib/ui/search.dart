// The 🔎 window: words in the office chat and in every worker's terminal, including what was said
// and shown before the office last restarted. A terminal line opens that terminal right at it.
// A port of ui/search.ts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/api.dart';
import '../office_scope.dart';
import '../shared/protocol.dart';
import '../shared/search.dart';
import '../world/laptop_screen.dart' show kTermFont, kTermFontFallback, TermTheme;
import 'modal.dart';
import 'search_logic.dart';
import 'theme.dart';
import 'worker_text.dart';

/// What was searched last, so the window opens where you left it.
String _lastQuery = '';

/// Stands in for GET /api/search (previews and tests).
Future<SearchResults> Function(String q)? searchOverride;

Future<SearchResults> _search(OfficeScope scope, String q) async {
  final o = searchOverride;
  if (o != null) return o(q);
  // Terminals are the workers on your floor; the chat is the whole building's.
  final floor = scope.store.floor;
  final r = await Api.getJson('/api/search?${Uri(queryParameters: {'q': q, 'floor': ?floor}).query}');
  if (!r.ok) throw Exception(r.error('HTTP ${r.status}'));
  return SearchResults.fromJson(r.body);
}

/// Opens the 🔎 window on the last search, or on [query] when given.
ModalHandle openSearch(OfficeScope scope, {String? query}) {
  if (query != null) _lastQuery = query;
  return ModalStack.instance.show((m) => _SearchWindow(modal: m, scope: scope));
}

class _SearchWindow extends StatefulWidget {
  const _SearchWindow({required this.modal, required this.scope});

  final ModalHandle modal;
  final OfficeScope scope;

  @override
  State<_SearchWindow> createState() => _SearchWindowState();
}

class _SearchWindowState extends State<_SearchWindow> {
  late final _input = TextEditingController(text: _lastQuery);
  final _inputFocus = FocusNode();
  SearchResults? _found;
  String _error = '';
  bool _searching = false;
  int _seq = 0;
  Timer? _timer;
  final List<FocusNode> _hitFocus = [];

  @override
  void initState() {
    super.initState();
    // Right away, so the first keys typed after / land in the box.
    _input.selection = TextSelection(baseOffset: 0, extentOffset: _input.text.length);
    _run();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    for (final f in _hitFocus) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _run() async {
    _timer?.cancel();
    final q = _input.text;
    _lastQuery = q;
    final mine = ++_seq;
    if (searchKey(q).length < searchMin) {
      setState(() {
        _found = null;
        _error = '';
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final r = await _search(widget.scope, q);
      if (mine != _seq || !mounted) return;
      setState(() {
        _found = r;
        _error = '';
        _searching = false;
      });
    } catch (e) {
      if (mine != _seq || !mounted) return;
      setState(() {
        _error = '$e'.replaceFirst('Exception: ', '');
        _searching = false;
      });
    }
  }

  void _jump(TerminalHit hit, String needle) {
    widget.modal.close();
    widget.scope.actions.openWorkerTerminal(hit.workerId, find: (row: hit.rows - hit.row, needle: needle));
  }

  FocusNode _hitNode(int i) {
    while (_hitFocus.length <= i) {
      _hitFocus.add(FocusNode());
    }
    return _hitFocus[i];
  }

  KeyEventResult _inputKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter) {
      _run();
      return KeyEventResult.handled;
    }
    // Down from the box steps into the terminal lines, which Enter opens.
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && _hitFocus.isNotEmpty) {
      _hitFocus.first.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return ModalWindow(
      modal: widget.modal,
      width: 820,
      height: (screen.height - 32).clamp(0, 720),
      scrollBody: false,
      title: const Text('🔎 Search'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _inputKey,
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              autofocus: true,
              maxLength: searchMax,
              autocorrect: false,
              enableSuggestions: false,
              style: heavy(15, weight: FontWeight.w600),
              decoration: InputDecoration(
                counterText: '',
                hintText: 'Search the chat and every terminal…',
                hintStyle: heavy(15, color: Swatch.muted, weight: FontWeight.w600),
              ),
              onChanged: (_) {
                _timer?.cancel();
                _timer = Timer(const Duration(milliseconds: 200), _run);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              _statusText(),
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
            ),
          ),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  String _statusText() {
    if (_searching) return 'Searching…';
    if (_error.isNotEmpty) return "Couldn't search: $_error";
    final f = _found;
    if (f == null) return kSearchIntro;
    final byWorker = hitsByWorker(f, (id) => widget.scope.store.workers.containsKey(id));
    return searchStatus(f, f.chat.length + byWorker.values.fold(0, (n, l) => n + l.length));
  }

  Widget _results() {
    final f = _found;
    if (f == null || _error.isNotEmpty) return const SizedBox.shrink();
    final needle = searchKey(f.q);
    final store = widget.scope.store;
    // Workers sent home since the search ran have nothing left to open.
    final byWorker = hitsByWorker(f, (id) => store.workers.containsKey(id));
    var n = 0;
    final groups = <Widget>[
      if (f.chat.isNotEmpty)
        _Group(
          head: Text('💬 Chat', style: heavy(13, weight: FontWeight.w900)),
          rows: [for (final c in f.chat) _ChatHit(c, needle)],
        ),
      for (final MapEntry(key: id, value: hits) in byWorker.entries)
        _Group(
          head: Row(
            spacing: 6,
            children: [
              Dot(hexColor(store.workers[id]!.color)),
              Flexible(
                child: Text(
                  [store.workers[id]!.name, if (store.workers[id]!.worktree != null) '🌿 ${store.workers[id]!.worktree!.branch}'].join(' · '),
                  style: heavy(13, weight: FontWeight.w900),
                ),
              ),
            ],
          ),
          rows: [
            for (final hit in hits)
              _TermHit(
                hit,
                needle,
                focusNode: _hitNode(n++),
                onOpen: () => _jump(hit, needle),
                onArrow: (down) {
                  final i = _hitFocus.indexWhere((f) => f.hasFocus);
                  final next = i + (down ? 1 : -1);
                  if (next < 0) {
                    _inputFocus.requestFocus();
                  } else if (next < n) {
                    _hitFocus[next].requestFocus();
                  }
                },
              ),
          ],
        ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
      children: [for (final g in groups) Padding(padding: const EdgeInsets.only(bottom: 14), child: g)],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.head, required this.rows});

  final Widget head;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: head),
      for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 4), child: r),
    ],
  );
}

/// The text with its matches marked (yellow, rounded), as spans.
List<InlineSpan> _marks(String text, String needle, {Color markText = Swatch.ink}) => [
  for (final p in highlight(text, needle))
    p.mark
        ? WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(color: Swatch.warn, borderRadius: BorderRadius.circular(3)),
              child: Text(p.text, style: TextStyle(color: markText)),
            ),
          )
        : TextSpan(text: p.text),
];

class _ChatHit extends StatelessWidget {
  const _ChatHit(this.c, this.needle);

  final ChatLine c;
  final String needle;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0x262B2D42), width: 2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              c.name,
              style: heavy(12, color: hexColor(c.color), weight: FontWeight.w900),
            ),
            Text(
              timeAgo(c.at),
              style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
            ),
          ],
        ),
        Text.rich(
          TextSpan(children: _marks(c.text, needle)),
          style: heavy(14, weight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _TermHit extends StatefulWidget {
  const _TermHit(this.hit, this.needle, {required this.focusNode, required this.onOpen, required this.onArrow});

  final TerminalHit hit;
  final String needle;
  final FocusNode focusNode;
  final VoidCallback onOpen;
  final void Function(bool down) onArrow;

  @override
  State<_TermHit> createState() => _TermHitState();
}

class _TermHitState extends State<_TermHit> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Open the terminal at this line',
    waitDuration: const Duration(milliseconds: 600),
    child: FocusableActionDetector(
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onFocusChange: (v) => setState(() => _focused = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowIntent(true),
        SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowIntent(false),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onOpen()),
        _ArrowIntent: CallbackAction<_ArrowIntent>(onInvoke: (i) => widget.onArrow(i.down)),
      },
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: TermTheme.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _hover || _focused ? Swatch.accent : TermTheme.background, width: _hover || _focused ? 3 : 2),
          ),
          child: Text.rich(
            TextSpan(children: _marks(widget.hit.text, widget.needle)),
            style: const TextStyle(fontFamily: kTermFont, fontFamilyFallback: kTermFontFallback, fontSize: 12.5, color: TermTheme.foreground),
          ),
        ),
      ),
    ),
  );
}

class _ArrowIntent extends Intent {
  const _ArrowIntent(this.down);
  final bool down;
}
