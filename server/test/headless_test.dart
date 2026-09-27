import 'package:agent_office_server/src/headless.dart';
import 'package:office_shared/shared.dart' show flagBold, rgbFlag;
import 'package:test/test.dart';
import 'package:xterm_core/xterm_core.dart';

/// Every cell of both terminals' buffers must look the same: same text, colors and attributes.
/// An empty cell and a default-styled space are the same to the eye.
void expectSameCells(HeadlessTerminal a, HeadlessTerminal b, {bool altToo = true}) {
  void compare(Buffer x, Buffer y, String which) {
    expect(y.height, x.height, reason: '$which: line count');
    for (var row = 0; row < x.height; row++) {
      final lx = x.lines[row], ly = y.lines[row];
      expect(ly.isWrapped, lx.isWrapped, reason: '$which row $row wrapped');
      for (var col = 0; col < x.viewWidth; col++) {
        String cell(BufferLine l) {
          var cp = l.getCodePoint(col);
          final blank = cp == 0 || cp == 0x20;
          if (blank) cp = 0x20;
          final plain =
              blank && l.getBackground(col) == 0 && l.getAttributes(col) & (CellAttr.inverse | CellAttr.underline) == 0;
          return plain
              ? ' '
              : '${String.fromCharCode(cp)} ${blank ? 0 : l.getForeground(col)} ${l.getBackground(col)} ${l.getAttributes(col)}';
        }

        expect(cell(ly), cell(lx), reason: '$which row $row col $col');
      }
    }
    expect(y.cursorX, x.cursorX, reason: '$which cursor x');
    expect(y.cursorY, x.cursorY, reason: '$which cursor y');
  }

  compare(a.term.mainBuffer, b.term.mainBuffer, 'normal');
  expect(b.isAlt, a.isAlt);
  if (altToo && a.isAlt) compare(a.term.altBuffer, b.term.altBuffer, 'alt');
}

HeadlessTerminal replay(HeadlessTerminal a, {int? scrollback}) {
  final b = HeadlessTerminal(cols: a.cols, rows: a.rows);
  b.write(a.serialize(scrollback: scrollback));
  return b;
}

void main() {
  test('a snapshot recreates colors, attributes, wide characters, wrapping and the cursor', () {
    final a = HeadlessTerminal(cols: 40, rows: 8);
    final out = StringBuffer();
    for (var i = 0; i < 30; i++) {
      out.write('\x1b[3${i % 8}mline $i\x1b[0m plain \x1b[1;4mbold\x1b[0m\r\n');
    }
    out.write('\x1b[38;5;208m256\x1b[48;2;10;20;30m rgb bg \x1b[0m\x1b[7m inv \x1b[0m\x1b[95;103mbright\x1b[0m\r\n');
    out.write('wide: 日本語テキスト and ${'long ' * 20}\r\n');
    out.write('\x1b[2;3mdim italic\x1b[0m   gap   \x1b[9mstrike\x1b[0m\r\n');
    // A wide character that doesn't fit the last column.
    out.write('${'x' * 39}界 after\r\n');
    out.write('\x1b[44m\x1b[K\x1b[0m(a blue row above)\r\n');
    out.write('prompt> \x1b[3D');
    a.write(out.toString());
    final b = replay(a);
    expectSameCells(a, b);
  });

  test('scrollback is capped, and more output carries on the same in both', () {
    final a = HeadlessTerminal(cols: 20, rows: 5);
    for (var i = 0; i < 100; i++) {
      a.write('row $i\r\n');
    }
    final b = replay(a, scrollback: 10);
    expect(b.term.mainBuffer.height, 15);
    expect(b.term.mainBuffer.lines[0].getCodePoint(0), 'r'.codeUnitAt(0));
    expect(TermLine(b.term.mainBuffer.lines[0], 20).translateToString(true), 'row 86');
    final full = replay(a);
    expectSameCells(a, full);
    for (final t in [a, full]) {
      t.write('\x1b[31mmore\r\nand more');
    }
    expectSameCells(a, full);
  });

  test('a full-screen program: the alternate screen, its cursor, modes and scroll region', () {
    final a = HeadlessTerminal(cols: 30, rows: 6);
    a.write('shell history\r\n\$ vim\r\n');
    a.write('\x1b[?1049h\x1b[H\x1b[2J\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?25l');
    a.write('\x1b[1;1H\x1b[7m status \x1b[0m\x1b[2;1Htext\x1b[2;5r\x1b[4;2H\x1b[32m');
    final b = replay(a);
    expectSameCells(a, b);
    expect(b.term.cursorKeysMode, isTrue);
    expect(b.term.bracketedPasteMode, isTrue);
    expect(b.term.mouseMode, MouseMode.upDownScroll);
    expect(b.term.mouseReportMode, MouseReportMode.sgr);
    expect(b.term.cursorVisibleMode, isFalse);
    expect(b.term.buffer.marginTop, 1);
    expect(b.term.buffer.marginBottom, 4);
    // The style in force carries on.
    for (final t in [a, b]) {
      t.write('go');
    }
    expectSameCells(a, b);
    // Leaving the program brings back the shell.
    for (final t in [a, b]) {
      t.write('\x1b[?1049l\x1b[r');
    }
    expect(b.isAlt, isFalse);
    expectSameCells(a, b, altToo: false);
  });

  test('progress reports and titles are read off the output', () {
    final t = HeadlessTerminal(cols: 20, rows: 5);
    final busy = <bool>[];
    final titles = <String>[];
    t.onProgress = busy.add;
    t.onTitleChange = titles.add;
    t.write('\x1b]9;4;3;\x07hi\x1b]0;✳ Fixing tests\x07\x1b]9;4;0;\x1b\\\x1b]9;hello\x07');
    expect(busy, [true, false]);
    expect(titles, ['✳ Fixing tests']);
  });

  test('laptop frames: styled runs, only changed rows after a keyframe, trimmed', () {
    final t = HeadlessTerminal(cols: 20, rows: 3);
    t.write('\x1b[1;31mred\x1b[0m plain   \r\n\x1b[38;2;1;2;3mrgb');
    final last = <String>[];
    final f = t.snapshotScreen(last)!;
    expect(f.full, isTrue);
    expect(f.lines.length, 3);
    expect(f.lines[0]!.map((r) => r.toJson()).toList(), [
      ['red', 1, -1, flagBold],
      [' plain', -1, -1, 0],
    ]);
    expect(f.lines[1]!.single.toJson(), ['rgb', rgbFlag | 0x010203, -1, 0]);
    expect(f.lines[2], isEmpty);
    expect(f.cursor, (3, 1));
    expect(t.snapshotScreen(last), isNull);
    t.write('!');
    final d = t.snapshotScreen(last)!;
    expect(d.full, isFalse);
    expect(d.lines.keys, [1]);
    expect(t.screenText(), 'red plain   \nrgb!\n');
  });

  test('a marker follows its line as output scrolls, and is gone once trimmed', () {
    final t = HeadlessTerminal(cols: 10, rows: 3, scrollbackLines: 30);
    t.write('a\r\nb\r\n');
    final m = t.registerMarker();
    expect(m.line, 2);
    t.write('c\r\nd\r\n');
    expect(m.line, 2);
    // The buffer holds 33 lines (the screen's 3 and 30 above): 30 more push the marked one to the top.
    for (var i = 0; i < 30; i++) {
      t.write('x\r\n');
    }
    expect(m.line, 0);
    t.write('y\r\n');
    expect(m.line, -1);
  });
}
