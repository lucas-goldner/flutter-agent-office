// The bookshelf: the project's Markdown files, listed by the office (server/docs.ts) and read in a
// window in the office (ui/bookshelf.ts). Port of src/shared/docs.ts.

import 'json_util.dart';

/// One Markdown file in the project.
class DocFile {
  const DocFile({required this.path, this.title, required this.size, required this.mtime});

  factory DocFile.fromJson(Map<String, dynamic> j) => DocFile(
    path: asString(j['path']),
    title: asStringOrNull(j['title']),
    size: asInt(j['size']),
    mtime: asInt(j['mtime']),
  );

  /// From the project folder, with forward slashes: "docs/setup.md".
  final String path;

  /// Its first heading (or front matter title), when it has one near the top.
  final String? title;
  final int size;

  /// Last modified, ms since epoch.
  final int mtime;

  Map<String, dynamic> toJson() => {'path': path, 'title': ?title, 'size': size, 'mtime': mtime};
}

/// What GET /api/docs answers: every Markdown file in the floor's project, by path.
class DocList {
  const DocList({required this.files, required this.more});

  factory DocList.fromJson(Map<String, dynamic> j) =>
      DocList(files: asList(j['files'], DocFile.fromJson), more: asBool(j['more']));

  final List<DocFile> files;

  /// There were more than the office lists.
  final bool more;

  Map<String, dynamic> toJson() => {
    'files': [for (final f in files) f.toJson()],
    'more': more,
  };
}

/// What GET /api/docs/file answers.
class DocText {
  const DocText({required this.path, required this.text});

  factory DocText.fromJson(Map<String, dynamic> j) => DocText(path: asString(j['path']), text: asString(j['text']));

  final String path;
  final String text;

  Map<String, dynamic> toJson() => {'path': path, 'text': text};
}

final RegExp _docExt = RegExp(r'\.(md|markdown)$', caseSensitive: false);
final RegExp _dotPart = RegExp(r'(^|/)\.\.?(/|$)');

/// A file the bookshelf shows: Markdown, by its extension.
bool isDocPath(String p) => _docExt.hasMatch(p) && !_dotPart.hasMatch(p);

final RegExp _scheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false);
final RegExp _query = RegExp(r'\?.*$');

/// Where a link in the doc at [from] goes in the project, as a path from the project folder, with any
/// #anchor apart: "../README.md#setup" from "docs/a.md" is (path: "README.md", hash: "setup"). A link
/// starting with / is from the project folder, as on GitHub. Null for links elsewhere (another site,
/// mailto:…) or out of the project.
({String path, String hash})? resolveDocLink(String from, String href) {
  if (href.isEmpty || _scheme.hasMatch(href) || href.startsWith('//')) return null;
  final hashAt = href.indexOf('#');
  final hash = hashAt >= 0 ? href.substring(hashAt + 1) : '';
  var rel = (hashAt >= 0 ? href.substring(0, hashAt) : href).replaceFirst(_query, '');
  try {
    rel = Uri.decodeComponent(rel);
  } catch (_) {
    return null;
  }
  // Just an anchor: somewhere in this same doc.
  if (rel.isEmpty) return (path: from, hash: hash);
  final fromParts = from.split('/');
  final parts = rel.startsWith('/') ? <String>[] : fromParts.sublist(0, fromParts.length - 1);
  for (final seg in rel.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.isNotEmpty ? (path: parts.join('/'), hash: hash) : null;
}
