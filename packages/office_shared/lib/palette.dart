// The command palette's matching (Ctrl+K, ⌘K on a Mac): which of the office's workers, issues, pull
// requests, boards, teammates and actions a few typed letters mean, best first. Pure, so the ranking
// is tested without a page. Ported from src/shared/palette.ts.

import 'dart:math' as math;

/// Something the palette can find: shown as [title] over [detail]; [keywords] are found but not shown.
abstract interface class PaletteItem {
  String get title;
  String? get detail;
  List<String?> get keywords;
}

/// A [PaletteItem] that is just its texts.
class PaletteEntry implements PaletteItem {
  const PaletteEntry({required this.title, this.detail, this.keywords = const []});

  @override
  final String title;
  @override
  final String? detail;
  @override
  final List<String?> keywords;
}

/// How well some text matches a query: higher is better; [hits] are the matched characters' indices in it.
typedef TextMatch = ({double score, List<int> hits});

/// Which text of an item matched: the title, the detail, or one of the keywords.
enum PaletteField { title, detail, keyword }

class PaletteMatch<T extends PaletteItem> {
  const PaletteMatch({required this.item, required this.score, required this.field, required this.hits});

  final T item;
  final double score;

  /// Which text matched: the title, the detail, or one of the keywords.
  final PaletteField field;

  /// The matched characters' indices in that text.
  final List<int> hits;
}

/// The most the palette lists at once: past that, typing more narrows it down.
const int paletteMax = 50;

/// What each kind of match is worth: the whole text, its start, the start of a word, anywhere in it,
/// a scattered subsequence.
const double _exact = 1000;
const double _prefix = 900;
const double _wordStartScore = 800;
const double _inside = 600;
const double _words = 500;
const double _scattered = 300;

/// A title counts for most; a match in the detail line or a hidden keyword a little less.
const Map<PaletteField, double> _weight = {PaletteField.title: 1, PaletteField.detail: 0.9, PaletteField.keyword: 0.85};

/// Lowercased one character at a time, so indices still line up with the original text.
String _fold(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    final c = String.fromCharCode(r);
    final l = c.toLowerCase();
    out.write(l.length == c.length ? l : c);
  }
  return out.toString();
}

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _ws = RegExp(r'\s+');

/// Whether index [i] of [text] starts a word: the first character, or one after a space or punctuation.
bool _wordStart(String text, int i) => i == 0 || !_letterOrDigit.hasMatch(text[i - 1]);

List<int> _range(int from, int n) => [for (var k = 0; k < n; k++) from + k];

/// Where [word] is in [text] (both folded), preferring the start of a word, or -1.
int _findWord(String text, String word, [int from = 0]) {
  var first = -1;
  for (var at = text.indexOf(word, from); at >= 0; at = text.indexOf(word, at + 1)) {
    if (_wordStart(text, at)) return at;
    if (first < 0) first = at;
  }
  return first;
}

bool _subsequenceFrom(String t, String letters, int from) {
  for (var k = 0; k < letters.length; k++) {
    final i = t.indexOf(letters[k], from);
    if (i < 0) return false;
    from = i + 1;
  }
  return true;
}

/// How well [query] matches [text], or null when it doesn't: the whole text beats its start, which
/// beats the start of a word inside it, which beats the letters anywhere in it, then every typed
/// word somewhere in it, and last the letters in order but scattered (fewer, closer gaps and
/// letters at word starts score higher). A shorter text wins a tie. An empty query matches all.
TextMatch? matchText(String query, String text) {
  final q = _fold(query.replaceAll(_ws, ' ').trim());
  if (q.isEmpty) return (score: 0, hits: const []);
  final t = _fold(text);
  // A little for being short: "Login" over "Login page" when both start with it.
  final short = 50 / (10 + t.length);
  if (t.trim() == q) return (score: _exact + short, hits: _range(t.indexOf(q), q.length));
  final at = _findWord(t, q);
  if (at >= 0) {
    return (
      score: (at == 0 ? _prefix : (_wordStart(t, at) ? _wordStartScore : _inside)) + short,
      hits: _range(at, q.length),
    );
  }

  // Several words ("login fix"): each one somewhere, in any order.
  final words = q.split(' ');
  if (words.length > 1) {
    var hits = <int>[];
    var starts = 0;
    for (final w in words) {
      final i = _findWord(t, w);
      if (i < 0) {
        hits = [];
        break;
      }
      if (_wordStart(t, i)) starts++;
      hits.addAll(_range(i, w.length));
    }
    if (hits.isNotEmpty) {
      return (score: _words + (50 * starts) / words.length + short, hits: (hits.toSet().toList()..sort()));
    }
  }

  // The letters in order, anywhere: each one where it starts a word if it can, else the next one along.
  final letters = q.replaceAll(' ', '');
  final hits = <int>[];
  var from = 0;
  for (var k = 0; k < letters.length; k++) {
    final c = letters[k];
    var i = t.indexOf(c, from);
    if (i < 0) return null;
    // A later word starting with it beats this one, unless it carries straight on from the last letter.
    if (!_wordStart(t, i) && (hits.isEmpty || hits.last != i - 1)) {
      for (var j = t.indexOf(c, i + 1); j >= 0; j = t.indexOf(c, j + 1)) {
        if (_wordStart(t, j)) {
          // Only if the rest still fits after it.
          if (_subsequenceFrom(t, letters.substring(hits.length + 1), j + 1)) i = j;
          break;
        }
      }
    }
    hits.add(i);
    from = i + 1;
  }
  var score = _scattered;
  for (var k = 0; k < hits.length; k++) {
    if (_wordStart(t, hits[k])) score += 12;
    if (k > 0) score -= hits[k] - hits[k - 1] == 1 ? -6 : math.min(8, hits[k] - hits[k - 1] - 1);
  }
  // Never as good as the letters together.
  return (score: math.max(1.0, math.min(_inside - 1, score - hits[0] * 0.5 + short)), hits: hits);
}

/// How well [query] matches an item: its best text, weighted, or null when none of them match.
PaletteMatch<T>? matchItem<T extends PaletteItem>(String query, T item) {
  PaletteMatch<T>? best;
  void consider(String? text, PaletteField field) {
    if (text == null || text.isEmpty) return;
    final m = matchText(query, text);
    if (m == null) return;
    final score = m.score * _weight[field]!;
    if (best == null || score > best!.score) best = PaletteMatch(item: item, score: score, field: field, hits: m.hits);
  }

  consider(item.title, PaletteField.title);
  consider(item.detail, PaletteField.detail);
  for (final k in item.keywords) {
    consider(k, PaletteField.keyword);
  }
  return best;
}

/// The items [query] matches, best first (ties keep the order they came in), at most [limit] of them.
List<PaletteMatch<T>> rankItems<T extends PaletteItem>(String query, List<T> items, [int limit = paletteMax]) {
  final found = <({PaletteMatch<T> m, int i})>[];
  for (var i = 0; i < items.length; i++) {
    final m = matchItem(query, items[i]);
    if (m != null) found.add((m: m, i: i));
  }
  found.sort((a, b) {
    final d = b.m.score.compareTo(a.m.score);
    return d != 0 ? d : a.i.compareTo(b.i);
  });
  return [for (final f in found.take(limit)) f.m];
}

/// The parts of a keydown the palette's shortcut depends on (TS PaletteKey).
typedef PaletteKeyPress = ({String key, String code, bool ctrlKey, bool altKey, bool shiftKey, bool metaKey});

final RegExp _printableAscii = RegExp(r'^[ -~]$');

/// Whether a key press is the palette's shortcut: ⌘K on a Mac, Ctrl+K elsewhere, with no other
/// modifier. By the key's place too, for keyboards where K is another letter (Cyrillic, Greek).
bool isPaletteKey(PaletteKeyPress e, bool mac) {
  if (e.altKey || e.shiftKey || (mac ? !e.metaKey || e.ctrlKey : !e.ctrlKey || e.metaKey)) return false;
  return e.key.toLowerCase() == 'k' || (e.code == 'KeyK' && !_printableAscii.hasMatch(e.key));
}
