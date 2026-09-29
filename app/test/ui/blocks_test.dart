import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:agent_office/ui/blocks.dart';
import 'package:agent_office/ui/cabinet.dart' show lostGame;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/cabinet.dart';

void main() {
  test('frames from a browser are checked before anyone else sees them', () {
    final f = Blocks().frame();
    final json = jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>;
    expect(checkFrame(json), f);
    expect(checkFrame({...json, 'cells': f.cells.substring(1)}), isNull);
    expect(checkFrame({...json, 'score': -1}), isNull);
    expect(checkFrame({...json, 'state': 'won'}), isNull);
    expect(checkFrame('nope'), isNull);
  });

  test('a new game shows its piece at the top of the well and a ghost at the bottom', () {
    final f = Blocks().frame();
    expect(f.cells.length, wellCols * wellRows);
    expect(f.state, PlayState.play);
    final rows = [for (var r = 0; r < wellRows; r++) f.cells.substring(r * wellCols, (r + 1) * wellCols)];
    expect(rows.first, matches(RegExp('[1-7]')));
    expect(rows.last, contains('8'));
  });

  test('dropping an I into a four-deep gap clears four lines', () {
    final g = Blocks();
    for (var r = blocksHidden + wellRows - 4; r < blocksHidden + wellRows; r++) {
      for (var c = 1; c < wellCols; c++) {
        g.well[r * wellCols + c] = 3;
      }
    }
    // Upright, its blocks are the third column of its box: that's column 0 of the well.
    g.piece = Piece(kind: 1, rot: 1, x: -2, y: 1);
    var landed = -1;
    g.onLand = (lines) => landed = lines;
    g.hardDrop();
    expect(landed, 4);
    expect(g.lines, 4);
    // 17 rows down at 2 points a row, and 800 for four lines at level 1.
    expect(g.score, 17 * 2 + 800);
    expect(g.pieces, 1);
    final bottom = g.frame().cells.substring((wellRows - 4) * wellCols).replaceAll('8', '0');
    expect(bottom, isNot(matches(RegExp('[1-7]'))));
  });

  test('a cleared line brings the rows above it down', () {
    final g = Blocks();
    final last = blocksHidden + wellRows - 1;
    for (var c = 0; c < wellCols - 1; c++) {
      g.well[last * wellCols + c] = 5;
    }
    g.well[(last - 1) * wellCols + 0] = 6;
    g.piece = Piece(kind: 1, rot: 1, x: wellCols - 3, y: 1);
    g.hardDrop();
    expect(g.lines, 1);
    // The block that sat on top of the full row is on the bottom now.
    expect(g.well[last * wellCols + 0], 6);
    // Three blocks of the upright I are left above it in the last column.
    expect(g.well[last * wellCols + wellCols - 1], 1);
  });

  test('a piece turned against the wall is kicked out from it', () {
    final g = Blocks();
    // A T pointing right, flat against the left wall.
    g.piece = Piece(kind: 3, rot: 1, x: -1, y: 8);
    g.rotate(1);
    expect(g.piece, Piece(kind: 3, rot: 2, x: 0, y: 8));
  });

  test('turning four times comes back round', () {
    for (var kind = 1; kind <= 7; kind++) {
      expect(pieceBlocks(kind, 4).toSet(), pieceBlocks(kind, 0).toSet());
    }
  });

  test('a paused game stands still, and a piece with no room to come in ends it', () {
    final g = Blocks();
    final y = g.piece.y;
    g.pause(true);
    g.update(5);
    expect(g.piece.y, y);
    g.pause(false);
    g.update(1.01);
    expect(g.piece.y, y + 1);
    g.well.fillRange(0, (blocksHidden + 2) * wellCols, 5);
    g.spawn();
    expect(g.state, PlayState.over);
  });

  test('hold puts the piece by once per piece, and brings it back next time', () {
    final g = Blocks(random: math.Random(2));
    final first = g.piece.kind;
    final next = g.frame().next;
    g.hold();
    expect(g.frame().hold, first);
    expect(g.piece.kind, next);
    g.hold();
    expect(g.piece.kind, next, reason: 'only once per piece');
    g.hardDrop();
    g.hold();
    expect(g.piece.kind, first);
  });

  test('every bag deals all seven pieces', () {
    final g = Blocks(random: math.Random(9));
    final seen = <int>[];
    for (var i = 0; i < 7; i++) {
      seen.add(g.piece.kind);
      g.well.fillRange(0, g.well.length, 0);
      g.hold();
      g.hold();
      g.spawn();
    }
    expect(seen.length, 7);
  });

  test('back at a game the office lost, the browser starts a fresh one', () {
    expect(lostGame('abc12345', 'abc12345'), isFalse);
    expect(lostGame('abc12345', 'zzz99999'), isTrue);
    expect(lostGame('', 'zzz99999'), isFalse);
  });

  test('the screen paints for a game, a paused one, an ended one and the high scores', () {
    final g = Blocks();
    final scores = [
      const HighScore(game: 'aaaaaaaa', name: 'Ada', color: '#ef476f', score: 12400, lines: 12, level: 2, at: 0),
    ];
    for (final v in [
      ScreenView(frame: g.frame(), player: 'Ada', scores: scores, mine: 'aaaaaaaa', t: 0),
      ScreenView(frame: g.frame().copyWith(state: PlayState.paused), t: 0),
      ScreenView(frame: g.frame().copyWith(state: PlayState.over), t: 0),
      ScreenView(scores: scores, t: 0),
      const ScreenView(t: 1),
    ]) {
      final rec = ui.PictureRecorder();
      paintBlocksScreen(ui.Canvas(rec), v);
      rec.endRecording().dispose();
    }
  });
}
