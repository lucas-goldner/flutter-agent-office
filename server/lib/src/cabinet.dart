// The arcade cabinet's high scores, and the office following every game. Port of src/server/cabinet.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:office_shared/shared.dart' hide clearPoints;
import 'package:office_shared/shared.dart' as shared show clearPoints;
import 'package:path/path.dart' as p;

import 'secrets.dart';

final _colorRe = RegExp(r'^#[0-9a-fA-F]{6}$');

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A score on its way to the table: a [HighScore] without its `at`.
typedef ScoreEntry = ({String game, String name, String color, int score, int lines, int level});

/// Best first; of two the same, the one that got there first.
int _byScore(HighScore a, HighScore b) => b.score != a.score ? b.score - a.score : a.at - b.at;

/// The arcade's high-score table: one for the whole building, on every floor's cabinet, saved in the
/// office's .agent-office/arcade.json so it's still there after a restart.
class HighScores {
  HighScores(String dataDir, {int Function()? now}) : _file = p.join(dataDir, 'arcade.json'), _clock = now ?? _now {
    _load();
  }

  final String _file;
  final int Function() _clock;
  List<HighScore> _list = [];

  /// How often [record] was called (for tests).
  int records = 0;

  List<HighScore> top() => _list;

  /// Games' scores as they stand, saved together. Each goes on the table if it's good enough, and the
  /// same game again only ever raises its own score (nobody else's). Says whether the table changed,
  /// and which game just took first place from another one, if one did.
  ({bool changed, HighScore? first}) record(List<ScoreEntry> scores) {
    records++;
    final leader = _list.isEmpty ? null : _list.first;
    var next = _list;
    for (final s in scores) {
      final was = next.where((e) => e.game == s.game).firstOrNull;
      if (s.score <= 0 || (was != null && (was.name != s.name || s.score <= was.score))) continue;
      final entry = HighScore(
        game: s.game,
        name: s.name,
        color: s.color,
        score: s.score,
        lines: s.lines,
        level: s.level,
        at: _clock(),
      );
      final after = ([...next.where((e) => !identical(e, was)), entry]..sort(_byScore)).take(scoresKept).toList();
      if (after.any((e) => e.game == s.game)) next = after;
    }
    if (identical(next, _list)) return (changed: false, first: null);
    _list = next;
    _save();
    final first = next.first.game != leader?.game && scores.any((s) => s.game == next.first.game) ? next.first : null;
    return (changed: true, first: first);
  }

  void _load() {
    final f = File(_file);
    if (!f.existsSync()) return;
    try {
      final saved = jsonDecode(f.readAsStringSync());
      if (saved is! List) return;
      final list = <HighScore>[];
      for (final e in saved) {
        if (e is! Map<String, dynamic>) continue;
        final s = checkScore(e);
        final name = e['name'], at = e['at'], color = e['color'];
        if (s == null || name is! String || name.isEmpty || at is! num || !at.isFinite) continue;
        list.add(
          HighScore(
            game: s.game,
            name: name.length > 24 ? name.substring(0, 24) : name,
            color: color is String && _colorRe.hasMatch(color) ? color : '#4f86f7',
            score: s.score,
            lines: s.lines,
            level: s.level,
            at: at.toInt(),
          ),
        );
      }
      _list = (list..sort(_byScore)).take(scoresKept).toList();
    } catch (_) {
      // a broken file just means a fresh table
    }
  }

  void _save() {
    try {
      writePrivateFile(_file, jsonPretty([for (final s in _list) s.toJson()]));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// The fastest a player lands pieces, per second, over all their games: about as fast as anyone keeps
/// it up on these keys (a line a second, if every one went in a four-line clear). And how many more
/// they can land in a burst on top of that.
const double piecesPerSecond = 2.5;
const int pieceBurst = 10;

/// New games a player can start in a row that go on the table, and how often (ms) another one can after that.
const int gameBurst = 3;
const int gameEvery = 20000;

/// The most a piece scores on its way down: the one before it soft-dropped the whole well (a point a
/// row) and then held, and this one hard-dropped the whole well (2 a row).
const int dropPoints = 3 * (wellRows + 2);

/// The high-score table changes (arcade.json written, every floor told) at most this often, in ms.
const int recordEvery = 2000;

/// Games kept waiting for their players to come back to them, at most.
const _gamesKept = 100;

/// Players an Allowance keeps track of before it forgets the ones back to a full allowance.
const _playersKept = 256;

/// Whose game it is (an account, or a name on the shared password) and how it shows on the table.
class Player {
  const Player({required this.owner, required this.name, required this.color, this.connection});
  final String owner;
  final String name;
  final String color;

  /// The connection it's played over: a new name on it is the same player to the office.
  final String? connection;

  Player copyWith({String? owner, String? name, String? connection}) => Player(
    owner: owner ?? this.owner,
    name: name ?? this.name,
    color: color,
    connection: connection ?? this.connection,
  );
}

/// The most `lines` lines can score, cleared by `pieces` pieces landing after `before` lines: each
/// landing clears up to four at once, for their clear points times the level it's on then.
/// -infinity if that many pieces can't clear that many lines.
double mostClearPoints(int before, int lines, int pieces) {
  if (lines == 0) return 0;
  if (lines > pieces * 4) return double.negativeInfinity;
  // most[n]: the most the first n of the lines score, cleared in `landings` landings exactly.
  var most = [0.0, for (var i = 0; i < lines; i++) double.negativeInfinity];
  var best = double.negativeInfinity;
  for (var landings = 1; landings <= math.min(pieces, lines); landings++) {
    final was = most;
    most = [
      for (var n = 0; n < was.length; n++)
        [
          double.negativeInfinity,
          for (var k = 1; k <= math.min(4, n); k++) was[n - k] + shared.clearPoints[k] * levelFor(before + n - k),
        ].reduce(math.max),
    ];
    best = math.max(best, most[lines]);
  }
  return best;
}

/// Something a player can only do so often: `burst` times in a row, and then again as it comes back
/// at `perSecond`. It's kept under each thing they go by (their account or name, and their
/// connection), so a new game, a new name or a new connection doesn't start them over.
class _Allowance {
  _Allowance(this._burst, this._perSecond, this._clock);

  final double _burst;
  final double _perSecond;
  final int Function() _clock;
  final _used = <String, ({double left, int at})>{};

  /// What's left for the player going by `keys`: the least under any of them.
  double left(List<String> keys) {
    final now = _clock();
    return keys.map((k) => _leftAt(k, now)).reduce(math.min);
  }

  void take(List<String> keys, num n) {
    if (n == 0) return;
    final now = _clock();
    for (final k in keys) {
      _used[k] = (left: _leftAt(k, now) - n, at: now);
    }
    // Anyone back to a full allowance is the same as someone never seen.
    if (_used.length > _playersKept) {
      for (final k in [..._used.keys]) {
        if (_leftAt(k, now) >= _burst) _used.remove(k);
      }
    }
  }

  double _leftAt(String key, int now) {
    final u = _used[key];
    return u != null ? math.min(_burst, u.left + ((now - u.at) / 1000) * _perSecond) : _burst;
  }
}

class _Game {
  _Game(this.player, this.id, this.keys, {required this.counts});
  final Player player;
  final String id;

  /// What its player goes by, for their allowances.
  List<String> keys;

  /// From its last frame that added up.
  int score = 0;
  int lines = 0;
  int level = 1;
  int pieces = 0;

  /// The most its cleared lines could have scored between them.
  double clears = 0;

  /// Someone's at it; otherwise it waits for its player to come back to it.
  bool playing = true;

  /// One too many new games in a row: it's followed like any other, but it never goes on the table.
  final bool counts;

  /// The score last put up for the table.
  int offered = 0;
}

/// What the office made of a frame: it added up, it didn't (and its game is off the table for good),
/// or there's no game of theirs to follow.
enum Verdict { ok, voided, none }

final _random = math.Random.secure();

/// The office's side of the arcade. It starts every game, follows each one frame by frame and puts
/// the scores on the high-score table itself, so a browser can't post a score it didn't play for.
///
/// A frame adds up when nothing in it went down, its level is the one its lines make, it hasn't
/// cleared more lines than its pieces could fill or scored more than they (and the lines, cleared
/// the best way they could have been) could, and its player has landed no more pieces than
/// [piecesPerSecond] lets them, give or take a [pieceBurst], across all their games. A game with a
/// frame that doesn't add up never goes on the table again, and nor does one started after [gameBurst]
/// others in a row. However many games end at once, the table changes at most every [recordEvery] ms.
class Arcade {
  /// [changed]: the table changed. `first` is a game that just took first place, and the floor it was played on.
  Arcade(this._table, this._changed, {int Function()? now, Timer Function(Duration, void Function())? timer})
    : _clock = now ?? _now,
      _timerFn = timer ?? Timer.new {
    _pieces = _Allowance(pieceBurst.toDouble(), piecesPerSecond, _clock);
    _starts = _Allowance(gameBurst.toDouble(), 1000 / gameEvery, _clock);
  }

  final HighScores _table;
  final void Function(({HighScore score, String floor})? first) _changed;
  final int Function() _clock;
  final Timer Function(Duration, void Function()) _timerFn;
  final _games = <String, _Game>{};

  /// Scores waiting to go on the table, by game, with the floor each was played on.
  final _pending = <String, ({ScoreEntry score, String floor})>{};
  late final _Allowance _pieces;
  late final _Allowance _starts;
  Timer? _timer;
  int? _recordedAt;

  /// `player` steps up to the cabinet: back to game `resume` if it's theirs and waiting for them, else a new game. Says which.
  String start(Player player, [Object? resume]) {
    final keys = [player.owner, if (player.connection != null) 'connection:${player.connection}'];
    final was = resume is String ? _games[resume] : null;
    if (was != null && was.player.owner == player.owner && !was.playing) {
      was
        ..playing = true
        ..keys = keys;
      // Played again: the last to go when there are too many.
      _games.remove(was.id);
      _games[was.id] = was;
      return was.id;
    }
    _prune();
    final id = [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    final counts = _starts.left(keys) >= 1;
    if (counts) _starts.take(keys, 1);
    _games[id] = _Game(player, id, keys, counts: counts);
    return id;
  }

  /// Whether game `id` can go on the table: false for one started after too many others in a row (and one that's gone).
  bool counts(String? id) => id != null && (_games[id]?.counts ?? false);

  /// A frame from the player of game `id`, on `floor`. A game's last frame puts its score up for the table.
  Verdict frame(String? id, CabinetFrame f, String floor) {
    final g = id == null ? null : _games[id];
    if (g == null || !g.playing) return Verdict.none;
    final pieces = f.pieces - g.pieces;
    final lines = f.lines - g.lines;
    final adds =
        pieces >= 0 &&
        lines >= 0 &&
        f.score >= g.score &&
        pieces <= _pieces.left(g.keys) &&
        f.lines * 10 <= f.pieces * 4 &&
        f.level == levelFor(f.lines);
    final clears = adds ? g.clears + mostClearPoints(g.lines, lines, pieces) : double.negativeInfinity;
    if (!adds || f.score > dropPoints * (f.pieces + 1) + clears) {
      _games.remove(g.id);
      return Verdict.voided;
    }
    _pieces.take(g.keys, pieces);
    g
      ..score = f.score
      ..lines = f.lines
      ..level = f.level
      ..pieces = f.pieces
      ..clears = clears;
    if (f.state == PlayState.over) {
      _offer(g, floor);
      _games.remove(g.id);
    }
    return Verdict.ok;
  }

  /// The player of game `id` stepped away from it on `floor` (or left the office): it waits for them,
  /// with its score so far up for the table.
  void leave(String? id, String floor) {
    final g = id == null ? null : _games[id];
    if (g == null || !g.playing) return;
    g.playing = false;
    _offer(g, floor);
  }

  /// Puts the scores waiting on the table now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    _recordedAt = _clock();
    final waiting = [..._pending.values];
    _pending.clear();
    final r = _table.record([for (final w in waiting) w.score]);
    if (!r.changed) return;
    final first = r.first;
    _changed(first == null ? null : (score: first, floor: waiting.firstWhere((w) => w.score.game == first.game).floor));
  }

  void _offer(_Game g, String floor) {
    if (!g.counts || g.score <= g.offered) return;
    g.offered = g.score;
    _pending[g.id] = (
      score: (game: g.id, name: g.player.name, color: g.player.color, score: g.score, lines: g.lines, level: g.level),
      floor: floor,
    );
    if (_timer != null) return;
    final at = _recordedAt;
    final wait = at == null ? 0 : math.max(0, at + recordEvery - _clock());
    _timer = _timerFn(Duration(milliseconds: wait), flush);
  }

  /// Makes room for a new game, by dropping the ones left waiting longest.
  void _prune() {
    for (final g in [..._games.values]) {
      if (_games.length < _gamesKept) return;
      if (!g.playing) _games.remove(g.id);
    }
  }
}
