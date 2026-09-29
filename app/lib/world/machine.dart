// The machine monitor on the west wall (world/machine.ts): how busy the CPU and memory are, with the
// last few minutes of each, and how many workers the office runs of the most it takes.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:office_shared/protocol.dart';

import '../ui/screen_paint.dart';

const _ink = '#1b1d2e';
const _muted = '#9aa0b8';

/// The screen's own shape (MachineMonitor is 2.3 × 1.3 m).
const double machineWidth = 920;
const double machineHeight = 520;

/// Green while there's room, amber when it's getting full, red from where hiring gets a warning.
String loadColor(num pct) => pct >= 90
    ? '#ef476f'
    : pct >= 70
    ? '#ffd166'
    : '#06d6a0';

String fmtGb(int bytes) {
  final gb = bytes / math.pow(2, 30);
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}

/// The office has as many workers as it takes.
bool officeFull(MachineState s) => s.limit != null && s.workers >= s.limit!;

/// What the hire dialog says while the machine is under pressure.
String? pressureNote(MachineState s) => s.pressure == null
    ? null
    : '⚠️ This machine is under pressure: ${s.pressure}. Another worker may slow down the ones already working.';

/// What the header says about room for another worker, and in what colour.
(String, String) machineStatus(MachineState s) {
  if (s.memTotal == 0) return ('…', _muted);
  if (s.pressure != null) return ('⚠️ Under pressure', '#ef476f');
  if (officeFull(s)) return ('🚫 Office full', '#ffd166');
  return ('✅ Room to hire', '#06d6a0');
}

/// The footer's words: the workers against the limit.
String workersLabel(MachineState s) => s.limit == null
    ? '👷 ${s.workers} worker${s.workers == 1 ? '' : 's'} · no limit'
    : '👷 ${s.workers} of ${s.limit} workers';

/// Paints the monitor, remembering what it drew last so an unchanged state isn't painted again.
class MachinePainter {
  String _drawn = '';

  /// Whether [s] differs from what was painted last (and marks it painted).
  bool changed(MachineState s) {
    final key = jsonEncode(s.toJson());
    if (key == _drawn) return false;
    _drawn = key;
    return true;
  }
}

/// Draws the whole screen for [s], in 920×520 units.
void paintMachine(Canvas canvas, MachineState s) {
  final g = Pen(canvas);
  g.rect(0, 0, machineWidth, machineHeight, css(_ink));
  const white = Color(0xFFFFFFFF);

  // Header: what this is, and whether there's room for another worker.
  g.text(
    '🖥️ This machine',
    30,
    50,
    g.style(40, weight: FontWeight.w900, color: white),
    align: TextAlignX.left,
  );
  final (status, color) = machineStatus(s);
  final st = g.style(30, weight: FontWeight.w800, color: css(_ink));
  final tw = g.measure(status, st);
  g.roundRect(machineWidth - 30 - tw - 32, 24, tw + 32, 50, 25, css(color));
  g.text(status, machineWidth - 30 - (tw + 32) / 2, 49, st);

  final memPct = s.memTotal > 0 ? (s.memUsed / s.memTotal * 100).round() : 0;
  _panel(g, 30, 100, 415, 'CPU', s.cpu.round(), s.cores > 0 ? '${s.cores} core${s.cores == 1 ? '' : 's'}' : '', [
    for (final (c, _) in s.history) c,
  ]);
  _panel(g, 475, 100, 415, 'Memory', memPct, s.memTotal > 0 ? '${fmtGb(s.memUsed)} of ${fmtGb(s.memTotal)}' : '', [
    for (final (_, m) in s.history) m,
  ]);

  // Footer: the workers, one pip each, against the limit.
  const y = 440.0;
  final label = workersLabel(s);
  final ls = g.style(32, weight: FontWeight.w800, color: white);
  g.text(label, 30, y, ls, align: TextAlignX.left);
  final limit = s.limit;
  if (limit != null) {
    final x0 = 30 + g.measure(label, ls) + 28;
    final room = machineWidth - 30 - x0;
    final n = math.max(limit, s.workers);
    if (n > 0 && room > 0) {
      final pip = math.min(34.0, room / n);
      final full = officeFull(s);
      for (var i = 0; i < n; i++) {
        final c = i >= limit
            ? '#ef476f'
            : i < s.workers
            ? (full ? '#ffd166' : '#06d6a0')
            : '#3a3d55';
        g.roundRect(x0 + i * pip, y - 14, math.max(2, pip - 6), 30, math.min(8, pip / 3), css(c));
      }
    }
  }
}

/// One gauge: its name, the percent now, a line under it, and the last few minutes as a filled graph.
void _panel(Pen g, double x, double y, double w, String name, int pct, String sub, List<double> history) {
  final color = css(loadColor(pct));
  g.roundRect(x, y, w, 300, 18, css('#25283d'));
  g.text(
    name,
    x + 20,
    y + 32,
    g.style(28, weight: FontWeight.w800, color: css(_muted)),
    align: TextAlignX.left,
  );
  g.text(
    '$pct%',
    x + 20,
    y + 94,
    g.style(84, weight: FontWeight.w900, color: color),
    align: TextAlignX.left,
  );
  g.text(
    sub,
    x + 20,
    y + 152,
    g.style(24, weight: FontWeight.w700, color: css(_muted)),
    align: TextAlignX.left,
  );
  // The graph: 0-100%, the newest reading on the right.
  final gx = x + 20, gy = y + 180, gw = w - 40;
  const gh = 100.0;
  // The 90% line: past it, hiring comes with a warning.
  g.line(gx, gy + gh * 0.1, gx + gw, gy + gh * 0.1, css('#3a3d55'), 2);
  if (history.length < 2) return;
  final step = gw / (history.length - 1);
  Offset at(int i) => Offset(gx + i * step, gy + gh - (history[i].clamp(0, 100) / 100) * gh);
  final line = Path()..moveTo(at(0).dx, at(0).dy);
  for (var i = 1; i < history.length; i++) {
    line.lineTo(at(i).dx, at(i).dy);
  }
  final area = Path()..moveTo(gx, gy + gh);
  for (var i = 0; i < history.length; i++) {
    area.lineTo(at(i).dx, at(i).dy);
  }
  area
    ..lineTo(gx + gw, gy + gh)
    ..close();
  g.canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.28));
  g.canvas.drawPath(
    line,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round
      ..color = color,
  );
}
