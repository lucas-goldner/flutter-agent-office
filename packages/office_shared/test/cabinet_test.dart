// The shared half of tests/cabinet.test.ts: checking frames, levels and scores. The high-score table
// and the office following games (server/cabinet.ts) and the game itself (client/ui/blocks.ts) are
// tested with their own ports.
import 'dart:convert';

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  // A new game's frame, as Blocks().frame() makes it: its piece at the top, its ghost at the bottom.
  final cells = StringBuffer();
  for (var r = 0; r < wellRows; r++) {
    for (var c = 0; c < wellCols; c++) {
      cells.write(r == 0 && c >= 3 && c < 7 ? '1' : (r == wellRows - 1 && c >= 3 && c < 7 ? '8' : '0'));
    }
  }
  final f = CabinetFrame(
    cells: cells.toString(),
    next: 4,
    hold: 0,
    score: 0,
    lines: 0,
    level: 1,
    pieces: 0,
    state: PlayState.play,
  );

  test('frames from a browser are checked before anyone else sees them', () {
    expect(checkFrame(jsonDecode(jsonEncode(f.toJson()))), f);
    Map<String, dynamic> with_(String k, Object? v) => {...f.toJson(), k: v};
    expect(checkFrame(with_('cells', f.cells.substring(1))), isNull);
    expect(checkFrame(with_('cells', '<${f.cells.substring(1)}')), isNull);
    expect(checkFrame(with_('score', -1)), isNull);
    expect(checkFrame(with_('state', 'won')), isNull);
    expect(checkFrame('nope'), isNull);
    // JSON numbers that are whole count, as Number.isInteger takes them; others don't.
    expect(checkFrame(with_('score', 12.0))?.score, 12);
    expect(checkFrame(with_('score', 12.5)), isNull);
    expect(checkFrame(with_('next', 8)), isNull);
    expect(checkFrame(with_('level', 0)), isNull);
  });

  test('a frame is the whole well', () {
    expect(f.cells.length, wellCols * wellRows);
  });

  test('levels go up one every ten lines, to 99', () {
    expect([0, 9, 10, 25, 995, 2000].map(levelFor), [1, 1, 2, 3, 99, 99]);
  });

  test('scores on disk are checked as they are read back', () {
    expect(checkScore({'game': 'abcd1234', 'score': 100, 'lines': 1, 'level': 1}), (
      game: 'abcd1234',
      score: 100,
      lines: 1,
      level: 1,
    ));
    expect(checkScore({'game': 'short', 'score': 100, 'lines': 1, 'level': 1}), isNull);
    expect(checkScore({'game': 'abcd1234', 'score': -5, 'lines': 1, 'level': 1}), isNull);
    expect(checkScore({'game': 'abcd1234', 'score': 100, 'lines': 1}), isNull);
  });

  test('scores are written the en-US way', () {
    expect([0, 99, 12400, 1234567].map(scoreText), ['0', '99', '12,400', '1,234,567']);
  });
}
