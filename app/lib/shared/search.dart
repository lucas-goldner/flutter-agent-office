// Searching the chat and the terminals. The server finds the lines; the browser uses the same
// rules to find a hit again in its own copy of a terminal and scroll to it.

import 'dart:math' as math;

/// Queries shorter than this match too much to be useful.
const int searchMin = 2;
const int searchMax = 200;

final RegExp _space = RegExp(r'\s+');

/// Text as a search compares it: any case, and a run of whitespace (a TUI's padding) as one space.
String searchKey(String text) => text.replaceAll(_space, ' ').trim().toLowerCase();

/// One row of a terminal buffer, as [BufferLike] hands it out.
abstract interface class BufferLineLike {
  bool get isWrapped;
  String translateToString([bool trimRight = false]);
}

/// The part of a terminal buffer a search reads (the headless one on the server, the terminal in the browser).
abstract interface class BufferLike {
  int get length;
  BufferLineLike? getLine(int y);
}

/// A buffer's lines as they were printed: rows the terminal wrapped are joined back into one line.
List<({int row, String text})> logicalLines(BufferLike buf) {
  final out = <({int row, String text})>[];
  for (var y = 0; y < buf.length; y++) {
    final line = buf.getLine(y);
    if (line == null) continue;
    final wrapsOn = buf.getLine(y + 1)?.isWrapped == true;
    // A row that wraps onto the next keeps its trailing spaces; they are part of the line.
    final text = line.translateToString(!wrapsOn);
    if (line.isWrapped && out.isNotEmpty) {
      final last = out.removeLast();
      out.add((row: last.row, text: last.text + text));
    } else {
      out.add((row: y, text: text));
    }
  }
  return out;
}

/// The logical line in `buf` holding `needle` (a searchKey) whose distance from the bottom is closest to `fromEnd`.
int? findLine(BufferLike buf, String needle, int fromEnd) {
  int? best;
  var bestDist = double.infinity;
  for (final (:row, :text) in logicalLines(buf)) {
    if (!searchKey(text).contains(needle)) continue;
    final dist = (buf.length - row - fromEnd).abs();
    if (dist < bestDist) {
      best = row;
      bestDist = dist.toDouble();
    }
  }
  return best;
}

/// `text` with its whitespace collapsed, cut down to about `width` characters around the match.
String snippet(String text, String needle, [int width = 180]) {
  final flat = text.replaceAll(_space, ' ').trim();
  if (flat.length <= width) return flat;
  final at = flat.toLowerCase().indexOf(needle);
  final start = math.max(0, math.min(at - ((width - needle.length) / 3).floor(), flat.length - width));
  final end = start + width;
  final cut = flat.substring(start, end).trim();
  return '${start > 0 ? '…' : ''}$cut${end < flat.length ? '…' : ''}';
}
