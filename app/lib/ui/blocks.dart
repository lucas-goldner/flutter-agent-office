// BLOCKFALL, the game on the arcade cabinet (ui/cabinet.dart): falling blocks with the usual rotation
// and wall kicks, a bag of all seven pieces at a time, hold, a ghost where the piece will land, and a
// painter that draws the whole screen in fixed 800×600 units from a CabinetFrame, so the player's
// screen, the cabinet in the office and everyone watching show the same picture. Port of ui/blocks.ts.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:office_shared/cabinet.dart';

import 'screen_paint.dart';

const double blocksWidth = 800;
const double blocksHeight = 600;

const int _cols = wellCols;

/// Two rows above the top of the well, where the pieces come in.
const int blocksHidden = 2;
const int _rows = wellRows + blocksHidden;
const int _ghost = 8;

/// I, O, T, S, Z, J, L: where each piece's blocks are in its box, turned the way it comes in.
const List<List<(int, int)>> _shapes = [
  [],
  [(0, 1), (1, 1), (2, 1), (3, 1)],
  [(0, 0), (1, 0), (0, 1), (1, 1)],
  [(1, 0), (0, 1), (1, 1), (2, 1)],
  [(1, 0), (2, 0), (0, 1), (1, 1)],
  [(0, 0), (1, 0), (1, 1), (2, 1)],
  [(0, 0), (0, 1), (1, 1), (2, 1)],
  [(2, 0), (0, 1), (1, 1), (2, 1)],
];
const _box = [0, 4, 2, 3, 3, 3, 3, 3];

/// Each piece's color.
const blockColors = ['', '#4cc9f0', '#ffd166', '#b388eb', '#06d6a0', '#ef476f', '#4f86f7', '#ff8a5b'];

/// Where to try a piece that won't turn where it is, turning clockwise from each of its four ways
/// (x right, y up, as they're usually written). Turning back the other way tries them reversed.
const List<List<(int, int)>> _kicks = [
  [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)],
  [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
  [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)],
  [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
];
const List<List<(int, int)>> _iKicks = [
  [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)],
  [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)],
  [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)],
  [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)],
];

/// How long a piece sits on something before it sticks, and how many moves can put that off.
const double _lockDelay = 0.5;
const int _lockResets = 15;

/// Holding left or right: how long before it slides, then how often it steps.
const double _das = 0.16;
const double _arr = 0.045;

/// Rows a second while you hold down.
const double _softDrop = 20;

class Piece {
  Piece({required this.kind, required this.rot, required this.x, required this.y});
  int kind, rot, x, y;

  Piece copy({int? rot, int? x, int? y}) => Piece(kind: kind, rot: rot ?? this.rot, x: x ?? this.x, y: y ?? this.y);

  @override
  bool operator ==(Object other) =>
      other is Piece && other.kind == kind && other.rot == rot && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(kind, rot, x, y);

  @override
  String toString() => 'Piece(kind $kind, rot $rot, $x, $y)';
}

/// The blocks of a piece turned [rot] quarter turns clockwise, in its box.
List<(int, int)> pieceBlocks(int kind, int rot) {
  final n = _box[kind];
  return [
    for (var (x, y) in _shapes[kind])
      () {
        for (var r = 0; r < rot; r++) {
          (x, y) = (n - 1 - y, x);
        }
        return (x, y);
      }(),
  ];
}

/// Seconds per row at a level: a second at 1, quicker and quicker after.
double gravity(int level) => math.pow(0.8 - (level - 1) * 0.007, level - 1).toDouble();

class Blocks {
  Blocks({math.Random? random}) : _random = random ?? math.Random() {
    _queue.add(_draw());
    spawn();
  }

  final math.Random _random;

  /// Row by row from the top, hidden rows first: 0 empty, else the color of the piece that left it.
  final Uint8List well = Uint8List(_cols * _rows);
  late Piece piece;
  List<int> _bag = [];
  final List<int> _queue = [];
  int _held = 0;

  /// Hold only works once per piece.
  bool _swapped = false;
  PlayState state = PlayState.play;
  int score = 0;
  int lines = 0;
  int level = 1;
  int pieces = 0;

  /// Up by one whenever the picture changes.
  int version = 0;

  /// What just happened, for the sounds: cleared lines, or the piece landing.
  void Function(int cleared)? onLand;

  /// Which game this is on the high-score table: the office names it when you start playing.
  String id = '';
  double _fall = 0;
  double _lockT = 0;
  int _resets = 0;
  bool _soft = false;
  bool _left = false;
  bool _right = false;

  /// Which way it's sliding while a key is held, and how long until the next step.
  int _slide = 0;
  double _repeat = 0;

  bool get over => state == PlayState.over;

  /// Left (-1) or right (1) pressed: a step now, then sliding while it's held.
  void press(int dir) {
    if (dir < 0) {
      _left = true;
    } else {
      _right = true;
    }
    _slide = dir;
    _repeat = _das;
    if (state == PlayState.play) _shift(dir);
  }

  void release(int dir) {
    if (dir < 0) {
      _left = false;
    } else {
      _right = false;
    }
    // Still holding the other way: slide that way again.
    if (_slide == dir) {
      _slide = _left
          ? -1
          : _right
          ? 1
          : 0;
      _repeat = _das;
    }
  }

  /// Lets go of everything, when the window loses the keyboard.
  void releaseAll() {
    _left = _right = _soft = false;
    _slide = 0;
  }

  void softDrop(bool on) => _soft = on;

  /// Straight down, and it sticks.
  void hardDrop() {
    if (state != PlayState.play) return;
    var rows = 0;
    while (_fits(piece, 0, rows + 1)) {
      rows++;
    }
    piece.y += rows;
    score += rows * 2;
    _lock();
  }

  /// A quarter turn, clockwise (1) or back (-1), kicked off a wall or the stack if it has to be.
  void rotate(int dir) {
    if (state != PlayState.play) return;
    final p = piece;
    final to = (p.rot + dir + 4) % 4;
    final table = p.kind == 1 ? _iKicks : _kicks;
    final kicks = dir > 0 ? table[p.rot] : [for (final (x, y) in table[to]) (-x, -y)];
    for (final (kx, ky) in kicks) {
      final turned = p.copy(rot: to);
      if (!_fits(turned, kx, -ky)) continue;
      piece = turned.copy(x: p.x + kx, y: p.y - ky);
      _moved();
      return;
    }
  }

  /// Puts the piece by for later, and brings back the one put by before (or the next one).
  void hold() {
    if (state != PlayState.play || _swapped) return;
    final kind = piece.kind;
    spawn(_held == 0 ? null : _held);
    _held = kind;
    _swapped = true;
  }

  void pause(bool on) {
    if (over || on == (state == PlayState.paused)) return;
    state = on ? PlayState.paused : PlayState.play;
    releaseAll();
    version++;
  }

  /// Moves the game on by [dt] seconds.
  void update(double dt) {
    if (state != PlayState.play) return;
    if (_slide != 0) {
      _repeat -= dt;
      while (_repeat <= 0 && _shift(_slide)) {
        _repeat += _arr;
      }
      if (_repeat <= 0) _repeat = _arr;
    }
    final perRow = _soft ? math.min(gravity(level), 1 / _softDrop) : gravity(level);
    _fall += dt;
    while (_fall >= perRow) {
      _fall -= perRow;
      if (!_fits(piece, 0, 1)) {
        _fall = 0;
        break;
      }
      piece.y++;
      if (_soft) score++;
      version++;
    }
    if (_fits(piece, 0, 1)) {
      _lockT = 0;
    } else if ((_lockT += dt) >= _lockDelay) {
      _lock();
    }
  }

  /// The screen as it is now: the well with the piece in it and its ghost below.
  CabinetFrame frame() {
    final cells = Uint8List.fromList(well.sublist(blocksHidden * _cols));
    if (state != PlayState.over) {
      var drop = 0;
      while (_fits(piece, 0, drop + 1)) {
        drop++;
      }
      for (final (x, y) in _at(piece, 0, drop)) {
        if (y >= blocksHidden && cells[(y - blocksHidden) * _cols + x] == 0) {
          cells[(y - blocksHidden) * _cols + x] = _ghost;
        }
      }
      for (final (x, y) in _at(piece)) {
        if (y >= blocksHidden) cells[(y - blocksHidden) * _cols + x] = piece.kind;
      }
    }
    return CabinetFrame(
      cells: cells.join(),
      next: _queue.first,
      hold: _held,
      score: score,
      lines: lines,
      level: level,
      pieces: pieces,
      state: state,
    );
  }

  /// The next piece from the bag, a fresh shuffled bag of all seven when it's empty.
  int _draw() {
    if (_bag.isEmpty) {
      _bag = [1, 2, 3, 4, 5, 6, 7];
      for (var i = _bag.length - 1; i > 0; i--) {
        final j = _random.nextInt(i + 1);
        final t = _bag[i];
        _bag[i] = _bag[j];
        _bag[j] = t;
      }
    }
    return _bag.removeLast();
  }

  /// A piece comes in at the top; with no room for it, the game's over.
  void spawn([int? kind]) {
    if (kind == null || kind == 0) {
      kind = _queue.removeAt(0);
      _queue.add(_draw());
    }
    piece = Piece(kind: kind, rot: 0, x: kind == 2 ? 4 : 3, y: 1);
    _fall = _lockT = 0;
    _resets = 0;
    _swapped = false;
    if (!_fits(piece)) state = PlayState.over;
    version++;
  }

  bool _shift(int dx) {
    if (!_fits(piece, dx, 0)) return false;
    piece.x += dx;
    _moved();
    return true;
  }

  /// It moved or turned: on the stack, that buys it a little more time before it sticks.
  void _moved() {
    if (!_fits(piece, 0, 1) && _resets < _lockResets) {
      _lockT = 0;
      _resets++;
    }
    version++;
  }

  List<(int, int)> _at(Piece p, [int dx = 0, int dy = 0]) => [
    for (final (x, y) in pieceBlocks(p.kind, p.rot)) (p.x + x + dx, p.y + y + dy),
  ];

  bool _fits(Piece p, [int dx = 0, int dy = 0]) => _at(
    p,
    dx,
    dy,
  ).every((c) => c.$1 >= 0 && c.$1 < _cols && c.$2 >= 0 && c.$2 < _rows && well[c.$2 * _cols + c.$1] == 0);

  /// The piece sticks where it is, full rows go, and the next piece comes in.
  void _lock() {
    final cells = _at(piece);
    for (final (x, y) in cells) {
      well[y * _cols + x] = piece.kind;
    }
    pieces++;
    var cleared = 0;
    for (var y = _rows - 1; y >= 0; y--) {
      var full = true;
      for (var x = 0; x < _cols; x++) {
        if (well[y * _cols + x] == 0) {
          full = false;
          break;
        }
      }
      if (!full) continue;
      well.setRange(_cols, (y + 1) * _cols, Uint8List.fromList(well.sublist(0, y * _cols)));
      well.fillRange(0, _cols, 0);
      cleared++;
      y++;
    }
    if (cleared > 0) {
      score += clearPoints[cleared] * level;
      lines += cleared;
      level = levelFor(lines);
    }
    onLand?.call(cleared);
    // Stuck entirely above the top of the well: that's the end too.
    if (cells.every((c) => c.$2 < blocksHidden)) {
      state = PlayState.over;
      version++;
      return;
    }
    spawn();
  }
}

/// Everything the screen shows.
class ScreenView {
  const ScreenView({
    this.frame,
    this.player,
    this.scores = const [],
    this.mine,
    this.note,
    this.prompt,
    required this.t,
  });

  /// The game on it, or null for the high scores with nobody playing.
  final CabinetFrame? frame;

  /// Who's playing.
  final String? player;
  final List<HighScore> scores;

  /// A game to pick out on the table: your own.
  final String? mine;

  /// Said over a paused game: why it's paused.
  final String? note;

  /// What to press, under a game that's over (or over the high scores).
  final String? prompt;

  /// Seconds, for the blinking.
  final double t;
}

const double _cell = 27;
const double _x0 = (blocksWidth - _cols * _cell) / 2;
const double _y0 = 36;
const _ink = '#0b1320';
const _text = '#f1ede4';
const _dim = '#8d99ae';
const _neon = '#ff5ecb';

/// Draws the whole screen, in 800×600 units.
void paintBlocksScreen(Canvas canvas, ScreenView v) {
  final g = Pen(canvas);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, blocksWidth, blocksHeight),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, blocksHeight), [css('#1b1d3a'), css(_ink)]),
  );
  final f = v.frame;
  if (f != null) {
    _paintGame(g, f, v);
  } else {
    _paintAttract(g, v);
  }
  // Scan lines, like the tube it would have had.
  final scan = css('rgba(0, 0, 0, 0.12)');
  for (var y = 0.0; y < blocksHeight; y += 4) {
    g.rect(0, y, blocksWidth, 1.5, scan);
  }
}

void _paintGame(Pen g, CabinetFrame f, ScreenView v) {
  final c = g.canvas;
  // The well, in a glowing frame.
  g.rect(_x0, _y0, _cols * _cell, wellRows * _cell, css('#070b14'));
  final frame = Rect.fromLTWH(_x0 - 4, _y0 - 4, _cols * _cell + 8, wellRows * _cell + 8);
  c.drawRect(
    frame,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = css(_neon)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
  );
  g.strokeRect(frame.left, frame.top, frame.width, frame.height, css(_neon), 4);
  final grid = css('rgba(255, 255, 255, 0.04)');
  for (var col = 1; col < _cols; col++) {
    g.line(_x0 + col * _cell, _y0, _x0 + col * _cell, _y0 + wellRows * _cell, grid, 1);
  }
  for (var r = 1; r < wellRows; r++) {
    g.line(_x0, _y0 + r * _cell, _x0 + _cols * _cell, _y0 + r * _cell, grid, 1);
  }
  for (var i = 0; i < f.cells.length; i++) {
    final k = f.cells.codeUnitAt(i) - 48;
    if (k <= 0 || k > _ghost) continue;
    final x = _x0 + (i % _cols) * _cell;
    final y = _y0 + (i ~/ _cols) * _cell;
    if (k == _ghost) {
      g.strokeRect(x + 3, y + 3, _cell - 6, _cell - 6, css('rgba(241, 237, 228, 0.35)'), 2);
    } else {
      _block(g, x, y, _cell, blockColors[k], dull: f.state == PlayState.over);
    }
  }

  // Left: what's on hold and how it's going. Right: what's next and the table.
  const lx = _x0 / 2;
  const rx = blocksWidth - _x0 / 2;
  _label(g, 'HOLD', lx, 62);
  _preview(g, f.hold, lx, 112);
  _label(g, 'SCORE', lx, 196);
  _value(g, scoreText(f.score), lx, 228, 32);
  _label(g, 'LINES', lx, 282);
  _value(g, '${f.lines}', lx, 312, 28);
  _label(g, 'LEVEL', lx, 362);
  _value(g, '${f.level}', lx, 392, 28);
  final player = v.player;
  if (player != null) {
    final s = g.style(20, weight: FontWeight.w900, color: css('#ffd166'));
    g.text('▶ ${g.fit(player.toUpperCase(), 190, s)}', lx, 470, s);
  }
  if (v.scores.isNotEmpty) {
    final best = v.scores.first;
    g.text(
      'HI ${scoreText(math.max(best.score, f.score))}',
      lx,
      502,
      g.style(16, weight: FontWeight.w800, color: css(_dim)),
    );
  }
  _label(g, 'NEXT', rx, 62);
  _preview(g, f.next, rx, 112);
  _label(g, 'HIGH SCORES', rx, 196);
  if (v.scores.isNotEmpty) {
    _table(g, v.scores, rx - 100, 200, 228, 30, 16, v.mine);
  } else {
    _value(g, 'Be the first!', rx, 228, 18);
  }

  if (f.state == PlayState.paused) {
    _banner(g, 'PAUSED', v.note ?? 'P to carry on', '#4f86f7');
  } else if (f.state == PlayState.over) {
    _banner(g, 'GAME OVER', v.prompt ?? scoreText(f.score), '#e63946');
  }
}

/// Nobody's playing: the title, the high scores and a blinking "press E".
void _paintAttract(Pen g, ScreenView v) {
  // Each letter in a piece's color, glowing.
  final letters = cabinetGame.split('');
  final styles = [
    for (var i = 0; i < letters.length; i++)
      g.style(
        76,
        weight: FontWeight.w900,
        color: css(blockColors[(i % 7) + 1]),
        shadows: [Shadow(color: css(blockColors[(i % 7) + 1]), blurRadius: 18)],
      ),
  ];
  final widths = [for (var i = 0; i < letters.length; i++) g.measure(letters[i], styles[i])];
  var x = blocksWidth / 2 - widths.fold<double>(0, (a, b) => a + b) / 2;
  for (var i = 0; i < letters.length; i++) {
    g.text(letters[i], x + widths[i] / 2, 74, styles[i]);
    x += widths[i];
  }
  _label(g, '🏆 HIGH SCORES', blocksWidth / 2, 142);
  if (v.scores.isNotEmpty) {
    _table(g, v.scores, blocksWidth / 2 - 250, 500, 182, 35, 24, v.mine);
  } else {
    g.text(
      'No scores yet. Be the first!',
      blocksWidth / 2,
      300,
      g.style(22, weight: FontWeight.w800, color: css(_dim)),
    );
  }
  if ((v.t * 1.6).floor() % 2 == 0) {
    g.text(
      v.prompt ?? 'PRESS E TO PLAY',
      blocksWidth / 2,
      562,
      g.style(30, weight: FontWeight.w900, color: css('#ffd166')),
    );
  }
}

/// The high-score table: place, name and score, [width] wide from [x], a row every [step], in [size] px.
void _table(Pen g, List<HighScore> scores, double x, double width, double y, double step, double size, String? mine) {
  for (var i = 0; i < scores.length; i++) {
    final s = scores[i];
    final cy = y + i * step;
    if (s.game == mine)
      g.roundRect(x - 8, cy - step / 2 + 2, width + 16, step - 4, 8, css('rgba(255, 209, 102, 0.22)'));
    final score = scoreText(s.score);
    final place = size * 1.6;
    TextStyle st(String color) => g.style(size, weight: FontWeight.w900, color: css(color));
    g.text('${i + 1}', x, cy, st(i == 0 ? '#ffd166' : _dim), align: TextAlignX.left);
    final name = st(s.color.startsWith('#') ? s.color : _text);
    g.text(
      g.fit(s.name, width - place - g.measure(score, name) - size, name),
      x + place,
      cy,
      name,
      align: TextAlignX.left,
    );
    g.text(score, x + width, cy, st(_text), align: TextAlignX.right);
  }
}

/// A block: its color, lit on the top and left, shaded on the bottom and right.
void _block(Pen g, double x, double y, double size, String color, {bool dull = false}) {
  final a = dull ? 0.45 : 1.0;
  Color alpha(Color c) => c.withValues(alpha: c.a * a);
  g.rect(x + 1, y + 1, size - 2, size - 2, alpha(css(color)));
  final light = alpha(css('rgba(255, 255, 255, 0.35)'));
  g.rect(x + 1, y + 1, size - 2, 4, light);
  g.rect(x + 1, y + 1, 4, size - 2, light);
  final dark = alpha(css('rgba(0, 0, 0, 0.25)'));
  g.rect(x + 1, y + size - 5, size - 2, 4, dark);
  g.rect(x + size - 5, y + 1, 4, size - 2, dark);
}

/// A piece in a little box, centered on (cx, cy).
void _preview(Pen g, int kind, double cx, double cy) {
  g.roundRect(cx - 62, cy - 36, 124, 72, 12, css('#070b14'));
  if (kind <= 0 || kind > 7) return;
  final cells = pieceBlocks(kind, 0);
  const size = 22.0;
  final xs = cells.map((c) => c.$1), ys = cells.map((c) => c.$2);
  final ox = cx - ((xs.reduce(math.min) + xs.reduce(math.max) + 1) * size) / 2;
  final oy = cy - ((ys.reduce(math.min) + ys.reduce(math.max) + 1) * size) / 2;
  for (final (x, y) in cells) {
    _block(g, ox + x * size, oy + y * size, size, blockColors[kind]);
  }
}

/// Big words across the well, and a line under them.
void _banner(Pen g, String title, String sub, String color) {
  g.rect(_x0, _y0, _cols * _cell, wellRows * _cell, css('rgba(7, 11, 20, 0.72)'));
  g.roundRect(_x0 - 30, blocksHeight / 2 - 62, _cols * _cell + 60, 112, 16, css(color));
  const white = Color(0xFFFFFFFF);
  g.text(title, blocksWidth / 2, blocksHeight / 2 - 22, g.style(44, weight: FontWeight.w900, color: white));
  final s = g.style(18, weight: FontWeight.w800, color: white);
  g.text(g.fit(sub, _cols * _cell + 40, s), blocksWidth / 2, blocksHeight / 2 + 22, s);
}

void _label(Pen g, String text, double x, double y) =>
    g.text(text, x, y, g.style(16, weight: FontWeight.w900, color: css(_dim)));

void _value(Pen g, String text, double x, double y, double size) {
  final s = g.style(size, weight: FontWeight.w900, color: css(_text));
  g.text(g.fit(text, 200, s), x, y, s);
}
