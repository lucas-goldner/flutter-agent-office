// A PR's unified diff (`gh pr diff`), split into files, and the pieces the Files tab draws with it:
// each file's lines with inline review comments, the file list/tree, and which files you've
// reviewed. A port of pulldiff.ts; the parsing is pure Dart so it is tested on the VM.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../interop/open_url.dart';
import '../shared/protocol.dart';
import 'markdown.dart';
import 'modal.dart' show timeAgo;
import 'theme.dart';

enum LineKind { ctx, add, del, hunk, note }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.old, this.neu});
  final LineKind kind;
  final String text;
  final int? old;

  /// The new file's line number (`new` in the TS).
  final int? neu;

  @override
  String toString() => '${kind.name}($old,$neu):$text';
}

/// A (added), D (deleted), M (modified), R (renamed).
enum FileStatus { A, D, M, R }

const statusWord = {FileStatus.A: 'added', FileStatus.D: 'deleted', FileStatus.M: 'modified', FileStatus.R: 'renamed'};

class DiffFile {
  DiffFile(this.path);

  String path;
  String? oldPath;
  FileStatus status = FileStatus.M;
  bool binary = false;
  int additions = 0;
  int deletions = 0;
  final List<DiffLine> lines = [];

  /// Fingerprint of the file's changes, so a review mark can tell when the file changed since.
  String hash = '';
}

/// Math.imul, done in 16-bit halves so it's exact on the web too (where ints are doubles).
int _imul(int a, int b) {
  final ah = (a >> 16) & 0xffff, al = a & 0xffff;
  final bh = (b >> 16) & 0xffff, bl = b & 0xffff;
  return (al * bl + ((((ah * bl + al * bh) & 0xffff) << 16) & 0xffffffff)) & 0xffffffff;
}

/// FNV-1a, enough to notice that a file's changes are different. Same values as the old client,
/// so review marks made there still count.
String fnv(String s) {
  var x = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    x = _imul((x ^ s.codeUnitAt(i)) & 0xffffffff, 0x01000193);
  }
  return x.toRadixString(36);
}

/// `a/src/x.ts` or `"a/odd name.ts"` → `src/x.ts`
String _unprefix(String p) {
  final q = p.length >= 2 && p.startsWith('"') && p.endsWith('"')
      ? p.substring(1, p.length - 1).replaceAllMapped(RegExp(r'\\(["\\])'), (m) => m[1]!)
      : p;
  return q.replaceFirst(RegExp(r'^[ab]/'), '');
}

final _gitHeader = RegExp(r'^diff --git ("?a/.+"?) ("?b/.+"?)$');
final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

List<DiffFile> parseDiff(String text) {
  final files = <DiffFile>[];
  DiffFile? f;
  var changes = <String>[];
  var inHunk = false;
  var o = 0;
  var n = 0;
  void finish() {
    final cur = f;
    if (cur == null) return;
    // Only the changed lines count, so a rebase that just moves them doesn't undo your review.
    cur.hash = fnv('${cur.path}\n${changes.join('\n')}');
    files.add(cur);
  }

  for (final line in text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      finish();
      final m = _gitHeader.firstMatch(line);
      f = DiffFile(m != null ? _unprefix(m[2]!) : line.substring(11));
      changes = [];
      inHunk = false;
      continue;
    }
    final cur = f;
    if (cur == null) continue;
    if (line.startsWith('@@')) {
      final m = _hunkHeader.firstMatch(line);
      if (m != null) {
        o = int.parse(m[1]!);
        n = int.parse(m[2]!);
        inHunk = true;
        cur.lines.add(DiffLine(LineKind.hunk, line));
        continue;
      }
    }
    if (!inHunk) {
      if (line.startsWith('new file mode')) {
        cur.status = FileStatus.A;
      } else if (line.startsWith('deleted file mode')) {
        cur.status = FileStatus.D;
      } else if (line.startsWith('rename from ')) {
        cur.oldPath = line.substring(12);
        cur.status = FileStatus.R;
      } else if (line.startsWith('rename to ')) {
        cur.path = line.substring(10);
      } else if (line.startsWith('Binary files ') || line == 'GIT binary patch') {
        cur.binary = true;
      } else if (line.startsWith('+++ ') && line != '+++ /dev/null') {
        cur.path = _unprefix(line.substring(4));
      }
      continue;
    }
    if (line.isEmpty) continue;
    final c = line[0];
    if (c == '+') {
      cur.lines.add(DiffLine(LineKind.add, line.substring(1), neu: n++));
      cur.additions++;
      changes.add(line);
    } else if (c == '-') {
      cur.lines.add(DiffLine(LineKind.del, line.substring(1), old: o++));
      cur.deletions++;
      changes.add(line);
    } else if (c == ' ') {
      cur.lines.add(DiffLine(LineKind.ctx, line.substring(1), old: o++, neu: n++));
    } else if (c == '\\') {
      cur.lines.add(DiffLine(LineKind.note, line.length > 2 ? line.substring(2) : ''));
    }
  }
  finish();
  return files;
}

// ---- Which files you've reviewed, per PR, kept in this browser --------------------------------

const reviewedKey = 'agent-office.reviewed';
const _keepPrs = 60;

/// Where the marks are kept: localStorage in the browser, a map in tests.
class KeyValueStore {
  const KeyValueStore({required this.get, required this.set});
  final String? Function(String key) get;
  final void Function(String key, String value) set;

  /// An in-memory store.
  factory KeyValueStore.memory([Map<String, String>? backing]) {
    final m = backing ?? <String, String>{};
    return KeyValueStore(get: (k) => m[k], set: (k, v) => m[k] = v);
  }
}

enum ReviewMark { none, reviewed, stale }

/// Your review marks for one PR (keyed by its URL): reviewed, or reviewed but changed since.
class Reviewed {
  Reviewed(this.pr, this.storage, {int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    final mine = _load()[pr];
    if (mine is Map && mine['files'] is Map) {
      (mine['files'] as Map).forEach((k, v) {
        if (k is String && v is String) _files[k] = v;
      });
    }
  }

  final String pr;
  final KeyValueStore storage;
  final int Function() _now;
  final Map<String, String> _files = {};

  Map<String, dynamic> _load() {
    try {
      final v = jsonDecode(storage.get(reviewedKey) ?? '{}');
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  ReviewMark mark(DiffFile f) {
    final h = _files[f.path];
    return h == null ? ReviewMark.none : (h == f.hash ? ReviewMark.reviewed : ReviewMark.stale);
  }

  void set(DiffFile f, bool on) {
    if (on) {
      _files[f.path] = f.hash;
    } else {
      _files.remove(f.path);
    }
    final all = _load();
    if (_files.isNotEmpty) {
      all[pr] = {'at': _now(), 'files': Map.of(_files)};
    } else {
      all.remove(pr);
    }
    // Forget the PRs looked at longest ago.
    int at(Object? v) => v is Map && v['at'] is num ? (v['at'] as num).toInt() : 0;
    final keys = all.keys.toList()..sort((a, b) => at(all[b]).compareTo(at(all[a])));
    for (final k in keys.skip(_keepPrs)) {
      all.remove(k);
    }
    try {
      storage.set(reviewedKey, jsonEncode(all));
    } catch (_) {
      // storage blocked or full: the mark lasts until the window closes
    }
  }
}

// ---- Drawing a file's diff ------------------------------------------------------------------------

final _generated = RegExp(
    r'(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Cargo\.lock|Gemfile\.lock|poetry\.lock|composer\.lock|go\.sum)$|\.min\.(js|css)$|\.snap$|(^|/)dist/');

/// Lock files and build output: collapsed until asked for, like GitHub does.
bool looksGenerated(String path) => _generated.hasMatch(path);

/// Line comments on this file that are still on a line, keyed "RIGHT:12" / "LEFT:7".
Map<String, List<GhReviewComment>> threadsByLine(List<GhReviewComment> comments, String path) {
  final out = <String, List<GhReviewComment>>{};
  for (final c in comments) {
    if (c.replyTo != null || c.path != path || c.line == null) continue;
    (out['${c.side.wire}:${c.line}'] ??= []).add(c);
  }
  return out;
}

Map<int, List<GhReviewComment>> repliesOf(List<GhReviewComment> comments) {
  final out = <int, List<GhReviewComment>>{};
  for (final c in comments) {
    if (c.replyTo != null) (out[c.replyTo!] ??= []).add(c);
  }
  return out;
}

/// A line comment and its replies.
class ReviewThread extends StatelessWidget {
  const ReviewThread({super.key, required this.root, required this.replies, required this.itemUrl, this.inCard = false});

  final GhReviewComment root;
  final Map<int, List<GhReviewComment>> replies;
  final String itemUrl;

  /// In a conversation card (.gh-thread .pd-thread): no frame or margin of its own.
  final bool inCard;

  @override
  Widget build(BuildContext context) {
    final all = [root, ...?replies[root.id]];
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < all.length; i++)
          Container(
            decoration: i == 0 ? null : const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFEBE1D4), width: 1.5))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(all[i].author, style: heavy(12.5, weight: FontWeight.w900)),
                      const SizedBox(width: 8),
                      _WhenLink(all[i].createdAt, all[i].url),
                    ],
                  ),
                ),
                MarkdownView(all[i].body, itemUrl: itemUrl, padding: const EdgeInsets.fromLTRB(12, 4, 12, 10), fontSize: 13.5),
              ],
            ),
          ),
      ],
    );
    if (inCard) return col;
    return Container(
      margin: const EdgeInsets.fromLTRB(108, 6, 12, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Swatch.ink, width: 2),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 2))],
      ),
      child: col,
    );
  }
}

class _WhenLink extends StatelessWidget {
  const _WhenLink(this.iso, this.url);
  final String iso;
  final String url;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: DateTime.tryParse(iso)?.toLocal().toString().split('.').first ?? '',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: () => openUrl(url), child: Text(timeAgo(iso), style: heavy(12, color: Swatch.muted, weight: FontWeight.w700))),
        ),
      );
}

const _numBg = Color(0xFFFAF6F0);
const _numFg = Color(0xFFA39A91);

({Color bg, Color num, Color sign, Color fg}) _lineColors(LineKind k) => switch (k) {
      LineKind.add => (bg: const Color(0xFFE6F8EC), num: const Color(0xFFCDF0D8), sign: const Color(0xFF2A9D4B), fg: Swatch.ink),
      LineKind.del => (bg: const Color(0xFFFFEBEE), num: const Color(0xFFFFD3DC), sign: const Color(0xFFC3423F), fg: Swatch.ink),
      LineKind.hunk => (bg: const Color(0xFFE8F2FF), num: const Color(0xFFDBE9FB), sign: _numFg, fg: const Color(0xFF3A6EA5)),
      LineKind.note => (bg: Colors.white, num: _numBg, sign: _numFg, fg: Swatch.muted),
      LineKind.ctx => (bg: Colors.white, num: _numBg, sign: _numFg, fg: Swatch.ink),
    };

/// One row of a diff: two line numbers, then the code with its +/- sign.
class DiffRow extends StatelessWidget {
  const DiffRow(this.line, {super.key, this.flash = false});
  final DiffLine line;
  final bool flash;

  @override
  Widget build(BuildContext context) {
    final c = _lineColors(line.kind);
    final code = mono(12.5, color: c.fg, height: 1.5);
    final numStyle = mono(12.5, color: _numFg, height: 1.5);
    final sign = switch (line.kind) { LineKind.add => '+', LineKind.del => '-', LineKind.ctx => ' ', _ => '' };
    Widget n(int? v) => Container(
          width: 48,
          color: c.num,
          padding: const EdgeInsets.only(right: 8),
          alignment: Alignment.topRight,
          child: Text(v?.toString() ?? '', style: numStyle),
        );
    return Container(
      decoration: BoxDecoration(
        color: flash ? const Color(0xFFFFE8A3) : c.bg,
        border: flash ? const Border(left: BorderSide(color: Swatch.accent, width: 4)) : null,
      ),
      constraints: const BoxConstraints(minHeight: 18.75),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            n(line.old),
            n(line.neu),
            SizedBox(width: 22, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text(sign, style: code.copyWith(color: c.sign)))),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  line.text.replaceAll('\t', '    '),
                  style: line.kind == LineKind.note ? code.copyWith(fontStyle: FontStyle.italic) : code,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row that can flash yellow when a "Show in diff" lands on it.
class FlashRow extends StatefulWidget {
  const FlashRow(this.line, {super.key});
  final DiffLine line;

  @override
  State<FlashRow> createState() => FlashRowState();
}

class FlashRowState extends State<FlashRow> {
  bool _on = false;

  void flash() {
    setState(() => _on = true);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _on = false);
    });
  }

  @override
  Widget build(BuildContext context) => DiffRow(widget.line, flash: _on);
}

/// A centred grey note in the diff pane (`.pd-note`).
class DiffNote extends StatelessWidget {
  const DiffNote(this.text, {super.key, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: Text(text, style: heavy(13, color: Swatch.muted, weight: FontWeight.w700), textAlign: TextAlign.center)),
            if (action != null) ...[const SizedBox(width: 12), action!],
          ],
        ),
      );
}

/// The lines of one file's diff, with its line comments under the lines they're on. [rowKeys]
/// gets a key for each row that has comments ("RIGHT:12"), so the window can scroll to it.
class FileDiffLines extends StatelessWidget {
  const FileDiffLines({super.key, required this.file, required this.comments, required this.itemUrl, this.rowKeys});

  final DiffFile file;
  final List<GhReviewComment> comments;
  final String itemUrl;
  final Map<String, GlobalKey<FlashRowState>>? rowKeys;

  @override
  Widget build(BuildContext context) {
    final f = file;
    if (f.binary) return const DiffNote('Binary file — not shown.');
    if (f.lines.isEmpty) {
      return DiffNote(f.status == FileStatus.R ? 'Renamed without changes.' : 'No changes to show (file mode or empty file).');
    }
    final threads = threadsByLine(comments, f.path);
    final replies = repliesOf(comments);
    final out = <Widget>[];
    for (final l in f.lines) {
      final here = [
        if (l.neu != null) ...?threads['RIGHT:${l.neu}'],
        if (l.old != null && l.kind != LineKind.ctx) ...?threads['LEFT:${l.old}'],
      ];
      if (here.isEmpty) {
        out.add(DiffRow(l));
        continue;
      }
      final key = GlobalKey<FlashRowState>();
      if (l.neu != null) rowKeys?['RIGHT:${l.neu}'] = key;
      if (l.old != null && l.kind != LineKind.add) rowKeys?['LEFT:${l.old}'] = key;
      out.add(FlashRow(l, key: key));
      for (final c in here) {
        out.add(ReviewThread(root: c, replies: replies, itemUrl: itemUrl));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
  }
}

// ---- The file list as a folder tree --------------------------------------------------------------

class TreeDir {
  TreeDir(this.name, this.path, [List<TreeDir>? dirs, List<DiffFile>? files])
      : dirs = dirs ?? [],
        files = files ?? [];
  final String name;
  final String path;
  List<TreeDir> dirs;
  List<DiffFile> files;
}

/// Folders with their files, single-child folder chains squashed ("src/client/ui"), like GitHub.
TreeDir buildTree(List<DiffFile> files) {
  final root = TreeDir('', '');
  for (final f in files) {
    final parts = f.path.split('/');
    var d = root;
    for (final part in parts.sublist(0, parts.length - 1)) {
      final p = d.path.isNotEmpty ? '${d.path}/$part' : part;
      var next = d.dirs.where((x) => x.name == part && x.path == p).firstOrNull;
      if (next == null) d.dirs.add(next = TreeDir(part, p));
      d = next;
    }
    d.files.add(f);
  }
  TreeDir squash(TreeDir d) {
    d.dirs = d.dirs.map(squash).toList();
    while (d.dirs.length == 1 && d.files.isEmpty && d.path.isNotEmpty) {
      final only = d.dirs.first;
      d = TreeDir('${d.name}/${only.name}', only.path, only.dirs, only.files);
    }
    d.dirs.sort((a, b) => _localeCompare(a.name, b.name));
    d.files.sort((a, b) => _localeCompare(a.path, b.path));
    return d;
  }

  return squash(root);
}

/// Near enough to localeCompare: case-insensitive first, then by case.
int _localeCompare(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : a.compareTo(b);
}

/// Files in the order the tree shows them, so the diff pane matches the sidebar.
List<DiffFile> treeOrder(TreeDir d) => [...d.dirs.expand(treeOrder), ...d.files];
