// The 🔎 window's marks and words (see search.dart), apart so they are tested on the VM.

import '../shared/protocol.dart';

/// `text` with its whitespace collapsed, cut into pieces; the ones that match `needle` (a
/// searchKey) are marked.
List<({String text, bool mark})> highlight(String text, String needle) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  final lower = flat.toLowerCase();
  // Lowercasing can change a string's length (rare scripts); then just show it plain.
  if (lower.length != flat.length || needle.isEmpty) return [(text: flat, mark: false)];
  final out = <({String text, bool mark})>[];
  var from = 0;
  for (var at = lower.indexOf(needle); at >= 0; at = lower.indexOf(needle, from)) {
    if (at > from) out.add((text: flat.substring(from, at), mark: false));
    out.add((text: flat.substring(at, at + needle.length), mark: true));
    from = at + needle.length;
  }
  if (from < flat.length) out.add((text: flat.substring(from), mark: false));
  return out;
}

/// Terminal hits by worker, in the order they came, leaving out workers sent home since.
Map<String, List<TerminalHit>> hitsByWorker(SearchResults r, bool Function(String workerId) stillHere) {
  final by = <String, List<TerminalHit>>{};
  for (final hit in r.terminals) {
    if (!stillHere(hit.workerId)) continue;
    (by[hit.workerId] ??= []).add(hit);
  }
  return by;
}

const kSearchIntro = "Finds words in the office chat and in every worker's terminal, including what they showed before the office restarted.";

/// The line over the results.
String searchStatus(SearchResults r, int count) => count == 0
    ? 'Nothing in the chat or any terminal matches “${r.q.trim()}”.'
    : '$count ${count == 1 ? 'line' : 'lines'}, newest first${r.more ? ' (only the newest are shown; add words to narrow it down)' : ''}.';
