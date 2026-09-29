// The bookshelf (ui/bookshelf.ts): every Markdown file in the floor's project, to read without leaving
// the office. The filter box over the list picks docs out as you type (the letters in order, not
// necessarily together; a few words narrow it further), ↑ ↓ and Enter open one, and it reads beside
// the list, rendered as GitHub shows it: links to other docs open them here, pictures come from the
// project, and the contents menu jumps to a heading.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:office_shared/docs.dart';

import '../interop/open_link.dart';
import '../interop/portable.dart' show storageGet, storageSet;
import '../net/api.dart';
import 'bookshelf_logic.dart';
import 'markdown.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

const _lastKey = 'agent-office.bookshelf';

String? _lastRead(String floor) {
  try {
    final all = jsonDecode(storageGet(_lastKey) ?? '{}');
    return all is Map ? all[floor] as String? : null;
  } catch (_) {
    return null;
  }
}

void _rememberRead(String floor, String path) {
  try {
    final all = jsonDecode(storageGet(_lastKey) ?? '{}');
    final m = all is Map ? Map<String, dynamic>.from(all) : <String, dynamic>{};
    m[floor] = path;
    storageSet(_lastKey, jsonEncode(m));
  } catch (_) {
    // Storage blocked: it just won't reopen where you were.
  }
}

/// Opens the bookshelf for [floor]'s project. [onTurn] is you turning a page (opening a doc, or
/// scrolling a screenful); [onReading] says what you're reading, for everyone on the floor.
ModalHandle openBookshelf({
  required String floor,
  String? project,
  String? repoUrl,
  void Function()? onTurn,
  void Function(String? what)? onReading,
}) {
  late final ModalHandle handle;
  handle = ModalStack.instance.show(
    (modal) => _Bookshelf(
      modal: modal,
      floor: floor,
      project: project,
      repoUrl: repoUrl,
      onTurn: onTurn ?? () {},
      // What you're reading goes under your name tag, through the window's doing.
      onReading: (what) {
        handle.doing = what;
        onReading?.call(what);
      },
    ),
    onClose: () => onReading?.call(null),
  );
  handle
    ..doing = '📚 at the bookshelf'
    ..reading = true;
  return handle;
}

class _Bookshelf extends StatefulWidget {
  const _Bookshelf({
    required this.modal,
    required this.floor,
    required this.project,
    required this.repoUrl,
    required this.onTurn,
    required this.onReading,
  });

  final ModalHandle modal;
  final String floor;
  final String? project;
  final String? repoUrl;
  final VoidCallback onTurn;
  final void Function(String? what) onReading;

  @override
  State<_Bookshelf> createState() => _BookshelfState();
}

class _BookshelfState extends State<_Bookshelf> {
  final TextEditingController _filter = TextEditingController();
  final FocusNode _filterFocus = FocusNode();
  final ScrollController _page = ScrollController();
  final ScrollController _list = ScrollController();
  final Map<String, ({int level, String text, GlobalKey key})> _anchors = {};

  List<DocFile> _files = [];
  List<DocHit> _shown = [];
  bool _more = false;
  String? _listError;
  bool _loaded = false;

  /// Which of [_shown] ↑ ↓ are on.
  int _sel = 0;

  /// The doc open now, and its text.
  String? _current;
  DocText? _doc;
  String? _pageNote;

  /// Each open's number, so a slow one that's been overtaken is dropped.
  int _opening = 0;

  /// Where the page was last time it turned.
  double _turnedAt = 0;

  String _q(Map<String, String> params) => Uri(queryParameters: {'floor': widget.floor, ...params}).query;

  @override
  void initState() {
    super.initState();
    _page.addListener(_scrolled);
    // A moment later, so the E that opened the shelf isn't typed into the box.
    Timer(const Duration(milliseconds: 30), () {
      if (mounted) _filterFocus.requestFocus();
    });
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    _page.dispose();
    _list.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Api.getJson('/api/docs?${_q({})}').catchError((Object e) => ApiResult(0, {'error': '$e'}));
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _listError = r.error('HTTP ${r.status}');
        _loaded = true;
      });
      return;
    }
    final list = DocList.fromJson(r.body);
    setState(() {
      _files = list.files;
      _more = list.more;
      _loaded = true;
      _refilter();
    });
    final paths = {for (final f in _files) f.path};
    final start = [
      _lastRead(widget.floor),
      ...shelfOrder(_files).map((f) => f.path),
    ].firstWhere((p) => p != null && paths.contains(p), orElse: () => null);
    if (start != null) {
      _open(start);
    } else {
      setState(() => _pageNote = '📭 Nothing to read here: this project has no Markdown files yet.');
    }
  }

  void _refilter() {
    _shown = filterDocs(_files, _filter.text);
    _sel = 0;
    if (_list.hasClients) _list.jumpTo(0);
  }

  void _move(int by) {
    if (_shown.isEmpty) return;
    setState(() => _sel = (_sel + by + _shown.length) % _shown.length);
  }

  Future<void> _open(String path, [String hash = '']) async {
    if (path == _current) return _jump(hash);
    final mine = ++_opening;
    final r = await Api.getJson('/api/docs/file?${_q({'path': path})}')
        .catchError((Object e) => ApiResult(0, {'error': '$e'}));
    if (mine != _opening || !mounted) return;
    if (!r.ok) {
      toast("📚 Couldn't open ${docName(path)}: ${r.error('HTTP ${r.status}')}", ToastKind.warn);
      if (_current == null) setState(() => _pageNote = "Couldn't open $path.");
      return;
    }
    final doc = DocText.fromJson(r.body);
    _rememberRead(widget.floor, path);
    setState(() {
      _current = path;
      _doc = doc;
      _pageNote = null;
    });
    _turnedAt = 0;
    if (_page.hasClients) _page.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The headings are known once the page has been laid out: the contents menu, and where to jump.
      if (!mounted) return;
      setState(() {});
      _jump(hash);
    });
    final info = _files.where((f) => f.path == path).firstOrNull;
    widget.onReading('📚 reading ${info?.title ?? docName(path)}');
    widget.onTurn();
  }

  /// Scrolls to the heading [hash] names in the doc open now.
  void _jump(String hash) {
    if (hash.isEmpty) {
      if (_page.hasClients) _page.jumpTo(0);
      return;
    }
    var id = hash;
    try {
      id = Uri.decodeComponent(hash);
    } catch (_) {
      // Not encoded after all.
    }
    id = id.replaceFirst(RegExp('^user-content-'), '');
    final at = _anchors[id] ?? _anchors[id.toLowerCase()];
    final ctx = at?.key.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx);
  }

  /// A link in the doc: other docs open here, the rest go to GitHub (or wherever they point).
  void _link(String href) {
    final path = _current;
    if (path == null) return openInNewTab(href);
    final to = resolveDocLink(path, href);
    if (to == null) return openInNewTab(href);
    if (to.path == path || isDocPath(to.path)) {
      _open(to.path, to.hash);
    } else if (widget.repoUrl != null) {
      openInNewTab(_github(to.path, to.hash));
    } else {
      toast(to.path);
    }
  }

  String _github(String path, [String hash = '']) =>
      '${widget.repoUrl}/blob/HEAD/${path.split('/').map(Uri.encodeComponent).join('/')}${hash.isEmpty ? '' : '#$hash'}';

  /// Every screenful you read, a page of the book in your hands turns.
  void _scrolled() {
    final view = _page.position.viewportDimension;
    if ((_page.offset - _turnedAt).abs() < view * 0.8) return;
    _turnedAt = _page.offset;
    widget.onTurn();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      _move(k == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (_sel < _shown.length) _open(_shown[_sel].doc.path);
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.pageUp) && _page.hasClients) {
      // The page, not the box: read on without leaving the filter.
      final by = (k == LogicalKeyboardKey.pageDown ? 1 : -1) * _page.position.viewportDimension * 0.85;
      _page.animateTo(
        (_page.offset + by).clamp(0, _page.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ModalWindow(
    modal: widget.modal,
    width: 1060,
    height: 700,
    scrollBody: false,
    bodyPadding: EdgeInsets.zero,
    title: Text('📚 Bookshelf${widget.project != null ? ' · ${widget.project}' : ''}'),
    body: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 290, child: _side()),
        Container(width: kBorder, color: Swatch.ink),
        Expanded(child: _reader()),
      ],
    ),
  );

  Widget _side() {
    final count = !_loaded
        ? 'Looking along the shelves…'
        : _files.isEmpty
        ? ''
        : _filter.text.trim().isNotEmpty
        ? '${_shown.length} of ${_files.length} docs'
        : '${_files.length} doc${_files.length == 1 ? '' : 's'}${_more ? ' (the first ${_files.length})' : ''}';
    return Container(
      color: Swatch.paper2,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            onKeyEvent: _key,
            skipTraversal: true,
            child: BoxInput(
              controller: _filter,
              focusNode: _filterFocus,
              hint: 'Filter the docs…',
              onChanged: (_) => setState(_refilter),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            count,
            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Expanded(child: _listView()),
        ],
      ),
    );
  }

  Widget _listView() {
    if (_listError != null) {
      return Text("Couldn't look along the shelves: $_listError", style: heavy(13, color: Swatch.muted));
    }
    if (_loaded && _files.isEmpty) {
      return Text('No Markdown files in this project yet.', style: heavy(13, color: Swatch.muted));
    }
    if (_loaded && _shown.isEmpty) return Text('No doc matches that.', style: heavy(13, color: Swatch.muted));
    return ListView.builder(
      controller: _list,
      itemCount: _shown.length,
      itemBuilder: (context, i) {
        final hit = _shown[i];
        final doc = hit.doc;
        final name = docName(doc.path);
        final title = doc.title ?? name;
        // Without a title of its own, the name's matched letters are the path's, moved along.
        final titleMarks = doc.title != null
            ? hit.title
            : {for (final p in hit.path) p - (doc.path.length - name.length)};
        final sel = i == _sel;
        final open = doc.path == _current;
        return GestureDetector(
          onTap: () {
            setState(() => _sel = i);
            _open(doc.path);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: open ? const Color(0xFFFFE3C8) : (sel ? Colors.white : Colors.transparent),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? Swatch.ink : Colors.transparent, width: 2),
              ),
              child: Tooltip(
                message: doc.path,
                waitDuration: const Duration(milliseconds: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(_marked(title, titleMarks, heavy(14)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text.rich(
                      _marked(doc.path, hit.path, heavy(11.5, color: Swatch.muted, weight: FontWeight.w600)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// [text] with the letters at [at] marked.
  TextSpan _marked(String text, Set<int> at, TextStyle style) {
    if (at.isEmpty) return TextSpan(text: text, style: style);
    final mark = style.copyWith(backgroundColor: const Color(0xFFFFD166), color: Swatch.ink);
    final spans = <TextSpan>[];
    var run = StringBuffer();
    var on = false;
    for (var i = 0; i <= text.length; i++) {
      final hit = at.contains(i);
      if (i == text.length || hit != on) {
        if (run.isNotEmpty) spans.add(TextSpan(text: run.toString(), style: on ? mark : style));
        run = StringBuffer();
        on = hit;
      }
      if (i < text.length) run.write(text[i]);
    }
    return TextSpan(children: spans);
  }

  Widget _reader() {
    final path = _current;
    final doc = _doc;
    final info = path == null ? null : _files.where((f) => f.path == path).firstOrNull;
    final name = path == null ? '' : docName(path);
    final dir = path == null ? '' : path.substring(0, path.length - name.length);
    final meta = [
      if (doc != null) readTime(doc.text),
      if (info != null) docSize(info.size),
      if (info != null) 'updated ${timeAgo(info.mtime)}',
    ].join(' · ');
    final heads = [
      for (final e in _anchors.entries)
        if (e.value.level <= 3 && e.value.text.isNotEmpty) e,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (path != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0x1F2B2D42), width: 2)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: dir,
                              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
                            ),
                            TextSpan(text: name, style: heavy(14)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        meta,
                        style: heavy(11.5, color: Swatch.muted, weight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                if (widget.repoUrl != null)
                  OfficeButton(label: 'GitHub ↗', dense: true, onPressed: () => openInNewTab(_github(path))),
                if (heads.length >= 3) ...[
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Jump to a heading',
                    onSelected: _jump,
                    itemBuilder: (_) => [
                      for (final h in heads)
                        PopupMenuItem(
                          value: h.key,
                          child: Text('${'  ' * (h.value.level - 1)}${clip(h.value.text, 60)}', style: heavy(13)),
                        ),
                    ],
                    child: const OfficeButton(label: '☰ Contents', dense: true),
                  ),
                ],
              ],
            ),
          ),
        Expanded(child: _page0(doc)),
      ],
    );
  }

  Widget _page0(DocText? doc) {
    if (doc == null) {
      return Center(
        child: _pageNote != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _pageNote!,
                  style: heavy(15, color: Swatch.muted),
                  textAlign: TextAlign.center,
                ),
              )
            : const CircularProgressIndicator(color: Swatch.accent),
      );
    }
    return SingleChildScrollView(
      controller: _page,
      child: doc.text.trim().isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text('This file is empty.', style: heavy(14, color: Swatch.muted)),
            )
          : MarkdownView(
              doc.text,
              key: ValueKey(doc.path),
              file: true,
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
              onLink: _link,
              anchors: _anchors,
              pictureSrc: (src) {
                final to = resolveDocLink(doc.path, src);
                return to != null ? '/api/docs/picture?${_q({'path': to.path})}' : imageSrc(src, null);
              },
            ),
    );
  }
}
