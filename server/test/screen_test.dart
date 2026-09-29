// Port of tests/screen.test.ts: a terminal's snapshot keeps the mouse encoding a program switched
// on (headless.dart's serializer writes the report mode back, which upstream's screen.ts adds to
// xterm.js's), so a browser opening OpenCode's terminal still scrolls it.
import 'package:agent_office_server/src/headless.dart';
import 'package:test/test.dart';

HeadlessTerminal terminal() => HeadlessTerminal(cols: 80, rows: 10);

/// A fresh terminal fed a snapshot ends up with the mouse the way the snapshot left it.
HeadlessTerminal restored(String snapshot) => terminal()..write(snapshot);

void main() {
  test('a snapshot keeps the SGR mouse encoding OpenCode switches on, so the wheel still reaches it', () {
    final t = terminal();
    // What OpenCode prints on start: the alternate screen, every mouse tracking mode, then SGR reports.
    t.write('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006hhello');
    final snap = t.serialize(scrollback: 100);
    expect(snap, contains('\x1b[?1003h'));
    expect(snap, contains('\x1b[?1006h'));

    final again = restored(snap);
    expect(
      again.serialize(scrollback: 100),
      contains('\x1b[?1006h'),
      reason: 'the encoding survives a second hop (pty host, then office, then browser)',
    );
    expect(again.serialize(scrollback: 100), contains('\x1b[?1003h'));
  });

  test('switching the encoding off, or a full reset, leaves it out of the snapshot', () {
    final off = terminal()..write('\x1b[?1000h\x1b[?1006h\x1b[?1006l');
    expect(off.serialize(scrollback: 100), isNot(contains('\x1b[?1006h')));

    final reset = terminal()..write('\x1b[?1000h\x1b[?1006h\x1bc');
    expect(reset.serialize(scrollback: 100), isNot(contains('\x1b[?1006h')));
  });

  test('a terminal without the mouse snapshots as before', () {
    final t = terminal()..write('plain output\r\n');
    expect(t.serialize(scrollback: 100), isNot(matches(RegExp('\x1b\\[\\?10(0[0-6]|1[56])h'))));
  });
}
