// The Changes window at a desk: the files a worker changed and their diff against the branch the
// office was opened on, refreshed while the worker works, with commit / discard / open-a-PR.
// A port of ui/changes.ts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/portable.dart';
import '../net/server.dart';
import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import '../world/laptop_screen.dart' show kTermFont, kTermFontFallback;
import 'changes_logic.dart';
import 'child_button.dart';
import 'modal.dart';
import 'prompt.dart';
import 'theme.dart';
import 'worker_text.dart';

({String workerId, ModalHandle modal})? _current;

/// Whose changes are on screen, so a reconnect can watch them again.
String? openChangesFor() => _current?.workerId;

/// Opens [workerId]'s Changes window. [onTerminal] adds the ⌨️ Terminal button.
void openChanges(OfficeScope scope, String workerId, {VoidCallback? onTerminal}) {
  if (_current?.workerId == workerId) return;
  if (scope.store.workers[workerId] == null) return;
  final previous = _current;
  late final ModalHandle modal;
  modal = ModalStack.instance.show(
    (m) => _ChangesWindow(scope: scope, workerId: workerId, modal: m, onTerminal: onTerminal),
    onClose: () {
      if (identical(_current?.modal, modal)) _current = null;
    },
  );
  modal.doing = "🌿 looking over ${scope.store.workers[workerId]!.name}'s changes";
  _current = (workerId: workerId, modal: modal);
  previous?.modal.close();
}

const _mono = TextStyle(fontFamily: kTermFont, fontFamilyFallback: kTermFontFallback, color: Swatch.ink);
const _addColor = Color(0xFF2A9D4B);
const _delColor = Color(0xFFC3423F);
const _faint = Color(0x262B2D42); // rgba(43,45,66,.15)

class _ChangesWindow extends StatefulWidget {
  const _ChangesWindow({required this.scope, required this.workerId, required this.modal, this.onTerminal});

  final OfficeScope scope;
  final String workerId;
  final ModalHandle modal;
  final VoidCallback? onTerminal;

  @override
  State<_ChangesWindow> createState() => _ChangesWindowState();
}

class _ChangesWindowState extends State<_ChangesWindow> {
  ChangesState? _state;
  String? _selected;

  /// The signature the shown diff was fetched for; a new one means the file changed underneath.
  String? _shownSig;
  String _requestedSig = '';
  bool _loading = false;

  /// The diff on screen: its rows, or why there are none.
  List<DiffLine>? _diff;
  String? _diffError;
  final _subs = <StreamSubscription<Object?>>[];
  final _focus = FocusNode(debugLabel: 'changes');
  final _listScroll = ScrollController();
  late final String _name = widget.scope.store.workers[widget.workerId]!.name;

  Store get store => widget.scope.store;
  void _send(ClientMsg m) => widget.scope.net.send(m);

  @override
  void initState() {
    super.initState();
    _subs.add(widget.scope.net.messages.listen(_onMsg));
    _subs.add(
      widget.scope.net.status.listen((up) {
        if (up) _send(ChangesWatchCmd(widget.workerId));
      }),
    );
    store.topic(Topic.workers).addListener(_onWorkers);
    _send(ChangesWatchCmd(widget.workerId));
    Timer(const Duration(milliseconds: 30), () {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    store.topic(Topic.workers).removeListener(_onWorkers);
    _send(ChangesUnwatchCmd(widget.workerId));
    _focus.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  void _onWorkers() {
    if (store.workers[widget.workerId] == null) {
      widget.modal.close();
    } else {
      setState(() {});
    }
  }

  ChangedFile? _file(String? path) => _state?.files.where((f) => f.path == path).firstOrNull;

  void _requestDiff() {
    final f = _file(_selected);
    if (_selected == null || f == null) return;
    _loading = true;
    _requestedSig = f.sig;
    _send(ChangesDiffCmd(widget.workerId, _selected!));
  }

  void _select(String? p) {
    if (p == _selected) return;
    setState(() {
      _selected = p;
      _shownSig = null;
      _diff = null;
      _diffError = null;
    });
    if (p != null) _requestDiff();
  }

  void _onState(ChangesState s) {
    setState(() => _state = s);
    final f = _selected != null ? _file(_selected) : null;
    if (f == null) {
      _selected = null;
      _shownSig = null;
      if (s.files.isNotEmpty) _select(s.files.first.path);
      return;
    }
    if (_shownSig != null && _shownSig != f.sig && !_loading) _requestDiff();
  }

  void _onMsg(ServerMsg msg) {
    switch (msg) {
      case ChangesMsg(:final state) when state.workerId == widget.workerId:
        _onState(state);
      case ChangesDiffMsg m when m.workerId == widget.workerId && m.path == _selected:
        _loading = false;
        _shownSig = _requestedSig;
        setState(() {
          _diffError = m.error;
          _diff = m.error != null ? null : parseDiff(m.diff, m.truncated);
        });
        // The file changed again while the diff was on its way: fetch the fresh one.
        final f = _file(_selected);
        if (f != null && f.sig != _shownSig) _requestDiff();
      default:
        break;
    }
  }

  void _move(int delta) {
    final files = _state?.files ?? const <ChangedFile>[];
    if (files.isEmpty) return;
    final i = files.indexWhere((f) => f.path == _selected);
    _select(files[(i + delta).clamp(0, files.length - 1)].path);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyJ) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyK) {
      _move(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _discardAll() {
    final n = uncommittedCount(_state);
    confirmDialog(
      "Discard all uncommitted changes at $_name's desk?",
      'This puts $n file${n == 1 ? '' : 's'} in ${whereText(_state)} back to the last commit and deletes new files. Commits stay.'
          '${_state?.dir.isNotEmpty == true ? '' : " That folder is shared: anyone's uncommitted edits there go too."}',
      'Discard everything',
      () => _send(ChangesDiscardCmd(widget.workerId)),
    );
  }

  void _discardOne(ChangedFile f) => confirmDialog(
    'Discard the changes to ${f.path.split('/').last}?',
    'This puts ${f.path} back to the last commit in ${whereText(_state)}. ${f.status == ChangeStatus.untracked ? 'The file is deleted.' : 'Committed changes stay.'}',
    'Discard',
    () => _send(ChangesDiscardCmd(widget.workerId, path: f.path)),
  );

  void _commit() {
    final n = uncommittedCount(_state);
    final branch = _state?.branch;
    openPrompt(
      PromptOptions(
        title: '✅ Commit $n file${n == 1 ? '' : 's'}',
        subtitle: 'Stages everything in ${whereText(_state)} and commits it${branch != null && branch.isNotEmpty ? ' on $branch' : ''}.',
        placeholder: 'What changed, and why',
        submitLabel: 'Commit',
        onSubmit: (text, _) => _send(ChangesCommitCmd(widget.workerId, text)),
      ),
    );
  }

  void _openPr(ChangesState s) => openPrompt(
    PromptOptions(
      title: '🔀 Open a pull request',
      subtitle: 'Pushes ${s.branch} to origin and opens a PR against ${s.prBase}. The first line is the title; the rest is the description.',
      initial: s.subject ?? '',
      placeholder: 'Title',
      submitLabel: 'Open PR ↗',
      onSubmit: (text, _) {
        final lines = text.split('\n');
        _send(ChangesPrCmd(widget.workerId, title: lines.first.trim(), body: lines.skip(1).join('\n').trim()));
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final w = store.workers[widget.workerId];
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ModalWindow(
        modal: widget.modal,
        width: 1300,
        height: 860,
        scrollBody: false,
        bodyPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Dot(hexColor(w?.color ?? '#888888')),
            const SizedBox(width: 10),
            Flexible(child: Text('${w?.name ?? _name} · changes', maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                branchLine(_state),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: heavy(13, color: Swatch.muted),
              ),
            ),
          ],
        ),
        headerExtras: [
          if (widget.onTerminal != null)
            OfficeButton(
              label: '⌨️ Terminal',
              tooltip: 'Open the terminal instead',
              dense: true,
              onPressed: () {
                widget.onTerminal!();
                widget.modal.close();
              },
            ),
        ],
        body: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 700;
            final files = _FilesList(state: _state, selected: _selected, onSelect: _select, scroll: _listScroll);
            final diff = _DiffPane(
              state: _state,
              file: _file(_selected),
              diff: _diff,
              error: _diffError,
              name: _name,
              onDiscard: _discardOne,
              pictureUrl: (f, side) => serverUrl(pictureUrl(widget.scope.store.floor, widget.workerId, f, side)),
            );
            return Flex(
              direction: narrow ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (narrow) SizedBox(height: box.maxHeight * 0.38, child: files) else SizedBox(width: 320, child: files),
                Expanded(child: diff),
              ],
            );
          },
        ),
        footer: _Footer(state: _state, onDiscardAll: _discardAll, onCommit: _commit, onPr: _openPr),
      ),
    );
  }
}

/// +adds −dels, or "binary".
class _PlusMinus extends StatelessWidget {
  const _PlusMinus(this.adds, this.dels, {this.binary = false});

  final int adds;
  final int dels;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    final base = _mono.copyWith(fontSize: 11, fontWeight: FontWeight.w800);
    if (binary) return Text('binary', style: base.copyWith(color: Swatch.muted));
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(
            text: '+$adds',
            style: const TextStyle(color: _addColor),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: '−$dels',
            style: const TextStyle(color: _delColor),
          ),
        ],
      ),
      softWrap: false,
    );
  }
}

/// The .st badge: M, A, D, R or T on its colour.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);

  final ChangeStatus status;

  @override
  Widget build(BuildContext context) {
    final letter = statusLetter(status);
    final (bg, fg) = switch (letter) {
      'M' => (Swatch.warn, Swatch.ink),
      'A' => (Swatch.good, Colors.white),
      'D' => (Swatch.bad, Colors.white),
      _ => (Swatch.info, Swatch.ink),
    };
    return Tooltip(
      message: kStatusWord[status]!,
      child: Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Swatch.ink, width: 2),
        ),
        child: Text(
          letter,
          style: _mono.copyWith(fontSize: 11, fontWeight: FontWeight.w900, color: fg, height: 1),
        ),
      ),
    );
  }
}

class _FilesList extends StatelessWidget {
  const _FilesList({required this.state, required this.selected, required this.onSelect, required this.scroll});

  final ChangesState? state;
  final String? selected;
  final ValueChanged<String> onSelect;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final s = state;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Swatch.paper2,
        border: Border(
          right: BorderSide(color: Swatch.ink, width: kBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _faint, width: 2)),
            ),
            child: Text(
              filesHeading(s).toUpperCase(),
              style: heavy(12, color: Swatch.muted, weight: FontWeight.w900).copyWith(letterSpacing: 12 * 0.04),
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.all(6),
              children: [
                if (s != null)
                  for (final f in s.files) _FileRow(f: f, on: f.path == selected, onTap: () => onSelect(f.path)),
                if (s != null && s.more > 0)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Center(
                      child: Text('…and ${s.more} more', style: heavy(13, weight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({required this.f, required this.on, required this.onTap});

  final ChangedFile f;
  final bool on;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  void didUpdateWidget(_FileRow old) {
    super.didUpdateWidget(old);
    // Keep the picked file in view as j/k walk the list.
    if (widget.on && !old.on) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        if (mounted) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final i = f.path.lastIndexOf('/');
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: widget.on ? Colors.white : (_hover ? Colors.white.withValues(alpha: 0.7) : null),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: widget.on ? Swatch.ink : Colors.transparent, width: 2),
              boxShadow: widget.on ? const [BoxShadow(color: Swatch.ink, offset: Offset(0, 2))] : null,
            ),
            child: Row(
              spacing: 8,
              children: [
                _StatusBadge(f.status),
                Expanded(
                  child: Tooltip(
                    message: f.path,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (i >= 0)
                            TextSpan(
                              text: f.path.substring(0, i + 1),
                              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
                            ),
                          TextSpan(text: f.path.substring(i + 1)),
                        ],
                      ),
                      style: heavy(13, weight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (f.uncommitted)
                  Tooltip(
                    message: 'Not committed yet',
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Swatch.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Swatch.ink, width: 1.5),
                      ),
                    ),
                  ),
                _PlusMinus(f.additions, f.deletions, binary: f.binary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiffPane extends StatelessWidget {
  const _DiffPane({
    required this.state,
    required this.file,
    required this.diff,
    required this.error,
    required this.name,
    required this.onDiscard,
    required this.pictureUrl,
  });

  final ChangesState? state;
  final ChangedFile? file;
  final List<DiffLine>? diff;
  final String? error;
  final String name;
  final ValueChanged<ChangedFile> onDiscard;

  /// Where one side ('old' or 'new') of a changed picture loads from.
  final String Function(ChangedFile f, String side) pictureUrl;

  @override
  Widget build(BuildContext context) {
    final f = file;
    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (f != null) _diffHead(f),
          Expanded(child: _diffBody(f)),
        ],
      ),
    );
  }

  Widget _diffHead(ChangedFile f) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _faint, width: 2)),
    ),
    child: Row(
      spacing: 10,
      children: [
        _StatusBadge(f.status),
        Expanded(
          child: Tooltip(
            message: f.path,
            waitDuration: const Duration(milliseconds: 600),
            child: Text(
              f.from != null ? '${f.from} → ${f.path}' : f.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _mono.copyWith(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        Text(
          f.uncommitted ? '${kStatusWord[f.status]} · not committed' : kStatusWord[f.status]!,
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
        ),
        _PlusMinus(f.additions, f.deletions, binary: f.binary),
        if (f.uncommitted && state?.busy == null)
          OfficeButton(label: '↩︎ Discard', dense: true, tooltip: 'Throw away the uncommitted changes to this file', onPressed: () => onDiscard(f)),
      ],
    ),
  );

  Widget _diffBody(ChangedFile? f) {
    final s = state;
    if (f == null) {
      if (s == null) return const _Empty(children: [Spinner()]);
      if (s.error != null) return _Empty(big: '🚧', children: [_EmptyText("Couldn't read ${whereText(s)}: ${s.error}")]);
      return _Empty(
        big: '🌱',
        children: [
          _EmptyText(s.base == 'HEAD' ? 'Nothing uncommitted in ${whereText(s)}.' : "$name hasn't changed anything since ${s.base} yet."),
          const _EmptyText('This window follows the checkout as the worker works, so changes show up here as they are made.', note: true),
        ],
      );
    }
    final type = changedImageType(f.path);
    final text = error != null
        ? _Empty(children: [_EmptyText(error!)])
        : diff == null
            ? null
            : SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: diff!.length,
                  itemBuilder: (context, i) => _DiffRow(diff![i]),
                ),
              );
    if (text == null) return const SizedBox.shrink();
    if (type == null) return text;
    // A picture's diff only says it differs, so show the picture instead. An SVG is text too: its diff stays below.
    final preview = _PicturePreview(file: f, url: pictureUrl);
    if (type != 'image/svg+xml') return SingleChildScrollView(child: preview);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: SingleChildScrollView(child: preview)),
        Expanded(child: text),
      ],
    );
  }
}

/// A changed picture, before and after, each on a checkerboard so its transparent parts show.
class _PicturePreview extends StatelessWidget {
  const _PicturePreview({required this.file, required this.url});

  final ChangedFile file;
  final String Function(ChangedFile f, String side) url;

  @override
  Widget build(BuildContext context) {
    final sides = pictureSides(file);
    final figures = [for (final side in sides) Expanded(child: _Figure(file: file, side: side, url: url(file, side)))];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 500
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final side in sides) _Figure(file: file, side: side, url: url(file, side))])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < figures.length; i++) ...[if (i > 0) const SizedBox(width: 12), figures[i]]]),
      ),
    );
  }
}

class _Figure extends StatefulWidget {
  const _Figure({required this.file, required this.side, required this.url});

  final ChangedFile file;
  final String side;
  final String url;

  @override
  State<_Figure> createState() => _FigureState();
}

class _FigureState extends State<_Figure> {
  String _size = '';

  @override
  Widget build(BuildContext context) {
    final old = widget.side == 'old';
    final label = old ? 'Before' : 'After';
    final alt = '${old ? widget.file.from ?? widget.file.path : widget.file.path} (${label.toLowerCase()})';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label.toUpperCase(), style: heavy(12, color: Swatch.muted, weight: FontWeight.w900)),
              const SizedBox(width: 8),
              Text(_size, style: heavy(12, color: Swatch.muted)),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(minHeight: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _faint, width: 2)),
            child: CustomPaint(
              painter: const _Checkerboard(),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
                  child: Semantics(
                    label: alt,
                    image: true,
                    child: Image.network(
                      widget.url,
                      key: ValueKey(widget.url),
                      headers: imageHeaders(),
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, progress) => progress == null ? child : const Padding(padding: EdgeInsets.all(20), child: Spinner()),
                      errorBuilder: (_, _, _) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          "Couldn't load the picture ${old ? 'from before' : 'as it is now'}.",
                          style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSize();
  }

  @override
  void didUpdateWidget(_Figure old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _resolveSize();
  }

  ImageStream? _stream;
  ImageStreamListener? _listener;

  void _resolveSize() {
    if (_listener != null) _stream?.removeListener(_listener!);
    final stream = NetworkImage(widget.url, headers: imageHeaders()).resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      if (mounted) setState(() => _size = '${info.image.width} × ${info.image.height}');
    }, onError: (_, _) {});
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }
}

/// The checkerboard behind a picture (16px squares of #eeeae4 and white).
class _Checkerboard extends CustomPainter {
  const _Checkerboard();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final p = Paint()..color = const Color(0xFFEEEAE4);
    for (var y = 0.0; y < size.height; y += 8) {
      for (var x = ((y / 8).round().isOdd ? 8.0 : 0.0); x < size.width; x += 16) {
        canvas.drawRect(Rect.fromLTWH(x, y, 8, 8), p);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => false;
}

class _DiffRow extends StatelessWidget {
  const _DiffRow(this.line);

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final (bg, lnBg) = switch (line.kind) {
      DiffKind.add => (const Color(0xFFE3F9EA), const Color(0xFFC9F0D5)),
      DiffKind.del => (const Color(0xFFFFE3EA), const Color(0xFFFFCBD7)),
      DiffKind.hunk => (const Color(0xFFE0F2FE), const Color(0x0A2B2D42)),
      _ => (null, const Color(0x0A2B2D42)),
    };
    final style = _mono.copyWith(
      fontSize: 12.5,
      height: 1.45,
      color: switch (line.kind) {
        DiffKind.hunk => const Color(0xFF1D6FD6),
        DiffKind.meta => Swatch.muted,
        _ => Swatch.ink,
      },
      fontWeight: line.kind == DiffKind.hunk ? FontWeight.w700 : FontWeight.w400,
      fontStyle: line.kind == DiffKind.meta ? FontStyle.italic : FontStyle.normal,
    );
    final lnStyle = _mono.copyWith(fontSize: 12.5, height: 1.45, color: const Color(0xFF9A9088));
    Widget ln(String n) => SelectionContainer.disabled(
      child: Container(
        width: 44,
        color: lnBg,
        padding: const EdgeInsets.only(right: 6),
        alignment: Alignment.topRight,
        child: Text(n, style: lnStyle),
      ),
    );
    return Container(
      margin: EdgeInsets.only(top: line.kind == DiffKind.hunk ? 6 : 0),
      color: bg,
      constraints: const BoxConstraints(minHeight: 12.5 * 1.45),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ln(line.old),
            ln(line.now),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                // Tabs as 4 spaces (tab-size: 4).
                child: Text(line.code.replaceAll('\t', '    '), style: style),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.big, required this.children});

  final String? big;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (big != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(big!, style: const TextStyle(fontSize: 48, height: 1)),
              ),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class _EmptyText extends StatelessWidget {
  const _EmptyText(this.text, {this.note = false});

  final String text;
  final bool note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: heavy(note ? 13 : 14, color: Swatch.muted, weight: note ? FontWeight.w600 : FontWeight.w700),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.onDiscardAll, required this.onCommit, required this.onPr});

  final ChangesState? state;
  final VoidCallback onDiscardAll;
  final VoidCallback onCommit;
  final ValueChanged<ChangesState> onPr;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final busy = s?.busy != null;
    final uncommitted = uncommittedCount(s);
    return Row(
      spacing: 8,
      children: [
        Expanded(child: _summary(s)),
        OfficeButton(
          label: '🗑️ Discard all',
          tooltip: 'Throw away every uncommitted change in this checkout',
          onPressed: busy || uncommitted == 0 ? null : onDiscardAll,
        ),
        OfficeButton(label: commitLabel(uncommitted), tooltip: 'git add -A && git commit', onPressed: busy || uncommitted == 0 ? null : onCommit),
        ?_prSlot(s, busy),
      ],
    );
  }

  Widget _summary(ChangesState? s) {
    final muted = heavy(12, color: Swatch.muted, weight: FontWeight.w700);
    if (s == null) return const SizedBox.shrink();
    if (s.busy != null) {
      return Row(
        spacing: 6,
        children: [
          const Spinner(),
          Flexible(child: Text(s.busy!, style: muted)),
        ],
      );
    }
    if (s.error != null) return const SizedBox.shrink();
    final adds = s.files.fold(0, (n, f) => n + f.additions);
    final dels = s.files.fold(0, (n, f) => n + f.deletions);
    final parts = <Widget>[
      if (s.files.isNotEmpty) _PlusMinus(adds, dels),
      for (final b in summaryBits(s))
        b.tip == null
            ? Text(b.text, style: muted)
            : Tooltip(
                message: b.tip!,
                child: Text(b.text, style: muted),
              ),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < parts.length; i++) ...[if (i > 0) Text('·', style: muted), parts[i]],
      ],
    );
  }

  Widget? _prSlot(ChangesState? s, bool busy) {
    if (s == null) return null;
    final pr = s.pr;
    if (pr != null) {
      return OfficeButton(label: '🔀 PR #${pr.number} ↗', kind: BtnKind.primary, tooltip: 'Open on GitHub', onPressed: () => openInNewTab(pr.url));
    }
    if (s.prBase == null) return null;
    final why = prBlocked(s);
    return OfficeButton(
      label: '🔀 Open PR…',
      kind: BtnKind.primary,
      tooltip: why.isNotEmpty ? why : 'Push ${s.branch} and open a pull request against ${s.prBase}',
      onPressed: busy || why.isNotEmpty ? null : () => onPr(s),
    );
  }
}
