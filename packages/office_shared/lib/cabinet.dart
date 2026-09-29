// The arcade cabinet in the lounge: what its screen shows while someone plays, shared by the browser
// that plays (which sends it), the office (which passes it on to everyone else on the floor) and the
// browsers that watch. And its high-score table, which is the whole building's (see server/cabinet.ts).
// Port of src/shared/cabinet.ts.

import 'dart:math' as math;

import 'json_util.dart';

/// The game on the cabinet (see client/ui/blocks.ts). `GAME` in the TS.
const String cabinetGame = 'BLOCKFALL';

/// The well the blocks fall into: 10 wide, 20 deep.
const int wellCols = 10;
const int wellRows = 20;

/// How many games the high-score table keeps.
const int scoresKept = 10;
const int _scoreMax = 99999999;

/// Points for clearing 1–4 lines at once, times the level they're cleared on.
const List<int> clearPoints = [0, 100, 300, 500, 800];

/// The level a game is on with [lines] cleared: up one every ten, to 99.
int levelFor(int lines) => math.min(99, 1 + (lines / 10).floor());

enum PlayState implements WireEnum {
  play('play'),
  paused('paused'),
  over('over');

  const PlayState(this.wire);
  @override
  final String wire;

  static PlayState parse(Object? v) => parseWire(values, v, PlayState.play);
  static PlayState? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// One picture of the cabinet's screen while someone plays.
class CabinetFrame {
  const CabinetFrame({
    required this.cells,
    required this.next,
    required this.hold,
    required this.score,
    required this.lines,
    required this.level,
    required this.pieces,
    required this.state,
  });

  /// Tolerant reader, for frames the office sends. The office checks what browsers send with [checkFrame].
  factory CabinetFrame.fromJson(Map<String, dynamic> j) => CabinetFrame(
    cells: asString(j['cells']),
    next: asInt(j['next'], 1),
    hold: asInt(j['hold']),
    score: asInt(j['score']),
    lines: asInt(j['lines']),
    level: asInt(j['level'], 1),
    pieces: asInt(j['pieces']),
    state: PlayState.parse(j['state']),
  );

  /// The well row by row from the top, a character per cell: '0' empty, '1'–'7' a block's color, '8'
  /// where the falling piece will land.
  final String cells;

  /// The piece that comes next (1–7), and the one put on hold (0 for none).
  final int next;
  final int hold;
  final int score;
  final int lines;
  final int level;

  /// Pieces landed this game: one more is a thud, for anyone watching.
  final int pieces;
  final PlayState state;

  CabinetFrame copyWith({
    String? cells,
    int? next,
    int? hold,
    int? score,
    int? lines,
    int? level,
    int? pieces,
    PlayState? state,
  }) => CabinetFrame(
    cells: cells ?? this.cells,
    next: next ?? this.next,
    hold: hold ?? this.hold,
    score: score ?? this.score,
    lines: lines ?? this.lines,
    level: level ?? this.level,
    pieces: pieces ?? this.pieces,
    state: state ?? this.state,
  );

  Map<String, dynamic> toJson() => {
    'cells': cells,
    'next': next,
    'hold': hold,
    'score': score,
    'lines': lines,
    'level': level,
    'pieces': pieces,
    'state': state.wire,
  };

  @override
  bool operator ==(Object other) =>
      other is CabinetFrame &&
      other.cells == cells &&
      other.next == next &&
      other.hold == hold &&
      other.score == score &&
      other.lines == lines &&
      other.level == level &&
      other.pieces == pieces &&
      other.state == state;

  @override
  int get hashCode => Object.hash(cells, next, hold, score, lines, level, pieces, state);
}

/// A game on the high-score table.
class HighScore {
  const HighScore({
    required this.game,
    required this.name,
    required this.color,
    required this.score,
    required this.lines,
    required this.level,
    required this.at,
  });

  factory HighScore.fromJson(Map<String, dynamic> j) => HighScore(
    game: asString(j['game']),
    name: asString(j['name']),
    color: asString(j['color'], '#888888'),
    score: asInt(j['score']),
    lines: asInt(j['lines']),
    level: asInt(j['level'], 1),
    at: asInt(j['at']),
  );

  /// Which game: the office names each one as it starts (see Arcade in server/cabinet.ts), and its
  /// score only ever goes up.
  final String game;
  final String name;
  final String color;
  final int score;
  final int lines;
  final int level;
  final int at;

  Map<String, dynamic> toJson() => {
    'game': game,
    'name': name,
    'color': color,
    'score': score,
    'lines': lines,
    'level': level,
    'at': at,
  };
}

/// Who's at the cabinet, and which game they're on.
class CabinetPlayer {
  const CabinetPlayer({required this.id, required this.name, required this.game});

  factory CabinetPlayer.fromJson(Map<String, dynamic> j) =>
      CabinetPlayer(id: asString(j['id']), name: asString(j['name']), game: asString(j['game']));

  final String id;
  final String name;
  final String game;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'game': game};
}

/// Who's at the cabinet on your floor (and which game they're on), and the building's high scores.
class CabinetState {
  const CabinetState({this.player, this.scores = const []});

  factory CabinetState.fromJson(Map<String, dynamic> j) => CabinetState(
    player: j['player'] is Map ? CabinetPlayer.fromJson(asMap(j['player'])) : null,
    scores: asList(j['scores'], HighScore.fromJson),
  );

  final CabinetPlayer? player;
  final List<HighScore> scores;

  /// `player` is always sent, as null when nobody's at it.
  Map<String, dynamic> toJson() => {
    'player': player?.toJson(),
    'scores': [for (final s in scores) s.toJson()],
  };
}

/// The cabinet for someone walking onto the floor: its screen too, when a game's on.
class CabinetView extends CabinetState {
  const CabinetView({super.player, super.scores, this.frame});

  factory CabinetView.fromJson(Map<String, dynamic> j) {
    final s = CabinetState.fromJson(j);
    return CabinetView(
      player: s.player,
      scores: s.scores,
      frame: j['frame'] is Map ? CabinetFrame.fromJson(asMap(j['frame'])) : null,
    );
  }

  final CabinetFrame? frame;

  /// `frame` is always sent, as null when no game's on.
  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'frame': frame?.toJson()};
}

/// 12,400
String scoreText(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

final RegExp _cellsRe = RegExp('^[0-8]{${wellCols * wellRows}}\$');
final RegExp _gameRe = RegExp(r'^[a-z0-9]{8,32}$');

/// A whole number from JSON between [min] and [max], or null (JS's Number.isInteger takes 3.0 too).
int? _int(Object? v, int min, int max) {
  if (v is! num || !v.isFinite || v != v.truncateToDouble()) return null;
  final i = v.toInt();
  return i >= min && i <= max ? i : null;
}

/// A frame a browser sent, if it is one.
CabinetFrame? checkFrame(Object? raw) {
  if (raw is! Map) return null;
  final cells = raw['cells'] is String && _cellsRe.hasMatch(raw['cells'] as String) ? raw['cells'] as String : null;
  final next = _int(raw['next'], 1, 7);
  final hold = _int(raw['hold'], 0, 7);
  final score = _int(raw['score'], 0, _scoreMax);
  final lines = _int(raw['lines'], 0, _scoreMax);
  final level = _int(raw['level'], 1, 99);
  final pieces = _int(raw['pieces'], 0, _scoreMax);
  final state = PlayState.tryParse(raw['state']);
  if (cells == null ||
      next == null ||
      hold == null ||
      score == null ||
      lines == null ||
      level == null ||
      pieces == null ||
      state == null) {
    return null;
  }
  return CabinetFrame(
    cells: cells,
    next: next,
    hold: hold,
    score: score,
    lines: lines,
    level: level,
    pieces: pieces,
    state: state,
  );
}

/// A score read back from disk, if it is one.
({String game, int score, int lines, int level})? checkScore(Map<String, dynamic> raw) {
  final game = raw['game'] is String && _gameRe.hasMatch(raw['game'] as String) ? raw['game'] as String : null;
  final score = _int(raw['score'], 0, _scoreMax);
  final lines = _int(raw['lines'], 0, _scoreMax);
  final level = _int(raw['level'], 1, 99);
  if (game == null || score == null || lines == null || level == null) return null;
  return (game: game, score: score, lines: lines, level: level);
}
