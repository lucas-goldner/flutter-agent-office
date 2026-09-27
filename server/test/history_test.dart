import 'dart:io';

import 'package:agent_office_server/src/headless.dart';
import 'package:agent_office_server/src/history.dart';
import 'package:office_shared/shared.dart' show ChatLine, findLine, searchKey, snippet;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String dataDir() {
  final dir = Directory.systemTemp.createTempSync('agent-office-history-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir.path;
}

HeadlessTerminal terminal([int cols = 80, int rows = 10]) =>
    HeadlessTerminal(cols: cols, rows: rows, scrollbackLines: 3000);

ChatLine line(String text, [String name = 'Sam', int? at]) =>
    ChatLine(from: 'x', name: name, color: '#ef476f', text: text, at: at ?? DateTime.now().millisecondsSinceEpoch);

List<String> rows(HeadlessTerminal t) {
  final buf = t.normal;
  return [for (var y = 0; y < buf.length; y++) buf.getLine(y)!.translateToString(true)];
}

void main() {
  test('chat survives a restart, trimmed to the newest lines, and skips a torn last line', () {
    final dir = dataDir();
    final first = ChatLog(dir);
    for (var i = 0; i < chatKeep + 5; i++) {
      first.add(line('message $i'));
    }
    File(p.join(dir, 'chat.jsonl')).writeAsStringSync('{"from":"x","name":"Sam","te', mode: FileMode.append);

    final again = ChatLog(dir);
    final recent = again.recent(chatKeep + 10);
    expect(recent.length, chatKeep);
    expect(recent.first.text, 'message 5');
    expect(recent.last.text, 'message ${chatKeep + 4}');
    // The rewrite on load dropped the overflow and the torn line.
    expect(File(p.join(dir, 'chat.jsonl')).readAsStringSync().trim().split('\n').length, chatKeep);
  });

  test('chat search matches text or sender, any case and spacing, newest first', () {
    final log = ChatLog(dataDir());
    log.add(line('the  deploy TIMED out'));
    log.add(line('lunch?', 'Robin'));
    log.add(line('deploy is green now'));
    expect(log.search(searchKey('Deploy'), 10).hits.map((l) => l.text), [
      'deploy is green now',
      'the  deploy TIMED out',
    ]);
    expect(log.search(searchKey('deploy timed'), 10).hits.map((l) => l.text), ['the  deploy TIMED out']);
    expect(log.search(searchKey('robin: lunch'), 10).hits.map((l) => l.text), ['lunch?']);
    final capped = log.search(searchKey('deploy'), 1);
    expect(capped.hits.length, 1);
    expect(capped.more, isTrue);
  });

  test('a terminal tail restores its lines, colors and wrapping into a new terminal of another width', () {
    final a = terminal(120);
    final out = StringBuffer();
    for (var i = 1; i <= 50; i++) {
      out.write('\x1b[32mline $i\x1b[0m\r\n');
    }
    out.write('wrapped ${'y' * 150} END\r\n');
    // A TUI leaves the cursor above its last line; the tail still ends after it.
    a.write('$out\x1b[5A');
    final tail = terminalTail(a, 20);
    expect(tail, contains('\x1b[0;32m'), reason: 'keeps colors');

    final b = terminal(100);
    b.write('$tail\r\nNEXT\r\n');
    final text = rows(b);
    expect(text, isNot(contains('line 30')), reason: 'only the last 20 lines');
    expect(text, contains('line 50'));
    final next = text.indexOf('NEXT');
    expect(text[next - 1], endsWith(' END'), reason: 'what follows comes right after the old last line');
    expect(searchTerminal(b, searchKey('yyy end'), 5).hits.length, 1, reason: 'a wrapped line is found as one line');
  });

  test('terminal search shows each distinct line once, newest first, and says where it is', () {
    final term = terminal();
    term.write('status: building\r\nError: disk full\r\nstatus: building\r\nerror: DISK full again\r\n');
    final found = searchTerminal(term, searchKey('disk full'), 10);
    expect(found.hits.map((h) => h.text), ['error: DISK full again', 'Error: disk full']);
    expect(searchTerminal(term, searchKey('status'), 10).hits.map((h) => h.text), ['status: building']);
    // The row is where the browser's copy of the terminal looks for it again.
    final hit = found.hits[1];
    expect(findLine(term.active, searchKey('disk full'), hit.rows - hit.row), hit.row);
  });

  test('a full-screen program\'s screen is added to the tail as plain text', () {
    final a = terminal(40, 5);
    a.write('before\r\n\x1b[?1049h\x1b[H\x1b[1mstatus bar\x1b[0m\x1b[3;1Hbody   \r\n');
    expect(terminalTail(a, 20), 'before\x1b[0m\r\nstatus bar\r\n\r\nbody');
  });

  test('snippets cut long lines down around the match', () {
    final long = '${'a ' * 200}NEEDLE${' b' * 200}';
    final s = snippet(long, 'needle', 60);
    expect(s, contains('NEEDLE'));
    expect(s.startsWith('…') && s.endsWith('…'), isTrue);
    expect(s.length, lessThanOrEqualTo(62));
  });

  test('scrollback files are per worker, and pruning keeps only workers still at a desk', () {
    final store = ScrollbackStore(dataDir());
    store.save('aaa', 'one');
    store.save('bbb', 'two');
    store.save('../evil', 'nope');
    store.prune({'aaa'});
    expect(store.load('aaa'), 'one');
    expect(store.load('bbb'), isNull);
    expect(store.load('../evil'), isNull);
    store.remove('aaa');
    expect(store.load('aaa'), isNull);
  });
}
