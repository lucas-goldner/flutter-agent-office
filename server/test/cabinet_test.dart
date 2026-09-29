import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/cabinet.dart';
import 'package:office_shared/shared.dart' hide clearPoints;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String game(int n) => 'game${'$n'.padLeft(8, '0')}';
ScoreEntry entry(int n, int score, [String name = 'Ada']) =>
    (game: game(n), name: name, color: '#ef476f', score: score, lines: 1, level: 1);

/// Whether the table changed, and which game took first place.
Map<String, Object?> news(({bool changed, HighScore? first}) r) => {'changed': r.changed, 'first': r.first?.game};

/// A clock the test moves, with the timers set on it.
class FakeClock {
  int now = 1000000;
  final _timers = <_FakeTimer>[];

  Timer timer(Duration d, void Function() fn) {
    final t = _FakeTimer(now + d.inMilliseconds, fn);
    _timers.add(t);
    return t;
  }

  void tick(num ms) {
    final until = now + ms.round();
    while (true) {
      final due = _timers.where((t) => t.active && t.at <= until).toList()..sort((a, b) => a.at - b.at);
      if (due.isEmpty) break;
      final t = due.first;
      now = t.at > now ? t.at : now;
      t.fire();
    }
    now = until;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this._fn);
  final int at;
  final void Function() _fn;
  bool _active = true;

  void fire() {
    _active = false;
    _fn();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  bool get active => _active;
  @override
  int get tick => 0;
}

const ada = Player(owner: 'name:Ada', name: 'Ada', color: '#ef476f');
const grace = Player(owner: 'account:grace', name: 'Grace', color: '#06d6a0');
final cells = '0' * (wellCols * wellRows);
CabinetFrame frame({int score = 0, int lines = 0, int level = 1, int pieces = 0, PlayState state = PlayState.play}) =>
    CabinetFrame(
      cells: cells,
      next: 1,
      hold: 0,
      score: score,
      lines: lines,
      level: level,
      pieces: pieces,
      state: state,
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent-office-arcade-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a high score set by one person is still on the table after a restart', () {
    final before = HighScores(dir.path);
    expect(news(before.record([entry(1, 1200)])), {'changed': true, 'first': game(1)});
    expect(news(before.record([entry(2, 400, 'Grace')])), {'changed': true, 'first': null});
    final after = HighScores(dir.path);
    expect(after.top().map((s) => [s.name, s.score]), [
      ['Ada', 1200],
      ['Grace', 400],
    ]);
  });

  test('the same game only ever goes up, and only its own player can raise it', () {
    final table = HighScores(dir.path);
    table.record([entry(1, 500)]);
    expect(table.record([entry(1, 900)]).changed, isTrue);
    expect(table.record([entry(1, 300)]).changed, isFalse);
    expect(table.record([entry(1, 5000, 'Mallory')]).changed, isFalse);
    expect(table.top().map((s) => [s.game, s.score]), [
      [game(1), 900],
    ]);
    expect(table.record([entry(2, 0)]).changed, isFalse);
  });

  test('the table keeps the best games, and a new leader is news', () {
    final table = HighScores(dir.path);
    for (var i = 1; i <= scoresKept; i++) {
      table.record([entry(i, i * 100)]);
    }
    expect(table.record([entry(50, 50)]).changed, isFalse);
    expect(news(table.record([entry(51, 150, 'Grace')])), {'changed': true, 'first': null});
    expect(table.top(), hasLength(scoresKept));
    expect(table.top().last.score, 150);
    expect(news(table.record([entry(52, 5000, 'Grace')])), {'changed': true, 'first': game(52)});
    expect(news(table.record([entry(52, 6000, 'Grace')])), {'changed': true, 'first': null});
  });

  test('several games go on the table at once, and the one that ends up in front is the news', () {
    final table = HighScores(dir.path);
    table.record([entry(1, 1000)]);
    expect(news(table.record([entry(2, 1500, 'Grace'), entry(3, 2000, 'Linus'), entry(4, 0, 'Nobody')])), {
      'changed': true,
      'first': game(3),
    });
    expect(table.top().map((s) => s.score), [2000, 1500, 1000]);
    expect(news(table.record([entry(1, 900), entry(2, 1400, 'Grace')])), {'changed': false, 'first': null});
  });

  test('a broken or tampered table file is read as far as it makes sense', () {
    Map<String, Object?> e(int n, int score) {
      final x = entry(n, score);
      return {'game': x.game, 'name': x.name, 'color': x.color, 'score': x.score, 'lines': x.lines, 'level': x.level};
    }

    File(p.join(dir.path, 'arcade.json')).writeAsStringSync(
      jsonEncode([
        {...e(1, 300), 'at': 1},
        {...e(2, 700), 'color': 'red; x', 'at': 2},
        {...e(3, 900), 'score': 'lots', 'at': 3},
        null,
        {...e(4, 100), 'name': '', 'at': 4},
        e(5, 800),
      ]),
    );
    expect(HighScores(dir.path).top().map((s) => [s.score, s.color]), [
      [700, '#4f86f7'],
      [300, '#ef476f'],
    ]);
    File(p.join(dir.path, 'arcade.json')).writeAsStringSync('{ not json');
    expect(HighScores(dir.path).top(), isEmpty);
  });

  // ---- The office following games: scores it saw played, and nothing else -------------------------

  late FakeClock clock;
  late HighScores table;
  late Arcade arcade;
  late List<({String game, String floor})?> told;
  void arcadeFor() {
    clock = FakeClock();
    table = HighScores(dir.path, now: () => clock.now);
    told = [];
    arcade = Arcade(
      table,
      (first) => told.add(first == null ? null : (game: first.score.game, floor: first.floor)),
      now: () => clock.now,
      timer: clock.timer,
    );
  }

  void tick(num ms) => clock.tick(ms);

  test('a game that ends goes on the table without anyone walking away', () {
    arcadeFor();
    final id = arcade.start(ada);
    tick(3000);
    expect(arcade.frame(id, frame(pieces: 6, score: 120), 'f1'), Verdict.ok);
    expect(arcade.frame(id, frame(pieces: 7, score: 140, state: PlayState.over), 'f1'), Verdict.ok);
    tick(1);
    expect(table.top().map((s) => [s.game, s.score]), [
      [id, 140],
    ]);
    expect(arcade.frame(id, frame(pieces: 8, score: 180), 'f1'), Verdict.none);
  });

  test('a forged score never makes the table', () {
    arcadeFor();
    final id = arcade.start(ada);
    expect(arcade.frame(id, frame(pieces: 1, score: 99999999), 'f1'), Verdict.voided);
    arcade.leave(id, 'f1');
    final nudged = arcade.start(ada);
    tick(10000);
    expect(arcade.frame(nudged, frame(pieces: 10, score: dropPoints * 11), 'f1'), Verdict.ok);
    expect(arcade.frame(nudged, frame(pieces: 10, score: dropPoints * 11 + 1), 'f1'), Verdict.voided);
    tick(10000);
    final lines = arcade.start(ada);
    expect(arcade.frame(lines, frame(pieces: 2, lines: 1, score: 200), 'f1'), Verdict.voided);
    final level = arcade.start(ada);
    expect(arcade.frame(level, frame(pieces: 2, level: 9, score: 20), 'f1'), Verdict.voided);
    final down = arcade.start(grace);
    expect(arcade.frame(down, frame(pieces: 2, score: 60), 'f1'), Verdict.ok);
    expect(arcade.frame(down, frame(pieces: 3, score: 40), 'f1'), Verdict.voided);
    const linus = Player(owner: 'name:Linus', name: 'Linus', color: '#ffd166');
    final singles = arcade.start(linus);
    for (final (pieces, lines) in [(3, 1), (6, 2), (9, 3)]) {
      expect(
        arcade.frame(
          singles,
          frame(pieces: pieces, lines: lines, score: dropPoints * (pieces + 1) + 100 * lines),
          'f1',
        ),
        Verdict.ok,
      );
    }
    expect(arcade.frame(singles, frame(pieces: 10, lines: 4, score: dropPoints * 11 + 800), 'f1'), Verdict.voided);
    tick(10000);
    final up = arcade.start(linus);
    for (final n in [1, 2]) {
      tick(4000);
      expect(
        arcade.frame(up, frame(pieces: 10 * n, lines: 4 * n, score: dropPoints * (10 * n + 1) + 800 * n), 'f1'),
        Verdict.ok,
      );
    }
    tick(1000);
    expect(
      arcade.frame(up, frame(pieces: 21, lines: 12, level: 2, score: dropPoints * 22 + 800 * 2 + 1600), 'f1'),
      Verdict.voided,
    );
    expect(arcade.frame(id, frame(pieces: 2, score: 30), 'f1'), Verdict.none);
    for (final g in [id, nudged, lines, level, down, singles, up]) {
      arcade.leave(g, 'f1');
    }
    tick(recordEvery);
    expect(table.top(), isEmpty);
  });

  test("a game id the office didn't start gets nobody anywhere", () {
    arcadeFor();
    const madeUp = 'deadbeefdeadbeef';
    expect(arcade.frame(madeUp, frame(pieces: 1, score: 40, state: PlayState.over), 'f1'), Verdict.none);
    final id = arcade.start(ada, madeUp);
    expect(id, isNot(madeUp));
    expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
    final hers = arcade.start(grace);
    tick(2000);
    expect(arcade.frame(hers, frame(pieces: 5, score: 100), 'f1'), Verdict.ok);
    arcade.leave(hers, 'f1');
    expect(arcade.start(ada, hers), isNot(hers));
    expect(arcade.start(ada.copyWith(name: 'Grace'), hers), isNot(hers), reason: 'going by her name is not being her');
    expect(arcade.start(grace, hers), hers);
    expect(arcade.frame(hers, frame(pieces: 6, score: 120), 'f1'), Verdict.ok);
    for (var i = 0; i < 30; i++) {
      final g = arcade.start(ada, '$i'.padLeft(16, 'f'));
      arcade.leave(g, 'f1');
    }
    tick(recordEvery);
    expect(table.top().map((s) => [s.name, s.score]), [
      ['Grace', 100],
    ]);
  });

  test('a game going faster than anyone plays is off the table', () {
    arcadeFor();
    final jump = arcade.start(ada);
    expect(arcade.frame(jump, frame(pieces: pieceBurst + 1, score: 40), 'f1'), Verdict.voided);
    final quick = arcade.start(ada);
    for (var i = 1; i <= 125; i++) {
      tick(i > 50 && i <= 80 ? 333 : 500);
      expect(
        arcade.frame(quick, frame(pieces: i, score: i * 20), 'f1'),
        Verdict.ok,
        reason: 'piece $i',
      );
    }
    arcade.leave(quick, 'f1');
    final fast = arcade.start(grace);
    var caught = 0;
    for (var i = 1; i <= 100 && caught == 0; i++) {
      tick(80);
      if (arcade.frame(fast, frame(pieces: i, score: i * 20), 'f1') == Verdict.voided) caught = i;
    }
    expect(caught > pieceBurst && caught < 20, isTrue, reason: 'caught at piece $caught');
    final grace2 = grace.copyWith(owner: 'account:grace2');
    final banked = arcade.start(grace2);
    tick(1000);
    expect(arcade.frame(banked, frame(pieces: 4, score: 80), 'f1'), Verdict.ok);
    arcade.leave(banked, 'f1');
    tick(60 * 60000);
    expect(arcade.start(grace2, banked), banked);
    expect(
      arcade.frame(banked, frame(pieces: 4 + (piecesPerSecond * 60).round(), score: 80 * 60), 'f1'),
      Verdict.voided,
    );
    tick(recordEvery);
    expect(table.top().map((s) => [s.game, s.score]), [
      [quick, 2500],
      [banked, 80],
    ]);
  });

  test("a burst of pieces is the player's, not each new game's", () {
    arcadeFor();
    Verdict burst(Player p) => arcade.frame(
      arcade.start(p),
      frame(pieces: pieceBurst, lines: 4, score: dropPoints * (pieceBurst + 1) + 800, state: PlayState.over),
      'f1',
    );
    expect([for (var i = 0; i < 10; i++) burst(ada)], [Verdict.ok, for (var i = 0; i < 9; i++) Verdict.voided]);
    expect(burst(grace.copyWith(connection: 'c1')), Verdict.ok);
    expect(burst(grace.copyWith(connection: 'c2')), Verdict.voided);
    expect(burst(const Player(owner: 'name:Eve', name: 'Eve', color: '#4f86f7', connection: 'c3')), Verdict.ok);
    expect(
      burst(const Player(owner: 'name:Mallory', name: 'Mallory', color: '#4f86f7', connection: 'c3')),
      Verdict.voided,
    );
    tick((pieceBurst / piecesPerSecond) * 1000);
    expect(burst(grace.copyWith(connection: 'c2')), Verdict.ok);
    tick(recordEvery);
    expect(table.top().map((s) => s.name), ['Ada', 'Grace', 'Eve', 'Grace']);
  });

  test('new games started one after another stop going on the table, until they slow down', () {
    arcadeFor();
    bool quickGame() {
      final id = arcade.start(ada);
      final counts = arcade.counts(id);
      tick(500);
      expect(arcade.frame(id, frame(pieces: 1, score: 30, state: PlayState.over), 'f1'), Verdict.ok);
      return counts;
    }

    expect(
      [for (var i = 0; i < gameBurst + 2; i++) quickGame()],
      [for (var i = 0; i < gameBurst; i++) true, false, false],
    );
    tick(gameEvery);
    expect(quickGame(), isTrue);
    final waiting = arcade.start(grace);
    for (var i = 0; i < 20; i++) {
      arcade.leave(waiting, 'f1');
      expect(arcade.start(grace, waiting), waiting);
    }
    expect(arcade.counts(waiting), isTrue);
    tick(recordEvery);
    expect(table.top(), hasLength(gameBurst + 1));
  });

  test('made-up frames at the fastest pace allowed score what flawless play at that pace could, and no more', () {
    arcadeFor();
    expect(mostClearPoints(0, 4, 1), 800);
    expect(mostClearPoints(0, 4, 4), 800);
    expect(mostClearPoints(9, 5, 2), 100 + 2 * 800);
    expect(mostClearPoints(0, 5, 1), double.negativeInfinity);
    final id = arcade.start(ada);
    var f = frame();
    var cleared = 0.0;
    void land(int pieces) {
      final lines = 4 * (pieces ~/ 10);
      cleared += mostClearPoints(f.lines, lines - f.lines, pieces - f.pieces);
      f = frame(
        pieces: pieces,
        lines: lines,
        level: levelFor(lines),
        score: dropPoints * (pieces + 1) + cleared.round(),
      );
      expect(arcade.frame(id, f, 'f1'), Verdict.ok, reason: '$pieces pieces');
    }

    land(pieceBurst);
    final byMinute = <int>[];
    for (var n = 1; n <= 10 * 60 * piecesPerSecond; n++) {
      tick(1000 / piecesPerSecond);
      land(f.pieces + 1);
      if (n % (60 * piecesPerSecond) == 0) byMinute.add(f.score);
    }
    expect(arcade.frame(id, f.copyWith(score: f.score + 1), 'f1'), Verdict.voided);
    expect(byMinute[0], lessThan(60000));
    expect(byMinute[9], lessThan(4000000));
  });

  test('a flood of scores changes the table at most every recordEvery ms, and the last one still lands', () {
    arcadeFor();
    final id = arcade.start(ada);
    tick(3000);
    expect(arcade.frame(id, frame(pieces: pieceBurst), 'f1'), Verdict.ok);
    for (var i = 1; i <= 200; i++) {
      expect(arcade.frame(id, frame(pieces: pieceBurst, score: i), 'f1'), Verdict.ok);
      arcade.leave(id, 'f1');
      expect(arcade.start(ada, id), id);
      tick(5);
    }
    expect(table.records, 1);
    expect(table.top().first.score, 1);
    tick(recordEvery);
    expect(table.records, 2);
    expect(table.top().first.score, 200);
    expect(told, hasLength(2));
    final games = [
      arcade.start(grace),
      arcade.start(ada.copyWith(owner: 'name:Linus', name: 'Linus')),
      arcade.start(ada.copyWith(owner: 'name:Ken', name: 'Ken')),
    ];
    tick(5000);
    for (var i = 0; i < games.length; i++) {
      expect(
        arcade.frame(games[i], frame(pieces: 5, score: 250 + i * 10, state: PlayState.over), 'f${i + 1}'),
        Verdict.ok,
      );
    }
    tick(1);
    expect(table.records, 3);
    expect(told.last, (game: games[2], floor: 'f3'));
    expect(table.top().map((s) => [s.name, s.score]), [
      ['Ken', 270],
      ['Linus', 260],
      ['Grace', 250],
      ['Ada', 200],
    ]);
    final more = arcade.start(ada);
    for (var i = 0; i < 1000; i++) {
      arcade.frame(more, frame(pieces: 1, score: 10), 'f1');
    }
    tick(recordEvery * 2);
    expect(table.records, 3);
  });

  test('whatever is waiting for the table is saved when the office shuts down', () {
    arcadeFor();
    final first = arcade.start(ada);
    tick(1000);
    arcade.frame(first, frame(pieces: 2, score: 40), 'f1');
    arcade.leave(first, 'f1');
    tick(1);
    final second = arcade.start(grace);
    tick(1000);
    arcade.frame(second, frame(pieces: 3, score: 60), 'f1');
    arcade.leave(second, 'f1');
    arcade.flush();
    expect(HighScores(dir.path).top().map((s) => [s.name, s.score]), [
      ['Grace', 60],
      ['Ada', 40],
    ]);
  });
}
