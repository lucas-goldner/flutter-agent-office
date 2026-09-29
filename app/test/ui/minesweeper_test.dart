import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:agent_office/ui/minesweeper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the first dig is never a mine, nor anything around it, and it lays exactly the mines', () {
    for (var seed = 0; seed < 20; seed++) {
      final g = Minesweeper(random: math.Random(seed));
      const i = 5 * msCols + 7;
      g.open(i);
      expect(g.state, isNot(MineState.lost));
      expect(g.cells.where((c) => c.mine).length, msMines);
      for (final j in [i, ...neighbors(i)]) {
        expect(g.cells[j].mine, isFalse);
      }
      // No mines near: it opened out to the numbered edge.
      expect(g.cells[i].near, 0);
      expect(g.cells.where((c) => c.open).length, greaterThan(9));
    }
  });

  test('neighbors stay on the board', () {
    expect(neighbors(0).toSet(), {1, msCols, msCols + 1});
    expect(neighbors(msCols * msRows - 1).length, 3);
    expect(neighbors(msCols + 1).length, 8);
  });

  test('a flagged cell does not dig, and a mine ends the game', () {
    final g = Minesweeper(random: math.Random(1));
    g.open(0);
    final mine = g.cells.indexWhere((c) => c.mine);
    g.flag(mine);
    g.open(mine);
    expect(g.state, MineState.playing);
    g.flag(mine);
    g.open(mine);
    expect(g.state, MineState.lost);
    // Over: nothing more happens.
    g.flag(1);
    expect(g.cells[1].flag, isFalse);
  });

  test('a number with its mines flagged digs everything else around it', () {
    final g = Minesweeper(random: math.Random(3));
    g.open(0);
    final n = g.cells.indexWhere((c) => c.open && c.near > 0);
    for (final j in neighbors(n)) {
      if (g.cells[j].mine) g.flag(j);
    }
    g.chord(n);
    expect(g.state, isNot(MineState.lost));
    for (final j in neighbors(n)) {
      expect(g.cells[j].open || g.cells[j].mine, isTrue);
    }
  });

  test('opening every safe cell wins and flags the mines', () {
    final g = Minesweeper(random: math.Random(4));
    g.open(0);
    for (var i = 0; i < g.cells.length; i++) {
      if (!g.cells[i].mine) g.open(i);
    }
    expect(g.state, MineState.won);
    expect(g.cells.where((c) => c.flag).length, msMines);
  });

  test('the clock runs only while playing, and says when its seconds change', () {
    final g = Minesweeper(random: math.Random(5));
    expect(g.tick(2000), isFalse);
    g.open(0);
    expect(g.tick(500), isFalse);
    expect(g.tick(600), isTrue);
    expect(g.ms, 1100);
  });

  test('cells and the face are found where they are drawn', () {
    final g = Minesweeper();
    expect(g.cellAt(0, 0), -1);
    expect(g.cellAt(msWidth / 2, 62 + 1), 8);
    expect(g.onFace(msWidth / 2, 31), isTrue);
  });

  test('it paints without throwing', () {
    final g = Minesweeper(random: math.Random(6))..open(20);
    for (final idle in [true, false]) {
      final rec = ui.PictureRecorder();
      g.paint(ui.Canvas(rec), idle: idle);
      rec.endRecording().dispose();
    }
  });
}
