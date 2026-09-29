// What the bookshelf works out (ui/bookshelf.ts): which docs pass the filter and how well, the order
// they stand on the shelf, and the little labels. No widgets, so it's tested on its own.

import 'dart:math' as math;

import 'package:office_shared/docs.dart';

/// A doc that passes the filter: how well, and which letters of its title and path matched.
class DocHit {
  DocHit(this.doc);
  final DocFile doc;
  double score = 0;
  final Set<int> title = {};
  final Set<int> path = {};
}

String docName(String p) => p.substring(p.lastIndexOf('/') + 1);

/// Where the letters of [q] (lower case) turn up in [text], in order: all together if they can be,
/// else each as early as it can.
List<int>? findLetters(String q, String text) {
  final lower = text.toLowerCase();
  final at = lower.indexOf(q);
  if (at >= 0) return [for (var i = 0; i < q.length; i++) at + i];
  final out = <int>[];
  for (var j = 0; j < lower.length && out.length < q.length; j++) {
    if (lower[j] == q[out.length]) out.add(j);
  }
  return out.length == q.length ? out : null;
}

final RegExp _sep = RegExp(r'[\s/_.-]');
final RegExp _lowerRe = RegExp('[a-z]');
final RegExp _upperRe = RegExp('[A-Z]');

/// How good a find is: together beats scattered, and the start of a word beats the middle of one.
double rateFind(List<int> at, String text) {
  var score = 0.0;
  for (var k = 0; k < at.length; k++) {
    final p = at[k];
    final prev = p > 0 ? text[p - 1] : '';
    if (p == 0 || _sep.hasMatch(prev) || (_lowerRe.hasMatch(prev) && _upperRe.hasMatch(text[p]))) score += 8;
    if (k > 0) score += at[k - 1] == p - 1 ? 5 : -math.min(6, p - at[k - 1] - 1) * 0.5;
  }
  return score - at[0] * 0.05;
}

/// The project's own docs first (its README before the rest), then each folder's, in path order.
List<DocFile> shelfOrder(List<DocFile> files) {
  int rank(String p) => p.contains('/')
      ? 2
      : RegExp(r'^readme\.', caseSensitive: false).hasMatch(p)
      ? 0
      : 1;
  return [...files]..sort((a, b) {
    final r = rank(a.path) - rank(b.path);
    return r != 0 ? r : a.path.compareTo(b.path);
  });
}

/// The docs that match every word of [query], best first; all of them, in shelf order, for none.
List<DocHit> filterDocs(List<DocFile> files, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return [for (final d in shelfOrder(files)) DocHit(d)];
  final hits = <DocHit>[];
  for (final doc in files) {
    final name = docName(doc.path);
    final dir = doc.path.length - name.length;
    final hit = DocHit(doc);
    var all = true;
    for (final w in words) {
      // The file's name counts most, then its title, then anywhere in its path.
      final inName = findLetters(w, name);
      final t = doc.title;
      final inTitle = t != null ? findLetters(w, t) : null;
      final inPath = inName == null ? findLetters(w, doc.path) : null;
      final options = <(double, void Function())>[
        if (inName != null) (rateFind(inName, name) + 20, () => hit.path.addAll(inName.map((i) => dir + i))),
        if (inTitle != null) (rateFind(inTitle, t!) + 10, () => hit.title.addAll(inTitle)),
        if (inPath != null) (rateFind(inPath, doc.path), () => hit.path.addAll(inPath)),
      ];
      if (options.isEmpty) {
        all = false;
        break;
      }
      final best = options.reduce((a, b) => b.$1 > a.$1 ? b : a);
      hit.score += best.$1;
      best.$2();
    }
    if (all) hits.add(hit);
  }
  return hits..sort((a, b) {
    final s = b.score.compareTo(a.score);
    if (s != 0) return s;
    final l = a.doc.path.length - b.doc.path.length;
    return l != 0 ? l : a.doc.path.compareTo(b.doc.path);
  });
}

/// A file's size, as people say it.
String docSize(int bytes) => bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';

/// About how long it takes to read [text].
String readTime(String text) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  return '${math.max(1, (words / 220).round())} min read';
}

/// The project on GitHub, from the floor's origin remote, when that's where it is.
String? githubUrl(String? remote) {
  final m = RegExp(r'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$').firstMatch(remote ?? '');
  return m == null ? null : 'https://github.com/${m[1]}';
}
