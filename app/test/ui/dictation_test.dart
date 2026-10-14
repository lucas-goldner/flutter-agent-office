// Dictation (#266): the transcript bookkeeping, push to talk, listening on and on with a recognizer that
// gives up (tests/dictation.test.ts), and the 🎤 on a prompt box.

import 'package:agent_office/ui/child_button.dart';
import 'package:agent_office/ui/dictate.dart';
import 'package:agent_office/ui/modal.dart' show Toasts;
import 'package:agent_office/ui/speech_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// A recognizer's results so far: (words, whether it has settled on them).
List<RecResult> results(List<(String, bool)> rs) => [for (final (t, f) in rs) (transcript: t, isFinal: f)];

/// A recognizer that does what the test tells it to.
class FakeRec extends Recognizer {
  FakeRec() {
    made.add(this);
  }
  static List<FakeRec> made = [];
  static bool failStart = false;
  final List<String> calls = [];

  @override
  void start() {
    if (failStart) throw const RecognizerError('already started');
    calls.add('start');
  }

  @override
  void stop() => calls.add('stop');

  @override
  void abort() => calls.add('abort');

  void hear(List<(String, bool)> rs) => onresult?.call(results(rs));
}

/// Listens with a fake recognizer, and writes down what comes of it.
({Listening l, FakeRec rec, List<String> log, List<int> clock}) listening({bool phone = false}) {
  FakeRec.made = [];
  final clock = [0];
  final log = <String>[];
  final l = listen(
    ListenHandlers(
      interim: (t) {
        if (t.isNotEmpty) log.add('interim: $t');
      },
      said: (t) => log.add('said: $t'),
      end: (problem) => log.add(problem != null ? 'end: $problem' : 'end'),
    ),
    make: FakeRec.new,
    lang: 'en-US',
    now: () => clock[0],
    phone: phone,
  );
  return (l: l, rec: FakeRec.made.first, log: log, clock: clock);
}

void main() {
  test('what was said goes into a field in place of the selection, spaced from the words around it', () {
    expect(spliceSpoken('', 0, 0, ' fix the login bug '), (value: 'fix the login bug', caret: 17));
    expect(spliceSpoken('Fix it', 6, 6, 'and add a test'), (value: 'Fix it and add a test', caret: 21));
    expect(spliceSpoken('Fix it ', 7, 7, 'and add a test'), (value: 'Fix it and add a test', caret: 21));
    expect(spliceSpoken('one three', 4, 4, 'two'), (value: 'one two three', caret: 8));
    expect(spliceSpoken('say hello please', 4, 9, 'goodbye'), (value: 'say goodbye please', caret: 11));
    expect(spliceSpoken('done', 4, 4, ', mostly'), (value: 'done, mostly', caret: 12), reason: 'no space before ,');
    expect(spliceSpoken('see (', 5, 5, 'this'), (value: 'see (this', caret: 9), reason: 'nor after (');
    expect(spliceSpoken('line one\n', 9, 9, 'line two'), (value: 'line one\nline two', caret: 17));
    expect(spliceSpoken('as it was', 3, 3, '  '), (value: 'as it was', caret: 3), reason: 'nothing said');
  });

  test('what was said is one line of plain text: nothing a terminal would take for a key', () {
    expect(cleanSpoken('  run the\ntests \x1b[A now\r\n'), 'run the tests [A now');
    expect(cleanSpoken('\x03\x04'), '');
  });

  test('each phrase is handed over once, when the recognizer settles on it', () {
    final t = Transcript();
    List<Object> take(List<(String, bool)> rs) {
      final r = t.take(results(rs));
      return [r.said, r.interim];
    }

    expect(take([('fix the', false)]), [<String>[], 'fix the']);
    expect(take([('fix the login', false), (' bug', false)]), [<String>[], 'fix the login bug']);
    expect(take([('Fix the login bug', true)]), [
      ['Fix the login bug'],
      '',
    ]);
    expect(take([('Fix the login bug', true), (' and add', false)]), [
      <String>[],
      'and add',
    ], reason: 'not handed over twice');
    expect(take([('Fix the login bug', true), (' and add a test', true), (' then', false)]), [
      ['and add a test'],
      'then',
    ]);
    expect(take([('Fix the login bug', true), (' and add a test', true), ('', true)]), [
      <String>[],
      '',
    ], reason: 'a phrase of nothing is skipped');
  });

  test('a hold is push to talk; a tap leaves it listening until the next press', () {
    var now = 0;
    var live = false;
    final log = <String>[];
    final talk = PushToTalk(
      live: () => live,
      start: () {
        live = true;
        log.add('start');
      },
      stop: () {
        live = false;
        log.add('stop');
      },
      now: () => now,
    );
    // Held.
    talk.press();
    talk.press(); // the key repeating
    now += holdMs + 500;
    talk.release();
    talk.release();
    expect(log, ['start', 'stop']);
    // Tapped: still listening once let go.
    talk.press();
    now += holdMs - 200;
    talk.release();
    expect(log, ['start', 'stop', 'start']);
    expect(live, isTrue);
    // The next press ends it, however long it's held, and doesn't start another.
    now += 5000;
    talk.press();
    now += 50;
    talk.release();
    expect(log, ['start', 'stop', 'start', 'stop']);
    // It ended by itself while left on (an error, a long silence): a press starts it again.
    talk.press();
    now += 50;
    talk.release();
    live = false;
    talk.press();
    expect(log, ['start', 'stop', 'start', 'stop', 'start', 'start']);
  });

  test('listening hands over the phrases as they settle, and ends once when stopped', () {
    final (:l, :rec, :log, clock: _) = listening();
    expect(
      [rec.lang, rec.continuous, rec.interimResults, rec.calls],
      [
        'en-US',
        true,
        true,
        ['start'],
      ],
    );
    rec.hear([('fix the', false)]);
    rec.hear([('fix the login bug', true)]);
    l.stop();
    l.stop();
    expect(rec.calls, ['start', 'stop']);
    // What it was in the middle of arrives after the stop, then it ends.
    rec.hear([('fix the login bug', true), (' and add a test', true)]);
    rec.onend?.call();
    expect(log, ['interim: fix the', 'said: fix the login bug', 'said: and add a test', 'end']);
  });

  test('words it never settled on before it ended still count', () {
    final (:l, :rec, :log, clock: _) = listening();
    rec.hear([('fix the login bug', true), (' and add a te', false)]);
    l.stop();
    rec.onend?.call();
    expect(log, ['said: fix the login bug', 'interim: and add a te', 'said: and add a te', 'end']);
  });

  test('aborting throws away what was not handed over yet', () {
    final (:l, :rec, :log, clock: _) = listening();
    rec.hear([('never mi', false)]);
    final onresult = rec.onresult, onend = rec.onend;
    l.abort();
    onresult?.call(results([('never mind', true)]));
    onend?.call();
    expect(rec.calls, ['start', 'abort']);
    expect(rec.onresult, isNull);
    expect(log, ['interim: never mi', 'end']);
  });

  test('a recognizer that gives up on its own is started again, until it has been quiet too long', () {
    final (l: _, :rec, :log, :clock) = listening();
    rec.hear([('first', true)]);
    clock[0] += 8000;
    rec.onerror?.call('no-speech');
    rec.onend?.call();
    expect(rec.calls, ['start', 'start'], reason: 'started again after a pause');
    // Its results count from nothing again.
    rec.hear([('second', true)]);
    expect(log, ['said: first', 'said: second']);
    clock[0] += quietMs + 1;
    rec.onend?.call();
    expect(rec.calls, ['start', 'start'], reason: 'not after a minute of nothing');
    expect(log, ['said: first', 'said: second', 'end']);
  });

  test('a recognizer that fails says why, once, and is not started again', () {
    final denied = listening();
    denied.clock[0] += 5000;
    denied.rec.onerror?.call('not-allowed');
    denied.rec.onend?.call();
    expect(denied.rec.calls, ['start']);
    expect(denied.log, hasLength(1));
    expect(denied.log.first, startsWith('end: Dictation needs the microphone'));

    // A browser with the API but no speech service behind it (Brave) fails as soon as it starts.
    final dead = listening();
    dead.rec.onerror?.call('network');
    dead.rec.onend?.call();
    expect(dead.log.first, contains("speech service didn't answer"));

    // Cut off by something else listening: it just ends.
    final cut = listening();
    cut.clock[0] += 5000;
    cut.rec.onerror?.call('aborted');
    cut.rec.onend?.call();
    expect(
      [cut.rec.calls, cut.log],
      [
        ['start'],
        ['end'],
      ],
    );

    FakeRec.failStart = true;
    try {
      final stuck = listening();
      expect(stuck.log, ["end: Dictation couldn't start: already started"]);
    } finally {
      FakeRec.failStart = false;
    }
    expect(speechProblem('aborted', 'en-US'), isNull);
    expect(speechProblem('language-not-supported', 'tlh'), contains('tlh'));
  });

  test('on a phone it listens a phrase at a time, for what it settled on only', () {
    final (l: _, :rec, :log, :clock) = listening(phone: true);
    expect([rec.continuous, rec.interimResults], [false, false]);
    rec.hear([('fix the login bug', true)]);
    clock[0] += 3000;
    rec.onend?.call();
    rec.hear([('and add a test', true)]);
    expect(rec.calls, ['start', 'start']);
    expect(log, ['said: fix the login bug', 'said: and add a test']);
  });

  test('without a recognizer, listening ends at once and says so', () {
    final log = <String?>[];
    listen(ListenHandlers(interim: (_) {}, said: (_) {}, end: log.add), make: null);
    expect(log, hasLength(1));
    expect(log.first, contains('no speech recognition'));
  });

  group('the 🎤 on a prompt box', () {
    var now = 0;
    setUp(() => debugDictateNow = () => now);
    tearDown(() {
      debugSpeech = null;
      debugDictateNow = null;
      Toasts.instance.items.value = const [];
    });

    testWidgets('none where the browser cannot listen', (tester) async {
      debugSpeech = (make: null, secure: true);
      final office = Office();
      final c = TextEditingController();
      await office.pump(tester, PromptField(controller: c, onSend: () {}));
      expect(find.byKey(const ValueKey('dictate-mic')), findsNothing);
    });

    testWidgets('hold it and talk: what was said goes in at the cursor, and letting go stops it', (tester) async {
      debugSpeech = (make: FakeRec.new, secure: true);
      FakeRec.made = [];
      final office = Office();
      final c = TextEditingController(text: 'Fix it');
      await office.pump(tester, PromptField(controller: c, onSend: () {}));
      final mic = find.byKey(const ValueKey('dictate-mic'));
      expect(mic, findsOneWidget);
      final g = await tester.startGesture(tester.getCenter(mic));
      await tester.pump();
      expect(dictating.value, isTrue);
      final rec = FakeRec.made.single;
      rec.hear([('and add a', false)]);
      await tester.pump();
      expect(find.text('🎙️ and add a'), findsOneWidget);
      rec.hear([('and add a test', true)]);
      await tester.pump();
      expect(c.text, 'Fix it and add a test');
      now += holdMs + 50;
      await g.up();
      expect(rec.calls, ['start', 'stop']);
      rec.onend?.call();
      await tester.pump();
      expect(dictating.value, isFalse);
      expect(find.byKey(const ValueKey('dictate-live')), findsNothing);
    });

    testWidgets('Ctrl+Space held in the box is push to talk too', (tester) async {
      debugSpeech = (make: FakeRec.new, secure: true);
      FakeRec.made = [];
      final office = Office();
      final c = TextEditingController();
      await office.pump(tester, PromptField(controller: c, onSend: () {}));
      await tester.showKeyboard(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(FakeRec.made, hasLength(1));
      expect(c.text, '', reason: 'the space is not typed');
      FakeRec.made.single.hear([('run the tests', true)]);
      now += holdMs + 50;
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(FakeRec.made.single.calls, ['start', 'stop']);
      expect(c.text, 'run the tests');
      FakeRec.made.single.onend?.call();
    });

    testWidgets('over plain http it says why instead', (tester) async {
      debugSpeech = (make: FakeRec.new, secure: false);
      FakeRec.made = [];
      final office = Office();
      final c = TextEditingController();
      await office.pump(tester, PromptField(controller: c, onSend: () {}));
      await tester.tap(find.byKey(const ValueKey('dictate-mic')));
      await tester.pump();
      expect(FakeRec.made, isEmpty);
      expect(Toasts.instance.items.value.single.text, startsWith('Dictation needs HTTPS'));
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
