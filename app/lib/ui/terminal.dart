// A worker's live terminal in a window: a port of ui/terminal.ts, on the pure-Dart xterm package.
//
// The PTY's raw bytes come in as term.data (and a term.snapshot replay on attach); keys and pastes
// go out as term.input. The PTY is shared by everyone watching, so its size follows the latest
// typist (see TermSizePolicy).

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as x;

import '../interop/portable.dart';
import '../office_scope.dart';
import '../shared/protocol.dart';
import '../shared/search.dart';
import '../shared/status.dart';
import '../state/store.dart';
import '../world/laptop_screen.dart';
import 'modal.dart';
import 'provider.dart';
import 'terminal_logic.dart';
import 'theme.dart';
import 'worker_text.dart';

export 'terminal_logic.dart' show TerminalFind;

/// The laptop palette as an xterm theme.
const kTermTheme = x.TerminalTheme(
  cursor: Color(0xB3FFD166), // the theme cursor, see-through so the glyph under it shows
  selection: Color(0x9944475A),
  foreground: TermTheme.foreground,
  background: TermTheme.background,
  black: TermTheme.black,
  red: TermTheme.red,
  green: TermTheme.green,
  yellow: TermTheme.yellow,
  blue: TermTheme.blue,
  magenta: TermTheme.magenta,
  cyan: TermTheme.cyan,
  white: TermTheme.white,
  brightBlack: TermTheme.brightBlack,
  brightRed: TermTheme.brightRed,
  brightGreen: TermTheme.brightGreen,
  brightYellow: TermTheme.brightYellow,
  brightBlue: TermTheme.brightBlue,
  brightMagenta: TermTheme.brightMagenta,
  brightCyan: TermTheme.brightCyan,
  brightWhite: TermTheme.brightWhite,
  searchHitBackground: TermTheme.yellow,
  searchHitBackgroundCurrent: TermTheme.yellow,
  searchHitForeground: TermTheme.background,
);

/// ui-monospace 14px at a 1.1 line height, in the bundled face.
const kTermStyle = x.TerminalStyle(fontSize: 14, height: 1.1, fontFamily: kTermFont, fontFamilyFallback: kTermFontFallback);

/// Copy with Ctrl+Shift+C (Cmd+C on a Mac). Paste is the browser's own (see interceptPaste), and
/// Ctrl+A goes to the program (readline's start of line), not select-all.
final _termShortcuts = <ShortcutActivator, Intent>{
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyC, meta: true): CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyA, meta: true): const SelectAllTextIntent(SelectionChangedCause.keyboard),
};

({String workerId, ModalHandle modal, void Function(TerminalFind f) find})? _current;

/// Whose terminal is open, so a reconnect can attach to it again.
String? openTerminalFor() => _current?.workerId;

/// Opens [workerId]'s terminal, or scrolls the open one to [find]. [onChanges] adds the 🌿 Changes button.
void openTerminal(OfficeScope scope, String workerId, {VoidCallback? onChanges, TerminalFind? find}) {
  final cur = _current;
  if (cur != null && cur.workerId == workerId) {
    if (find != null) cur.find(find);
    return;
  }
  cur?.modal.close();
  if (scope.store.workers[workerId] == null) return;
  final key = GlobalKey<_TerminalWindowState>();
  late final ModalHandle modal;
  modal = ModalStack.instance.show(
    (m) => _TerminalWindow(key: key, scope: scope, workerId: workerId, modal: m, onChanges: onChanges, find: find),
    // Esc belongs to the program in the terminal; Ctrl+] or ✕ leaves.
    escCloses: false,
    onClose: () {
      if (identical(_current?.modal, modal)) _current = null;
    },
  );
  _current = (workerId: workerId, modal: modal, find: (f) => key.currentState?.find(f));
}

class _TerminalWindow extends StatefulWidget {
  const _TerminalWindow({super.key, required this.scope, required this.workerId, required this.modal, this.onChanges, this.find});

  final OfficeScope scope;
  final String workerId;
  final ModalHandle modal;
  final VoidCallback? onChanges;
  final TerminalFind? find;

  @override
  State<_TerminalWindow> createState() => _TerminalWindowState();
}

class _TerminalWindowState extends State<_TerminalWindow> {
  late x.Terminal _term = _makeTerminal();
  x.TerminalController _ctl = x.TerminalController();
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'terminal');
  final _policy = TermSizePolicy();
  final _subs = <StreamSubscription<Object?>>[];
  late final void Function() _stopPaste;
  bool _ready = false;
  TerminalFind? _pendingFind;
  Size? _host;
  Timer? _resizeDebounce;
  Size? _cell;

  /// A search hit being kept in view while the window settles (see [find]).
  x.CellAnchor? _findAnchor;
  int _followUntil = 0;
  final _viewKey = GlobalKey<x.TerminalViewState>();
  Offset? _downAt;
  bool _overLink = false;

  Store get store => widget.scope.store;
  WorkerInfo? get worker => store.workers[widget.workerId];

  @override
  void initState() {
    super.initState();
    _pendingFind = widget.find;
    final net = widget.scope.net;
    _subs.add(net.messages.listen(_onMsg));
    // Back after a reconnect: attach again for a fresh snapshot.
    _subs.add(
      net.status.listen((up) {
        if (up) net.send(WorkerAttachCmd(widget.workerId));
      }),
    );
    store.topic(Topic.workers).addListener(_refresh);
    _stopPaste = interceptPaste(() => _focus.hasFocus, (text) {
      _sendSize(typing: true);
      _term.paste(text);
    });
    net.send(WorkerAttachCmd(widget.workerId));
    Timer(const Duration(milliseconds: 50), () {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    store.topic(Topic.workers).removeListener(_refresh);
    _stopPaste();
    _resizeDebounce?.cancel();
    widget.scope.net.send(WorkerDetachCmd(widget.workerId));
    _ctl.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  x.Terminal _makeTerminal() => x.Terminal(maxLines: 5000, onOutput: _onData);

  void _onData(String data) {
    _sendSize(typing: true);
    widget.scope.net.send(TermInputCmd(widget.workerId, data));
  }

  void _onMsg(ServerMsg msg) {
    switch (msg) {
      case TermDataMsg(:final workerId, :final data) when workerId == widget.workerId:
        _term.write(data);
      case TermSnapshotMsg m when m.workerId == widget.workerId:
        // A fresh terminal is xterm.js's reset(): new buffers, modes and scrollback.
        setState(() {
          _ctl.dispose();
          _ctl = x.TerminalController();
          _term = _makeTerminal()..resize(m.cols, m.rows);
          _term.write(m.data);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _ready = true;
          _sendSize();
          _scrollToBottom();
          _refresh();
          final f = _pendingFind;
          _pendingFind = null;
          if (f != null) find(f);
        });
      default:
        break;
    }
  }

  TermSize get _size => (cols: _term.viewWidth, rows: _term.viewHeight);

  /// How many cells fit the window, like xterm.js's fit addon.
  TermSize? _fit() {
    final host = _host;
    final cell = _cell;
    if (host == null || cell == null || cell.isEmpty) return null;
    return (cols: (host.width / cell.width).floor().clamp(2, 1000), rows: (host.height / cell.height).floor().clamp(1, 1000));
  }

  void _sendSize({bool typing = false}) {
    if (!_ready) return;
    final fit = _fit();
    if (fit == null) return;
    final d = _policy.decide(typing: typing, w: worker, fit: fit, current: _size);
    if (d.resizeTo case final to?) _resizeTo(to);
    if (d.send case final s?) widget.scope.net.send(TermResizeCmd(widget.workerId, cols: s.cols, rows: s.rows));
  }

  void _resizeTo(TermSize to) {
    _term.resize(to.cols, to.rows);
    // Stay on a search hit through the resizes just after the window opens.
    if (DateTime.now().millisecondsSinceEpoch < _followUntil) {
      Timer(const Duration(milliseconds: 50), _scrollToFind);
    }
    setState(() {});
  }

  void _refresh() {
    final w = worker;
    if (w == null) {
      widget.modal.close();
      return;
    }
    if (_ready) {
      final to = _policy.follow(w, _size);
      if (to != null) _term.resize(to.cols, to.rows);
    }
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  /// Scrolls a search hit into view and lights it up for a few seconds.
  void find(TerminalFind f) {
    if (!_ready) {
      _pendingFind = f;
      return;
    }
    final buf = XtermBuffer(_term.buffer);
    final row = findLine(buf, f.needle, f.row);
    if (row == null) {
      toast('That line has scrolled out of the terminal since', ToastKind.warn);
      return;
    }
    var end = row;
    while (buf.getLine(end + 1)?.isWrapped == true) {
      end++;
    }
    final lines = _term.buffer.lines;
    // Anchors follow the line when the terminal reflows, which it does as the window settles.
    final mark = _ctl.highlight(
      p1: _term.buffer.createAnchor(0, row),
      p2: _term.buffer.createAnchor(lines[end].length, end),
      color: TermTheme.yellow.withValues(alpha: 0.45),
    );
    _findAnchor?.dispose();
    final anchor = _findAnchor = _term.buffer.createAnchor(0, row);
    _followUntil = DateTime.now().millisecondsSinceEpoch + 1500;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFind());
    Timer(const Duration(seconds: 8), () {
      mark.dispose();
      anchor.dispose();
      if (identical(_findAnchor, anchor)) _findAnchor = null;
    });
  }

  void _scrollToFind() {
    final a = _findAnchor;
    final cell = _cell;
    if (a == null || !a.attached || cell == null || !_scroll.hasClients || !mounted) return;
    final p = _scroll.position;
    final target = ((a.y - _term.viewHeight ~/ 3) * cell.height).clamp(0.0, p.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && (e.logicalKey == LogicalKeyboardKey.bracketRight || e.character == ']')) {
      widget.modal.close();
      return KeyEventResult.handled;
    }
    if (ctrl && (e.logicalKey == LogicalKeyboardKey.bracketLeft || e.character == '[')) {
      _onData('\x1b');
      return KeyEventResult.handled;
    }
    // Leave Ctrl+V / Cmd+V to the browser, whose paste event interceptPaste turns into a (bracketed) paste.
    if ((ctrl || meta) && e.logicalKey == LogicalKeyboardKey.keyV) return KeyEventResult.skipRemainingHandlers;
    return KeyEventResult.ignored;
  }

  /// The link under [local] (a point in the terminal view), if there is one.
  String? _linkAt(Offset local) {
    final view = _viewKey.currentState;
    if (view == null) return null;
    final at = view.renderTerminal.getCellOffset(local);
    return urlAt(XtermBuffer(_term.buffer), at.y, at.x);
  }

  // Links open on a click (web-links). xterm's onTapUp never fires, and window.open needs the
  // browser's own pointerup, so this listens to the raw pointer.
  void _pointerUp(PointerUpEvent e) {
    final down = _downAt;
    _downAt = null;
    if (down == null || (e.localPosition - down).distance > 4 || _ctl.selection != null) return;
    final url = _linkAt(e.localPosition);
    if (url != null) openInNewTab(url);
  }

  void _hover(PointerHoverEvent e) {
    final over = _linkAt(e.localPosition) != null;
    if (over != _overLink) setState(() => _overLink = over);
  }

  void _openModels() {
    _sendSize(typing: true);
    // OpenCode's native model picker is Ctrl+X, then M. Injecting the
    // control sequence preserves any draft already in the TUI input box.
    _term.textInput('\x18m');
    _focus.requestFocus();
  }

  Size _measureCell(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final style = kTermStyle.toTextStyle();
    const probe = 'mmmmmmmmmm';
    final b = ui.ParagraphBuilder(style.getParagraphStyle())
      ..pushStyle(style.getTextStyle(textScaler: scaler))
      ..addText(probe);
    final p = b.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
    return Size(p.maxIntrinsicWidth / probe.length, p.height);
  }

  void _hostChanged(Size size) {
    if (size == _host) return;
    _host = size;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 80), () {
      if (mounted) _sendSize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = worker;
    _cell ??= _measureCell(context);
    return ModalWindow(
      modal: widget.modal,
      width: 1200,
      height: 820,
      background: Swatch.termBg,
      scrollBody: false,
      bodyPadding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
      title: _Title(w: w, project: store.project),
      headerExtras: w == null ? const [] : _headerExtras(w),
      body: LayoutBuilder(
        builder: (context, box) {
          _hostChanged(box.biggest);
          return Semantics(
            label: '${w?.name ?? ''} terminal',
            child: Listener(
              onPointerDown: (e) => _downAt = e.buttons == kPrimaryButton ? e.localPosition : null,
              onPointerUp: _pointerUp,
              onPointerHover: _hover,
              child: x.TerminalView(
                _term,
                key: _viewKey,
                mouseCursor: _overLink ? SystemMouseCursors.click : SystemMouseCursors.text,
                controller: _ctl,
                scrollController: _scroll,
                focusNode: _focus,
                autofocus: true,
                autoResize: false,
                theme: kTermTheme,
                textStyle: kTermStyle,
                cursorType: x.TerminalCursorType.block,
                shortcuts: _termShortcuts,
                onKeyEvent: _onKey,
                hardwareKeyboardOnly: false,
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _headerExtras(WorkerInfo w) {
    final project = store.project;
    final openCode = w.kind == WorkerKind.agent && resolvedProvider(w.provider, project) == AgentProvider.opencode;
    final cost = workerCostText(w, project);
    final muted = heavy(12, color: Swatch.muted);
    return [
      StatusPill(w.status),
      if (cost.isNotEmpty)
        Tooltip(
          message: workerCostTitle(w, project),
          child: Text(cost, style: muted),
        ),
      if (w.viewers.isNotEmpty) Text('👀 ${w.viewers.join(', ')}', style: muted),
      if (w.lastInput != null)
        Tooltip(
          message: '${w.lastInput!.by} typed here last, ${timeAgo(w.lastInput!.at)}',
          child: Text('⌨️ ${w.lastInput!.by}', style: muted),
        ),
      if (openCode)
        OfficeButton(
          label: '🧠 Models',
          tooltip: 'OpenCode models: Ctrl+X then M (use /models if custom bindings override it)',
          onPressed: _ready && !isAsleep(w.status) ? _openModels : null,
        ),
      if (widget.onChanges != null)
        OfficeButton(
          label: '🌿 Changes',
          tooltip: 'What this worker changed: files, diff, commit, open a PR (C at the desk)',
          onPressed: () {
            widget.onChanges!();
            widget.modal.close();
          },
        ),
    ];
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.w, required this.project});

  final WorkerInfo? w;
  final ProjectInfo? project;

  @override
  Widget build(BuildContext context) {
    final w = this.w;
    if (w == null) return const SizedBox.shrink();
    return Row(
      children: [
        Dot(hexColor(w.color)),
        const SizedBox(width: 10),
        Flexible(child: Text(terminalTitle(w, project), maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
