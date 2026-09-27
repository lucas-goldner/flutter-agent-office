// Port of tests/laptop.test.ts, plus the colour resolution the painter uses.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:office_shared/protocol.dart';
import 'package:agent_office/state/screen_state.dart';
import 'package:agent_office/world/laptop_screen.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ScreenState screen(int cols, int rows, int activeRows, {int? width, int bg = -1}) {
  final s = ScreenState(cols: cols, rows: rows, cursor: (0, 0), version: 1);
  for (var y = 0; y < activeRows; y++) {
    s.lines[y] = [Run('x' * (width ?? cols), -1, bg, 0)];
  }
  return s;
}

const size = Size(1024, 680);

List<double> textYs(List<ScreenOp> ops) => [
  for (final op in ops)
    if (op is TextOp) op.at.dy,
];

void main() {
  test('fills a sparse wide laptop screen instead of leaving text in its upper half', () {
    final ys = textYs(screenOps(size, screen(100, 30, 8), zoomRows: 22));
    expect(ys, isNotEmpty);
    expect(ys.reduce(math.min), greaterThan(200));
    expect(ys.reduce(math.max), lessThan(480));
  });

  test('keeps very wide sparse output vertically centered within the laptop canvas', () {
    final ys = textYs(screenOps(size, screen(180, 45, 6), zoomRows: 22));
    expect(ys, isNotEmpty);
    expect(ys.reduce(math.min), greaterThan(250));
    expect(ys.reduce(math.max), lessThan(430));
  });

  test('keeps a tall full-screen styled terminal grid centered and complete', () {
    final ops = screenOps(size, screen(178, 45, 45, bg: 4), zoomRows: 22);
    final ys = textYs(ops);
    expect(ys.length, 45);
    expect(ys.reduce(math.min), greaterThan(60));
    expect(ys.reduce(math.max), lessThan(620));
    expect(ops.whereType<FillOp>().length, 46, reason: 'canvas fill plus one styled row per line');
  });

  test('preserves the plain narrow screen layout bounds', () {
    final ys = textYs(screenOps(size, screen(56, 22, 22, width: 20), zoomRows: 22));
    expect(ys, isNotEmpty);
    expect(ys.reduce(math.min), greaterThanOrEqualTo(20));
    expect(ys.reduce(math.max), lessThanOrEqualTo(660));
  });

  test('renders an empty screen as background without synthetic terminal text', () {
    final ops = screenOps(size, screen(100, 30, 0), zoomRows: 22);
    expect(textYs(ops), isEmpty);
    final first = ops.first as FillOp;
    expect(first.rect, const Rect.fromLTWH(0, 0, 1024, 680));
    expect(first.color, TermTheme.background);
  });

  test('shows the placeholder, centred, when there is no screen yet', () {
    final ops = screenOps(size, null, placeholder: 'asleep 💤');
    final t = ops.whereType<TextOp>().single;
    expect(t.text, 'asleep 💤');
    expect(t.center, isTrue);
    expect(t.at, const Offset(512, 340));
    expect(screenOps(size, null).whereType<TextOp>().single.text, 'booting…');
  });

  group('resolveColor', () {
    test('default, the theme 16, the cube, the greys and true colour', () {
      expect(resolveColor(-1, TermTheme.foreground), TermTheme.foreground);
      expect(resolveColor(1, TermTheme.foreground), TermTheme.red);
      expect(resolveColor(15, TermTheme.foreground), TermTheme.brightWhite);
      expect(resolveColor(16, TermTheme.foreground), const Color(0xFF000000));
      expect(resolveColor(196, TermTheme.foreground), const Color(0xFFFF0000));
      expect(resolveColor(232, TermTheme.foreground), const Color(0xFF080808));
      expect(resolveColor(255, TermTheme.foreground), const Color(0xFFEEEEEE));
      expect(resolveColor(rgbFlag | 0x123456, TermTheme.foreground), const Color(0xFF123456));
      expect(termPalette.length, 256);
    });

    test('inverse swaps, with the background standing in for a default one', () {
      final plain = runColors(const Run('a', 2, -1, 0));
      expect(plain.fg, TermTheme.green);
      expect(plain.bg, isNull);
      final inv = runColors(const Run('a', -1, -1, flagInverse));
      expect(inv.fg, TermTheme.background);
      expect(inv.bg, TermTheme.foreground);
    });
  });

  test('paints into a picture', () {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final s = screen(80, 24, 10, bg: 4)..lines[3] = [const Run('bold', 1, -1, flagBold | flagDim)];
    paintScreen(canvas, size, s, zoomRows: 22);
    paintScreen(canvas, size, null, placeholder: 'booting…');
    final pic = rec.endRecording();
    expect(pic, isNotNull);
    pic.dispose();
  });
}
