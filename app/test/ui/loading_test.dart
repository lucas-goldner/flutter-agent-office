import 'dart:async';

import 'package:agent_office/ui/loading.dart';
import 'package:agent_office/world/models.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_scene/scene.dart' show Node;
import 'package:flutter_test/flutter_test.dart';

// When the loading screen comes down (ui/loading.dart): once everything it waits on has settled, or at
// its cap, whichever is first, and only ever once. A port of upstream's tests/loading.test.ts.

final int capMs = loadingCap.inMilliseconds;

({List<GateWhy> calls, LoadingGate g}) gate() {
  final calls = <GateWhy>[];
  return (calls: calls, g: LoadingGate(calls.add));
}

void main() {
  test('comes down once everything it waits on is in, and the cap after that does nothing', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      final frame = Completer<void>(), dog = Completer<void>();
      g.until([frame.future, dog.future]);
      frame.complete();
      t.flushMicrotasks();
      expect(calls, isEmpty, reason: 'still waiting on the dog');
      t.elapse(Duration(milliseconds: capMs ~/ 2));
      dog.complete();
      t.flushMicrotasks();
      expect(calls, [GateWhy.ready]);
      t.elapse(loadingCap);
      expect(calls, [GateWhy.ready]);
    });
  });

  test('a step that fails counts as done, and its failure goes no further', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      final dog = Completer<void>();
      g.until([Future.value(), dog.future]);
      dog.completeError(StateError("the dog's model didn't load"));
      t.flushMicrotasks();
      expect(calls, [GateWhy.ready]);
    });
  });

  test('a step that never settles is given up on at the cap, once', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      g.until([Future.value(), Completer<void>().future]);
      t.flushMicrotasks();
      t.elapse(Duration(milliseconds: capMs - 1));
      expect(calls, isEmpty);
      t.elapse(const Duration(milliseconds: 1));
      expect(calls, [GateWhy.cap]);
      t.elapse(loadingCap);
      expect(calls, [GateWhy.cap]);
    });
  });

  test('never told what to wait for (the page broke on the way), it still comes down at the cap', () {
    fakeAsync((t) {
      final (:calls, g: _) = gate();
      t.elapse(Duration(milliseconds: capMs - 1));
      expect(calls, isEmpty);
      t.elapse(const Duration(milliseconds: 1));
      expect(calls, [GateWhy.cap]);
    });
  });

  test('while something is still going (a slow download coming in), the cap starts over from the last of it', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      g.until([Future.value(), Completer<void>().future]);
      t.flushMicrotasks();
      for (var i = 0; i < 6; i++) {
        t.elapse(Duration(milliseconds: capMs ~/ 2));
        g.stillGoing();
      }
      expect(calls, isEmpty);
      t.elapse(Duration(milliseconds: capMs - 1));
      expect(calls, isEmpty, reason: 'the cap counts from the last sign of life');
      t.elapse(const Duration(milliseconds: 1));
      expect(calls, [GateWhy.cap]);
    });
  });

  for (final how in GateWhy.values) {
    test('a sign of life after it came down (${how.name}) does nothing: no second release, no new timer', () {
      fakeAsync((t) {
        final (:calls, :g) = gate();
        if (how == GateWhy.ready) {
          g.until([]);
        } else {
          t.elapse(loadingCap);
        }
        t.flushMicrotasks();
        g.stillGoing();
        expect(t.pendingTimers, isEmpty);
        t.elapse(loadingCap);
        expect(calls, [how]);
      });
    });
  }

  test('steps given after it came down, or settling after, change nothing', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      final slow = Completer<void>();
      g.until([slow.future]);
      t.elapse(loadingCap);
      slow.complete();
      g.until([Future.value()]);
      t.flushMicrotasks();
      expect(calls, [GateWhy.cap]);
    });
  });

  test('with nothing to wait for it comes down straight away', () {
    fakeAsync((t) {
      final (:calls, :g) = gate();
      g.until([]);
      t.flushMicrotasks();
      expect(calls, [GateWhy.ready]);
    });
  });

  group('the screen', () {
    test('fills with the model files, says it is unpacking, then each step in turn, and comes down', () {
      fakeAsync((t) {
        final files = <Completer<Node>>[];
        final models = Models(
          loader: (_) {
            final c = Completer<Node>();
            files.add(c);
            return c.future;
          },
        );
        final l = Loading(models.onProgress);
        expect(l.view.value.say, 'Loading the office');
        unawaited(models.preload());
        expect(files, hasLength(4));
        t.flushMicrotasks();
        expect(l.view.value.say, 'Unpacking the office');
        expect(l.view.value.fill, 0);
        for (final f in files) {
          f.complete(Node());
        }
        t.flushMicrotasks();
        expect(l.view.value.fill, closeTo(4 / 5, 1e-9), reason: 'four files in, the first frame still to come');
        final door = Completer<void>();
        l.until([(say: 'Knocking on the door', done: door.future)]);
        expect(l.view.value.say, 'Loading the office');
        l.drew();
        t.flushMicrotasks();
        expect(l.view.value.say, 'Knocking on the door');
        final before = l.view.value.fill;
        door.complete();
        t.flushMicrotasks();
        expect(l.view.value.gone, isTrue);
        expect(l.view.value.fill, greaterThanOrEqualTo(before));
        expect(l.view.value.fill, 1);
      });
    });

    test('a file that fails still counts as done', () {
      fakeAsync((t) {
        final models = Models(loader: (_) => Future.error(StateError('no such file')));
        final seen = <ModelsProgress>[];
        models.onProgress(seen.add);
        unawaited(models.preload());
        t.flushMicrotasks();
        expect(seen.last, (asked: 4, done: 4));
        expect(models.model(ModelName.kitchen), isNull);
        expect(models.piece(ModelName.kitchen, 'fridge', (_) => throw StateError('not painted')).children, isEmpty);
      });
    });
  });
}
