import 'package:office_shared/protocol.dart';
import 'package:office_shared/search.dart';
import 'package:agent_office/ui/terminal_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as x;

WorkerInfo worker({int cols = 80, int rows = 24, List<String> viewers = const ['Ada'], Map<String, dynamic> extra = const {}}) =>
    WorkerInfo.fromJson({
      'id': 'w1',
      'kind': 'agent',
      'deskId': 'desk-1',
      'name': 'Nova',
      'color': '#ff8a5b',
      'status': 'working',
      'acked': true,
      'createdBy': 'Ada',
      'createdAt': 0,
      'cols': cols,
      'rows': rows,
      'viewers': viewers,
      ...extra,
    });

void main() {
  group('TermSizePolicy', () {
    test('the only viewer fits the PTY to its window, once per size', () {
      final p = TermSizePolicy();
      final w = worker();
      final d = p.decide(typing: false, w: w, fit: (cols: 120, rows: 40), current: (cols: 80, rows: 24));
      expect(d.resizeTo, (cols: 120, rows: 40));
      expect(d.send, (cols: 120, rows: 40));
      // Asked already; the worker update hasn't come back yet.
      expect(p.decide(typing: false, w: w, fit: (cols: 120, rows: 40), current: (cols: 120, rows: 40)).send, isNull);
    });

    test('a watcher among several follows the PTY instead of resizing it', () {
      final p = TermSizePolicy();
      final w = worker(cols: 100, rows: 30, viewers: ['Ada', 'Grace']);
      final d = p.decide(typing: false, w: w, fit: (cols: 60, rows: 20), current: (cols: 80, rows: 24));
      expect(d.resizeTo, (cols: 100, rows: 30));
      expect(d.send, isNull);
    });

    test('typing claims the PTY even when others watch (latest typist wins)', () {
      final p = TermSizePolicy();
      final w = worker(cols: 100, rows: 30, viewers: ['Ada', 'Grace']);
      final d = p.decide(typing: true, w: w, fit: (cols: 60, rows: 20), current: (cols: 100, rows: 30));
      expect(d.send, (cols: 60, rows: 20));
      expect(d.resizeTo, (cols: 60, rows: 20));
    });

    test('follows someone else resizing the PTY, but not its own request echoing back', () {
      final p = TermSizePolicy();
      p.decide(typing: true, w: worker(), fit: (cols: 90, rows: 30), current: (cols: 80, rows: 24));
      expect(p.follow(worker(cols: 90, rows: 30), (cols: 90, rows: 30)), isNull);
      expect(p.follow(worker(cols: 70, rows: 20), (cols: 90, rows: 30)), (cols: 70, rows: 20));
      expect(p.lastSent, '');
    });
  });

  test('terminalTitle: provider, name, task and branch', () {
    final w = worker(
      extra: {
        'title': 'Fix login',
        'worktree': {'path': 'p', 'branch': 'nova/fix', 'base': 'main'},
      },
    );
    expect(terminalTitle(w, null), 'Claude Code · Nova · Fix login · 🌿 nova/fix');
    final shell = WorkerInfo.fromJson({...w.toJson(), 'kind': 'shell', 'title': null, 'worktree': null});
    expect(terminalTitle(shell, null), 'Nova');
  });

  group('the xterm buffer as search reads it', () {
    x.Terminal term(String data, {int cols = 20, int rows = 5}) => x.Terminal(maxLines: 5000)
      ..resize(cols, rows)
      ..write(data);

    test('rows, wrapping, and blank cells as spaces', () {
      final t = term('hello\r\n\x1b[5Cgap\r\n${'a' * 25}');
      final buf = XtermBuffer(t.buffer);
      expect(buf.getLine(0)!.translateToString(true), 'hello');
      expect(buf.getLine(1)!.translateToString(true), '     gap');
      expect(buf.getLine(2)!.isWrapped, isFalse);
      expect(buf.getLine(3)!.isWrapped, isTrue);
      expect(logicalLines(buf).map((l) => l.text.trimRight()).toList().sublist(0, 3), ['hello', '     gap', 'a' * 25]);
    });

    test('findLine picks the hit nearest to where the server saw it', () {
      final lines = [for (var i = 0; i < 30; i++) i % 10 == 0 ? 'needle $i' : 'hay $i'];
      final t = term(lines.join('\r\n'), cols: 40, rows: 10);
      final buf = XtermBuffer(t.buffer);
      final len = buf.length;
      final row = findLine(buf, 'needle', len - 10)!;
      expect(buf.getLine(row)!.translateToString(true), 'needle 10');
      expect(findLine(buf, 'nowhere', 3), isNull);
    });

    test('urlAt finds the link under a cell, across a wrapped row', () {
      final t = term('see https://example.com/a/very/long/path?x=1, ok', cols: 20);
      final buf = XtermBuffer(t.buffer);
      expect(urlAt(buf, 0, 1), isNull);
      expect(urlAt(buf, 0, 6), 'https://example.com/a/very/long/path?x=1');
      expect(urlAt(buf, 1, 3), 'https://example.com/a/very/long/path?x=1');
      expect(urlAt(buf, 2, 8), isNull);
    });
  });
}
