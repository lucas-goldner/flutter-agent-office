// Minesweeper for the boss's monitor (ui/arcade.dart): the rules, and a painter that draws the whole
// screen in fixed 960×540 units, so the same picture goes on the monitor and on the board you click.
// Port of ui/minesweeper.ts.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'screen_paint.dart';

const double msWidth = 960;
const double msHeight = 540;

/// 16 × 9 cells, the shape of the screen, with a mine under about one in seven.
const int msCols = 16;
const int msRows = 9;
const int msMines = 22;
const double _cell = 52;
const double _x0 = (msWidth - msCols * _cell) / 2;
const double _y0 = 62;
const _face = (x: msWidth / 2, y: 31.0, r: 23.0);

/// The classic colors for 1 to 8 mines around.
const _number = ['', '#1f6feb', '#2a9d4b', '#e63946', '#3a3a9f', '#9d2a2a', '#1a9c9c', '#2b2d42', '#7a6f65'];

enum MineState { ready, playing, won, lost }

class MineCell {
  bool mine = false;
  bool open = false;
  bool flag = false;

  /// Mines in the 8 cells around it.
  int near = 0;
}

class Minesweeper {
  Minesweeper({math.Random? random}) : _random = random ?? math.Random() {
    reset();
  }

  final math.Random _random;
  List<MineCell> cells = [];
  MineState state = MineState.ready;

  /// The mine that went off.
  int _boom = -1;

  /// Time played, counted only while someone's at the monitor (see [tick]).
  double ms = 0;

  /// The cell under a held-down click, drawn pushed in.
  int pressed = -1;

  /// The cell under the mouse.
  int hover = -1;

  void reset() {
    cells = List.generate(msCols * msRows, (_) => MineCell());
    state = MineState.ready;
    _boom = -1;
    ms = 0;
  }

  bool get over => state == MineState.won || state == MineState.lost;

  /// The cell at a point on the screen, or -1.
  int cellAt(double x, double y) {
    final c = ((x - _x0) / _cell).floor();
    final r = ((y - _y0) / _cell).floor();
    return c >= 0 && c < msCols && r >= 0 && r < msRows ? r * msCols + c : -1;
  }

  bool onFace(double x, double y) => math.sqrt(math.pow(x - _face.x, 2) + math.pow(y - _face.y, 2)) <= _face.r + 4;

  bool isOpen(int i) => i >= 0 && i < cells.length && cells[i].open;

  /// Digs up a cell. The first dig of a game is never a mine, and neither is anything around it.
  void open(int i) {
    if (over || i < 0 || i >= cells.length) return;
    final first = cells[i];
    if (first.open || first.flag) return;
    if (state == MineState.ready) _lay(i);
    if (first.mine) {
      _boom = i;
      state = MineState.lost;
      return;
    }
    // Empty cells open their neighbors too, out to the numbered edge.
    final todo = [i];
    while (todo.isNotEmpty) {
      final j = todo.removeLast();
      final cell = cells[j];
      if (cell.open || cell.flag) continue;
      cell.open = true;
      if (cell.near == 0) todo.addAll(neighbors(j));
    }
    if (cells.every((c) => c.open || c.mine)) {
      state = MineState.won;
      for (final c in cells) {
        if (c.mine) c.flag = true;
      }
    }
  }

  void flag(int i) {
    if (over || i < 0 || i >= cells.length || cells[i].open) return;
    cells[i].flag = !cells[i].flag;
  }

  /// On a number with that many flags around it: digs up everything else around it.
  void chord(int i) {
    if (over || i < 0 || i >= cells.length) return;
    final cell = cells[i];
    if (!cell.open || cell.near == 0) return;
    final around = neighbors(i);
    if (around.where((j) => cells[j].flag).length != cell.near) return;
    for (final j in around) {
      open(j);
    }
  }

  /// Counts [dt] ms of play. True when the clock's seconds changed, so it needs drawing again.
  bool tick(double dt) {
    if (state != MineState.playing) return false;
    final before = (ms / 1000).floor();
    ms += dt;
    return (ms / 1000).floor() != before;
  }

  /// Puts the mines down, anywhere but [safe] and the cells around it.
  void _lay(int safe) {
    final keep = {safe, ...neighbors(safe)};
    final spots = [
      for (var i = 0; i < cells.length; i++)
        if (!keep.contains(i)) i,
    ];
    for (var n = 0; n < msMines; n++) {
      final k = n + _random.nextInt(spots.length - n);
      final t = spots[n];
      spots[n] = spots[k];
      spots[k] = t;
      cells[spots[n]].mine = true;
    }
    for (var i = 0; i < cells.length; i++) {
      cells[i].near = neighbors(i).where((j) => cells[j].mine).length;
    }
    state = MineState.playing;
  }

  /// Draws the whole screen in 960×540 units. [idle] is the monitor with nobody at it, which puts a
  /// title over a game that hasn't started.
  void paint(Canvas canvas, {required bool idle}) {
    final g = Pen(canvas);
    g.rect(0, 0, msWidth, msHeight, css('#1b2433'));

    // The top bar: mines left, the face (a new game), and the clock.
    final left = msMines - cells.where((c) => c.flag).length;
    _readout(g, _x0, '💣 $left');
    _readout(g, msWidth - _x0 - 150, '⏱ ${math.min(999, (ms / 1000).floor())}');
    canvas.drawCircle(Offset(_face.x, _face.y), _face.r, Paint()..color = css('#ffd166'));
    final face = switch (state) {
      MineState.won => '😎',
      MineState.lost => '😵',
      _ => pressed >= 0 ? '😮' : '🙂',
    };
    g.text(face, _face.x, _face.y + 2, g.style(30));

    for (var i = 0; i < cells.length; i++) {
      _paintCell(g, i);
    }

    if (idle && state == MineState.ready) {
      g.rect(0, 150, msWidth, 230, css('rgba(11, 19, 32, 0.78)'));
      final ink = css('#f1ede4');
      g.text('MINESWEEPER', msWidth / 2, 240, g.style(92, weight: FontWeight.w900, color: ink));
      g.text(
        'Sit in the boss’s chair and press E to play',
        msWidth / 2,
        318,
        g.style(28, weight: FontWeight.w800, color: ink),
      );
    } else if (over) {
      final won = state == MineState.won;
      g.roundRect(
        msWidth / 2 - 230,
        msHeight / 2 - 44,
        460,
        88,
        18,
        css(won ? 'rgba(42, 157, 75, 0.92)' : 'rgba(230, 57, 70, 0.92)'),
      );
      const white = Color(0xFFFFFFFF);
      g.text(
        won ? 'Cleared in ${(ms / 1000).floor()}s!' : 'Boom!',
        msWidth / 2,
        msHeight / 2 - 8,
        g.style(40, weight: FontWeight.w900, color: white),
      );
      g.text(
        idle ? 'Sit down and press E to play again' : 'Click the face for a new game',
        msWidth / 2,
        msHeight / 2 + 26,
        g.style(20, weight: FontWeight.w800, color: white),
      );
    }
  }

  void _paintCell(Pen g, int i) {
    final cell = cells[i];
    final x = _x0 + (i % msCols) * _cell;
    final y = _y0 + (i ~/ msCols) * _cell;
    final cx = x + _cell / 2;
    final cy = y + _cell / 2 + 2;
    final lost = state == MineState.lost;
    final shown = cell.open || (lost && cell.mine && !cell.flag);
    if (shown || (i == pressed && !cell.flag)) {
      g.rect(x, y, _cell, _cell, css(i == _boom ? '#ff5a5f' : '#f1ede4'));
      g.strokeRect(x + 0.5, y + 0.5, _cell - 1, _cell - 1, css('#cfc6b4'), 1);
    } else {
      // A raised tile: light on the top and left, dark on the bottom and right.
      g.rect(x, y, _cell, _cell, css('#5a93b0'));
      g.rect(x, y, _cell - 4, _cell - 4, css('#c4e4f2'));
      g.rect(x + 4, y + 4, _cell - 8, _cell - 8, css(i == hover && !over ? '#a9dcf0' : '#8ecae6'));
    }
    if (cell.flag) {
      g.text('🚩', cx, cy, g.style(26));
      if (lost && !cell.mine) _cross(g, cx, cy - 2);
    } else if (shown && cell.mine) {
      g.text('💣', cx, cy, g.style(28));
    } else if (cell.open && cell.near > 0) {
      g.text('${cell.near}', cx, cy, g.style(32, weight: FontWeight.w900, color: css(_number[cell.near])));
    }
  }
}

List<int> neighbors(int i) {
  final c = i % msCols;
  final r = i ~/ msCols;
  return [
    for (var dr = -1; dr <= 1; dr++)
      for (var dc = -1; dc <= 1; dc++)
        if ((dr != 0 || dc != 0) && r + dr >= 0 && r + dr < msRows && c + dc >= 0 && c + dc < msCols)
          (r + dr) * msCols + c + dc,
  ];
}

/// A dark box of LED-red text in the top bar, 150 wide.
void _readout(Pen g, double x, String text) {
  g.roundRect(x, 10, 150, 42, 10, css('#0b1320'));
  g.text(text, x + 75, 33, g.style(28, weight: FontWeight.w900, color: css('#ff5a5f')));
}

/// A red ✕ over a flag that was wrong.
void _cross(Pen g, double x, double y) {
  final red = css('#e63946');
  g.line(x - 14, y - 14, x + 14, y + 14, red, 5, cap: StrokeCap.round);
  g.line(x + 14, y - 14, x - 14, y + 14, red, 5, cap: StrokeCap.round);
}
