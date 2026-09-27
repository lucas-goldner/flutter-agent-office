// GitHub-flavoured markdown for issue and PR text, drawn as Flutter widgets: a port of markdown.ts.
//
// `package:markdown` parses it (GFM: tables, task lists, strikethrough, autolinks) and this file
// draws the tree the way style.css drew `.md`. Nothing becomes HTML, so there is nothing to
// sanitise; raw HTML in the source is shown as its text (a <br> breaks the line, an <img> shows
// the picture) and its tags are dropped. Links open in a new tab. Pictures from other hosts come
// through the office's /api/image, which fetches them for us (as gallery.ts does), so CORS on
// their host doesn't matter.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../interop/open_url.dart';
import '../net/server.dart';
import 'theme.dart';


/// Monospaced text (code, paths, diffs).
TextStyle mono(double size, {Color color = Swatch.ink, FontWeight weight = FontWeight.w400, double? height}) =>
    TextStyle(fontFamily: kMono, fontFamilyFallback: kMonoFallback, fontSize: size, color: color, fontWeight: weight, height: height);

const _link = Color(0xFF1D6FD6);
const _rule = Color(0xFFDDD0BF);

/// https://github.com/owner/repo from an issue or PR URL.
String repoUrlOf(String itemUrl) => itemUrl.replaceFirst(RegExp(r'/(pull|issues)/\d+.*$'), '');

/// The office fetches images for us, so a picture shows up whatever its host allows.
String imageUrl(String url) => '/api/image?url=${Uri.encodeComponent(url)}';

final _scheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false);

/// Relative links in a PR body mean GitHub pages: #anchors on the PR, paths in the repo.
String absolutize(String v, {required String? itemUrl, required bool anchors}) {
  if (itemUrl == null) return v;
  final repoUrl = repoUrlOf(itemUrl);
  if (v.isEmpty || _scheme.hasMatch(v) || v.startsWith('//')) return v;
  if (v.startsWith('#')) return anchors ? '${itemUrl.split('#').first}$v' : v;
  if (v.startsWith('/')) return 'https://github.com$v';
  return '$repoUrl/blob/HEAD/${v.replaceFirst(RegExp(r'^\./'), '')}';
}

/// Where the widget loads a picture from: through the office unless it's already on it.
String imageSrc(String src, String? itemUrl) {
  var s = absolutize(src, itemUrl: itemUrl, anchors: false);
  if (s.startsWith('//')) s = 'https:$s';
  return RegExp(r'^https?://', caseSensitive: false).hasMatch(s) ? imageUrl(s) : s;
}

/// Links #123 to the issue or PR and @name to the person, outside code and existing links.
class RefSyntax extends md.InlineSyntax {
  RefSyntax(this.repoUrl)
      : super(repoUrl == null
            ? r'(?<![\w/&#`])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\b'
            : r'(?<![\w/&#`])(?:#(\d+)|@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38})))\b');

  final String? repoUrl;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final issue = repoUrl == null ? null : match[1];
    final user = repoUrl == null ? match[1] : match[2];
    final a = md.Element.text('a', match[0]!)
      ..attributes['href'] = issue != null ? '$repoUrl/issues/$issue' : 'https://github.com/$user'
      ..attributes['class'] = issue != null ? 'ref' : 'mention';
    parser.addNode(a);
    return true;
  }
}

/// Inline HTML, kept apart from text so the renderer can drop its tags.
class _RawHtmlSyntax extends md.InlineHtmlSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('rawhtml', match[0]!));
    return true;
  }
}

/// Parses GFM the way the old client's marked did (breaks: true is applied when drawing).
List<md.Node> parseMarkdown(String src, {String? itemUrl}) {
  final doc = md.Document(
    extensionSet: md.ExtensionSet(
      const [md.FencedCodeBlockSyntax(), md.TableSyntax(), md.UnorderedListWithCheckboxSyntax(), md.OrderedListWithCheckboxSyntax()],
      [_RawHtmlSyntax(), md.StrikethroughSyntax(), md.AutolinkExtensionSyntax()],
    ),
    inlineSyntaxes: [RefSyntax(itemUrl == null ? null : repoUrlOf(itemUrl))],
    encodeHtml: false,
  );
  final nodes = doc.parse(src.replaceAll('\r\n', '\n'));
  _alerts(nodes);
  return nodes;
}

enum AlertKind { note, tip, important, warning, caution }

const _alertTitle = {
  AlertKind.note: 'ℹ️ Note',
  AlertKind.tip: '💡 Tip',
  AlertKind.important: '❗ Important',
  AlertKind.warning: '⚠️ Warning',
  AlertKind.caution: '🛑 Caution',
};

const _alertColors = {
  AlertKind.note: (Color(0xFF1D6FD6), Color(0xFFEAF3FF)),
  AlertKind.tip: (Color(0xFF2A9D4B), Color(0xFFE6F8EC)),
  AlertKind.important: (Color(0xFF9D4EDD), Color(0xFFF3E8FF)),
  AlertKind.warning: (Color(0xFFE0A100), Color(0xFFFFF6D6)),
  AlertKind.caution: (Color(0xFFC3423F), Color(0xFFFFEBEE)),
};

final _alertRe = RegExp(r'^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*', caseSensitive: false);

/// `> [!NOTE]` blockquotes become callouts, as on GitHub: the blockquote is tagged with its kind
/// and the marker is dropped from its first paragraph.
void _alerts(List<md.Node> nodes) {
  for (final n in nodes) {
    if (n is! md.Element) continue;
    if (n.children != null) _alerts(n.children!);
    if (n.tag != 'blockquote' || n.children == null || n.children!.isEmpty) continue;
    final p = n.children!.first;
    if (p is! md.Element || p.tag != 'p' || p.children == null) continue;
    final m = _alertRe.firstMatch(p.textContent);
    if (m == null) continue;
    // Eat the marker out of the leading text nodes; give up if something else is in the way.
    var left = m[0]!.length;
    final kids = p.children!;
    while (left > 0 && kids.isNotEmpty && kids.first is md.Text) {
      final t = (kids.first as md.Text).text;
      if (t.length <= left) {
        left -= t.length;
        kids.removeAt(0);
      } else {
        kids[0] = md.Text(t.substring(left));
        left = 0;
      }
    }
    if (left > 0) continue;
    if (kids.isNotEmpty && kids.first is md.Text) {
      kids[0] = md.Text((kids.first as md.Text).text.replaceFirst(RegExp(r'^\s+'), ''));
    }
    if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'br') kids.removeAt(0);
    if (p.textContent.trim().isEmpty && !_hasImage(p)) n.children!.removeAt(0);
    n.attributes['alert'] = m[1]!.toLowerCase();
  }
}

bool _hasImage(md.Element e) =>
    e.tag == 'img' || (e.children ?? const []).any((c) => c is md.Element && _hasImage(c));

/// A `.md` block. [itemUrl] (the issue or PR on GitHub) anchors its relative links and #refs.
class MarkdownView extends StatefulWidget {
  const MarkdownView(
    this.src, {
    super.key,
    this.itemUrl,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    this.fontSize = 14.5,
    this.onLink,
    this.selectable = true,
  });

  final String src;
  final String? itemUrl;
  final EdgeInsetsGeometry padding;
  final double fontSize;

  /// What a click on a link does; opens it in a new tab by default.
  final void Function(String href)? onLink;
  final bool selectable;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late List<md.Node> _nodes;
  final List<TapGestureRecognizer> _taps = [];

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src || old.itemUrl != widget.itemUrl) _parse();
  }

  void _parse() => _nodes = widget.src.trim().isEmpty ? const [] : parseMarkdown(widget.src, itemUrl: widget.itemUrl);

  void _dropTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _dropTaps();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dropTaps();
    final base = TextStyle(fontFamily: kFont, fontFamilyFallback: kFallback, fontSize: widget.fontSize, height: 1.6, fontWeight: FontWeight.w500, color: Swatch.ink);
    Widget body;
    if (_nodes.isEmpty) {
      body = Text('No description provided.', style: base.copyWith(color: Swatch.muted, fontStyle: FontStyle.italic));
    } else {
      final r = _Renderer(
        base: base,
        itemUrl: widget.itemUrl,
        taps: _taps,
        onLink: widget.onLink ?? openUrl,
      );
      body = r.blocks(_nodes);
    }
    body = Padding(padding: widget.padding, child: DefaultTextStyle(style: base, child: body));
    return widget.selectable ? SelectionArea(child: body) : body;
  }
}

/// One block and the margins around it, which collapse into each other like CSS margins.
class _Block {
  _Block(this.widget, {this.top = 0, this.bottom = 12});
  final Widget widget;
  final double top;
  final double bottom;
}

class _Renderer {
  _Renderer({required this.base, required this.itemUrl, required this.taps, required this.onLink});

  final TextStyle base;
  final String? itemUrl;
  final List<TapGestureRecognizer> taps;
  final void Function(String) onLink;

  static const _headSizes = {'h1': 22.0, 'h2': 19.0, 'h3': 16.5, 'h4': 15.0, 'h5': 14.0, 'h6': 14.0};
  static const _blockTags = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'blockquote', 'pre', 'table', 'hr', 'div', 'li',
  };

  /// Blocks stacked with collapsed margins; the first has no top margin and the last no bottom.
  Widget blocks(List<md.Node> nodes, {double gap = 12}) {
    final list = <_Block>[];
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      list.add(_Block(paragraph(List.of(inline)), bottom: gap));
      inline.clear();
    }

    for (final n in nodes) {
      if (n is md.Element && _blockTags.contains(n.tag)) {
        flush();
        final b = block(n, gap: gap);
        if (b != null) list.add(b);
      } else if (n is md.Text && inline.isEmpty && n.text.trimLeft().startsWith('<') && n.text.contains('>')) {
        // An HTML block.
        flush();
        final w = htmlBlock(n.text);
        if (w != null) list.add(_Block(w, bottom: gap));
      } else {
        inline.add(n);
      }
    }
    flush();
    if (list.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        final space = list[i - 1].bottom > list[i].top ? list[i - 1].bottom : list[i].top;
        children.add(SizedBox(height: space));
      }
      children.add(list[i].widget);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }

  _Block? block(md.Element e, {double gap = 12}) {
    final kids = e.children ?? const <md.Node>[];
    switch (e.tag) {
      case 'p':
        return _Block(paragraph(kids), bottom: gap);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final size = _headSizes[e.tag]!;
        final style = base.copyWith(fontSize: size, fontWeight: FontWeight.w900, height: 1.25, color: e.tag == 'h5' || e.tag == 'h6' ? Swatch.muted : null);
        Widget w = paragraph(kids, style: style);
        if (e.tag == 'h1' || e.tag == 'h2') {
          w = Container(
            padding: EdgeInsets.only(bottom: e.tag == 'h1' ? 5 : 4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x1F2B2D42), width: 2))),
            child: w,
          );
        }
        return _Block(w, top: 20, bottom: 8);
      case 'hr':
        return _Block(const _DashedRule(), top: 18, bottom: 18);
      case 'pre':
        return _Block(codeBlock(e.textContent), bottom: gap);
      case 'blockquote':
        return _Block(blockquote(e), bottom: gap);
      case 'ul' || 'ol':
        return _Block(list(e), bottom: gap);
      case 'table':
        return _Block(table(e), bottom: gap);
      default:
        return _Block(blocks(kids), bottom: gap);
    }
  }

  Widget codeBlock(String text) => Container(
        decoration: BoxDecoration(
          color: Swatch.termBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Swatch.ink, width: 2),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text(text.replaceFirst(RegExp(r'\n$'), ''), style: mono(12.5, color: const Color(0xFFE9ECEF), height: 1.5)),
        ),
      );

  Widget blockquote(md.Element e) {
    final kind = switch (e.attributes['alert']) {
      final String k => AlertKind.values.byName(k),
      null => null,
    };
    if (kind == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFFD9CBB8), width: 4))),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Swatch.muted),
          child: _Renderer(base: base.copyWith(color: Swatch.muted), itemUrl: itemUrl, taps: taps, onLink: onLink).blocks(e.children ?? const []),
        ),
      );
    }
    final (border, bg) = _alertColors[kind]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border(left: BorderSide(color: border, width: 4)),
        borderRadius: const BorderRadius.only(topRight: Radius.circular(10), bottomRight: Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(_alertTitle[kind]!, style: base.copyWith(fontWeight: FontWeight.w900)),
          ),
          if (e.children!.isNotEmpty) blocks(e.children!),
        ],
      ),
    );
  }

  Widget list(md.Element e) {
    final ordered = e.tag == 'ol';
    var n = int.tryParse(e.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final li in e.children ?? const <md.Node>[]) {
      if (li is! md.Element || li.tag != 'li') continue;
      final kids = List<md.Node>.of(li.children ?? const []);
      // Task list boxes: shown ticked or not, but they don't do anything here.
      bool? checked;
      if (li.attributes['class'] == 'task-list-item') {
        md.Element? box;
        if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'input') {
          box = kids.removeAt(0) as md.Element;
        } else if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'p') {
          final pk = (kids.first as md.Element).children!;
          if (pk.isNotEmpty && pk.first is md.Element && (pk.first as md.Element).tag == 'input') box = pk.removeAt(0) as md.Element;
        }
        if (box != null) checked = box.attributes['checked'] != null;
      }
      final marker = checked != null
          ? Padding(padding: const EdgeInsets.only(right: 6, top: 5), child: _TaskBox(checked))
          : SizedBox(
              width: 26,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(ordered ? '${n++}.' : '•', textAlign: TextAlign.right, style: base),
              ),
            );
      items.add(Padding(
        padding: EdgeInsets.only(top: items.isEmpty ? 0 : 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (checked != null) const SizedBox(width: 6),
            marker,
            Expanded(child: blocks(kids, gap: 4)),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: items);
  }

  Widget table(md.Element e) {
    final rows = <(md.Element, bool)>[];
    for (final part in e.children ?? const <md.Node>[]) {
      if (part is! md.Element) continue;
      for (final tr in part.children ?? const <md.Node>[]) {
        if (tr is md.Element && tr.tag == 'tr') rows.add((tr, part.tag == 'thead'));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.$1.children?.length ?? 0).reduce((a, b) => a > b ? a : b);
    var body = 0;
    final small = base.copyWith(fontSize: 13.5);
    final tableRows = [
      for (final (tr, head) in rows)
        TableRow(
          decoration: BoxDecoration(
            color: head ? Swatch.paper2 : ((body++).isOdd ? Swatch.paper : Colors.white),
          ),
          children: [
            for (var i = 0; i < cols; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                child: i < (tr.children?.length ?? 0)
                    ? paragraph(
                        (tr.children![i] as md.Element).children ?? const [],
                        style: head ? small.copyWith(fontWeight: FontWeight.w900) : small,
                        align: switch ((tr.children![i] as md.Element).attributes['align']) {
                          'center' => TextAlign.center,
                          'right' => TextAlign.right,
                          _ => TextAlign.left,
                        },
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        ),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: _rule, width: 1.5),
          children: tableRows,
        ),
      ),
    );
  }

  /// A paragraph; with breaks: true a newline in it is a line break, as in GitHub comments.
  Widget paragraph(List<md.Node> nodes, {TextStyle? style, TextAlign align = TextAlign.left}) {
    final s = style ?? base;
    // A paragraph that is just a picture is the picture.
    final meaningful = nodes.where((n) => !(n is md.Text && n.text.trim().isEmpty)).toList();
    if (meaningful.length == 1 && meaningful.first is md.Element && (meaningful.first as md.Element).tag == 'img') {
      return Align(alignment: Alignment.centerLeft, child: image(meaningful.first as md.Element));
    }
    final spans = <InlineSpan>[];
    for (final n in nodes) {
      inline(n, s, spans, null);
    }
    _trimTrailingBreak(spans);
    return Text.rich(TextSpan(style: s, children: spans), textAlign: align);
  }

  void _trimTrailingBreak(List<InlineSpan> spans) {
    while (spans.isNotEmpty && spans.last is TextSpan && (spans.last as TextSpan).text == '\n' && (spans.last as TextSpan).children == null) {
      spans.removeLast();
    }
  }

  TapGestureRecognizer _tap(String href) {
    final t = TapGestureRecognizer()..onTap = () => onLink(href);
    taps.add(t);
    return t;
  }

  void inline(md.Node n, TextStyle s, List<InlineSpan> out, String? href) {
    TapGestureRecognizer? rec() => href == null ? null : _tap(href);
    if (n is md.Text) {
      if (n.text.isEmpty) return;
      out.add(TextSpan(text: n.text, style: s, recognizer: rec(), mouseCursor: href == null ? null : SystemMouseCursors.click));
      return;
    }
    if (n is! md.Element) return;
    final kids = n.children ?? const <md.Node>[];
    switch (n.tag) {
      case 'strong' || 'b':
        for (final k in kids) {
          inline(k, s.copyWith(fontWeight: FontWeight.w900), out, href);
        }
      case 'em' || 'i':
        for (final k in kids) {
          inline(k, s.copyWith(fontStyle: FontStyle.italic), out, href);
        }
      case 'del' || 's':
        for (final k in kids) {
          inline(k, s.copyWith(decoration: TextDecoration.lineThrough), out, href);
        }
      case 'code':
        out.add(TextSpan(
          text: n.textContent,
          style: mono(12.5, color: s.color ?? Swatch.ink).copyWith(backgroundColor: const Color(0xFFF3EBE0)),
          recognizer: rec(),
        ));
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'a':
        // Links inside links (a #ref in a link's text) stay part of the outer one.
        final to = href ?? absolutize(n.attributes['href'] ?? '', itemUrl: itemUrl, anchors: true);
        final linkStyle = s.copyWith(
          color: _link,
          fontWeight: n.attributes['class'] != null ? FontWeight.w800 : FontWeight.w700,
        );
        for (final k in kids) {
          inline(k, linkStyle, out, to.isEmpty ? null : to);
        }
      case 'img':
        out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: image(n)));
      case 'input':
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(padding: const EdgeInsets.only(right: 6), child: _TaskBox(n.attributes['checked'] != null)),
        ));
      case 'rawhtml':
        _inlineHtml(n.textContent, s, out, href);
      default:
        for (final k in kids) {
          inline(k, s, out, href);
        }
    }
  }

  static final _tagRe = RegExp(r'<!--[\s\S]*?-->|<[^>]*>');
  static final _imgRe = RegExp(r'^<img\b', caseSensitive: false);
  static final _brRe = RegExp(r'^<br\s*/?>$', caseSensitive: false);

  static String? _attr(String tag, String name) {
    final m = RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false).firstMatch(tag);
    return m == null ? null : (m[1] ?? m[2] ?? m[3]);
  }

  md.Element _imgOf(String tag) {
    final e = md.Element.empty('img');
    e.attributes['src'] = _attr(tag, 'src') ?? '';
    e.attributes['alt'] = _attr(tag, 'alt') ?? '';
    final w = _attr(tag, 'width');
    if (w != null) e.attributes['width'] = w;
    return e;
  }

  /// Inline HTML: a <br> breaks the line and an <img> is drawn; other tags are dropped.
  void _inlineHtml(String raw, TextStyle s, List<InlineSpan> out, String? href) {
    if (_brRe.hasMatch(raw.trim())) {
      out.add(const TextSpan(text: '\n'));
    } else if (_imgRe.hasMatch(raw.trim())) {
      out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: image(_imgOf(raw))));
    }
  }

  static String _decode(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  /// An HTML block (a `<details>`, a `<p align=center>` with pictures, a comment): its text and
  /// pictures, without the tags.
  Widget? htmlBlock(String raw) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _tagRe.allMatches(raw)) {
      final text = _decode(raw.substring(at, m.start));
      if (text.isNotEmpty) spans.add(TextSpan(text: text));
      final tag = m[0]!;
      if (_imgRe.hasMatch(tag)) {
        spans.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: image(_imgOf(tag))));
      } else if (_brRe.hasMatch(tag) || RegExp(r'^</(p|div|summary|li|h\d|tr|details)>$', caseSensitive: false).hasMatch(tag)) {
        spans.add(const TextSpan(text: '\n'));
      }
      at = m.end;
    }
    final rest = _decode(raw.substring(at));
    if (rest.isNotEmpty) spans.add(TextSpan(text: rest));
    // Squeeze the blank lines the tags leave behind.
    final merged = <InlineSpan>[];
    for (final sp in spans) {
      if (sp is TextSpan && merged.isNotEmpty && merged.last is TextSpan) {
        merged[merged.length - 1] = TextSpan(text: '${(merged.last as TextSpan).text}${sp.text}');
      } else {
        merged.add(sp);
      }
    }
    final cleaned = <InlineSpan>[
      for (final sp in merged)
        if (sp is TextSpan) TextSpan(text: sp.text!.replaceAll(RegExp(r'[ \t]*\n[\s]*\n+'), '\n').replaceAll(RegExp(r'^\s+|\s+$'), ''))
        else sp,
    ].where((sp) => sp is! TextSpan || sp.text!.isNotEmpty).toList();
    if (cleaned.isEmpty) return null;
    return Text.rich(TextSpan(style: base, children: cleaned));
  }

  Widget image(md.Element e) {
    final src = e.attributes['src'] ?? '';
    final alt = e.attributes['alt'] ?? '';
    final width = double.tryParse(e.attributes['width'] ?? '');
    if (src.isEmpty) return Text(alt, style: base.copyWith(color: Swatch.muted));
    Widget img = Image.network(
      serverUrl(imageSrc(src, itemUrl)),
      headers: imageHeaders(),
      width: width,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Text(alt.isEmpty ? '🖼️' : '🖼️ $alt', style: base.copyWith(color: Swatch.muted)),
    );
    img = ClipRRect(borderRadius: BorderRadius.circular(6), child: img);
    return alt.isEmpty ? img : Semantics(label: alt, image: true, child: img);
  }
}

class _TaskBox extends StatelessWidget {
  const _TaskBox(this.checked);
  final bool checked;

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: checked ? Swatch.good : Colors.white,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: checked ? Swatch.good : const Color(0xFF767676), width: 1.5),
        ),
        child: checked ? const Icon(Icons.check, size: 11, color: Colors.white) : null,
      );
}

/// The `hr`: a 2px dashed rule.
class _DashedRule extends StatelessWidget {
  const _DashedRule();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 2, child: CustomPaint(painter: _DashPainter()));
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = _rule
      ..strokeWidth = 2;
    for (var x = 0.0; x < size.width; x += 10) {
      canvas.drawLine(Offset(x, 1), Offset((x + 6).clamp(0, size.width), 1), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => false;
}
