// The faces of the four wall boards (a port of world/boards.ts): the issues and PR cork boards
// with pinned sticky notes, the services chalkboard and the task-queue whiteboard. Each is a
// 1200x600 widget driven by the store, for a flutter_scene WidgetComponent. They paint like the
// old canvases did, and only repaint when what they show changes.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:office_shared/layout.dart' show deskById;
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import '../ui/gh_logic.dart' show kNoteColors, kPins, parseHex;
import '../ui/theme.dart' show kFallback, kMonoFallback;

const kFaceSize = Size(1200, 600);
const _font = 'Nunito';
const _fallback = kFallback;
const _ink = Color(0xFF2B2D42);

TextStyle _ts(double size, FontWeight w, Color c, {String family = _font}) =>
    TextStyle(fontFamily: family, fontFamilyFallback: family == _font ? _fallback : kMonoFallback, fontSize: size, fontWeight: w, color: c, height: 1);

enum _Align { left, center, right }

/// Measures and draws text the way canvas fillText does: at a baseline, anchored left/centre/right.
class _Pen {
  _Pen(this.canvas);
  final Canvas canvas;

  TextPainter _tp(String s, TextStyle style) => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();

  double width(String s, TextStyle style) => _tp(s, style).width;

  /// [middle]: y is the text's vertical middle (textBaseline = 'middle'), else its alphabetic baseline.
  void text(String s, TextStyle style, double x, double y, {_Align align = _Align.left, bool middle = false}) {
    final tp = _tp(s, style);
    final dx = switch (align) { _Align.left => x, _Align.center => x - tp.width / 2, _Align.right => x - tp.width };
    final dy = middle ? y - tp.height / 2 : y - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    tp.paint(canvas, Offset(dx, dy));
    tp.dispose();
  }

  List<String> wrap(String text, TextStyle style, double maxW, int maxLines) {
    final words = text.split(RegExp(r'\s+'));
    final lines = <String>[];
    var cur = '';
    for (final w in words) {
      final next = cur.isNotEmpty ? '$cur $w' : w;
      if (width(next, style) > maxW && cur.isNotEmpty) {
        lines.add(cur);
        cur = w;
        if (lines.length == maxLines) break;
      } else {
        cur = next;
      }
    }
    if (lines.length < maxLines && cur.isNotEmpty) lines.add(cur);
    if (lines.length == maxLines && words.join(' ').length > lines.join(' ').length) {
      lines[maxLines - 1] = lines[maxLines - 1].replaceFirst(RegExp(r'.{0,2}$'), '…');
    }
    return lines;
  }

  String clip(String text, TextStyle style, double maxW) {
    if (width(text, style) <= maxW) return text;
    var s = text;
    while (s.length > 1 && width('$s…', style) > maxW) {
      s = s.substring(0, s.length - 1);
    }
    return '$s…';
  }
}

/// A face: a fixed 1200x600 canvas behind a repaint boundary.
class _Face extends StatelessWidget {
  const _Face(this.painter);
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: ClipRect(child: SizedBox.fromSize(size: kFaceSize, child: CustomPaint(size: kFaceSize, painter: painter, isComplex: true))),
      );
}

// ---- The issues and PR cork boards --------------------------------------------------------------

enum CorkKind { issues, pulls }

/// The 📌 issues or 🔀 PR cork board, from the store.
class CorkBoardFace extends StatelessWidget {
  const CorkBoardFace({super.key, required this.store, required this.kind});
  final Store store;
  final CorkKind kind;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store.topics(kind == CorkKind.issues ? const [Topic.issues] : const [Topic.pulls, Topic.workers]),
        builder: (context, _) => _Face(kind == CorkKind.issues
            ? CorkBoardPainter.issues(store.issues)
            : CorkBoardPainter.pulls(store.pulls, store.workers)),
      );
}

class CorkNote {
  const CorkNote(this.number, this.title, {this.draft = false, this.worker});
  final int number;
  final String title;
  final bool draft;

  /// A PR's worker, so you can tell whose PR it is from across the room.
  final ({String name, Color color, String desk})? worker;
}

/// Paints a cork board with pinned sticky notes (BoardTexture.render).
class CorkBoardPainter extends CustomPainter {
  CorkBoardPainter._(this.kind, this.notes, this.error, this.loading, this.fetchedAt)
      : key = '${kind.name}|$error|$loading|${fetchedAt > 0}|${notes.map((n) => '${n.number}:${n.title}:${n.draft}:${n.worker}').join('\n')}';

  factory CorkBoardPainter.issues(GhState<GhIssue> st) => CorkBoardPainter._(
        CorkKind.issues,
        [for (final i in st.items.where((i) => i.state == 'OPEN')) CorkNote(i.number, i.title)],
        st.error,
        st.loading,
        st.fetchedAt,
      );

  /// [workers] lets PR notes name the desk they came from.
  factory CorkBoardPainter.pulls(GhState<GhPull> st, Map<String, WorkerInfo> workers) => CorkBoardPainter._(
        CorkKind.pulls,
        [
          for (final p in st.items.where((p) => p.state == 'OPEN'))
            () {
              final w = workerForPull(workers.values, p);
              return CorkNote(
                p.number,
                p.title,
                draft: p.isDraft,
                worker: w == null ? null : (name: w.name, color: parseHex(w.color, const Color(0xFF8D99AE)), desk: deskById[w.deskId]?.label ?? 'desk'),
              );
            }(),
        ],
        st.error,
        st.loading,
        st.fetchedAt,
      );

  final CorkKind kind;
  final List<CorkNote> notes;
  final String? error;
  final bool loading;
  final int fetchedAt;

  /// What is drawn, to repaint only when it changes.
  final String key;

  static final Float32List _speckDark = _specks(true);
  static final Float32List _speckLight = _specks(false);

  /// Cork speckles, from the same seeded generator as the old canvas.
  static Float32List _specks(bool dark) {
    var seed = 7;
    double rnd() => (seed = (seed * 16807) % 2147483647) / 2147483647;
    final out = <double>[];
    for (var i = 0; i < 1400; i++) {
      final isDark = rnd() > 0.5;
      final x = rnd() * 1200 + 1.5, y = rnd() * 600 + 1.5;
      if (isDark == dark) out.addAll([x, y]);
    }
    return Float32List.fromList(out);
  }

  @override
  void paint(Canvas g, Size size) {
    const w = 1200.0, h = 600.0;
    g.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFD8A86A));
    Paint speck(Color c) => Paint()
      ..color = c
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    g.drawRawPoints(ui.PointMode.points, _speckDark, speck(const Color(0x2E78461E)));
    g.drawRawPoints(ui.PointMode.points, _speckLight, speck(const Color(0x2EFFF0D2)));
    final pen = _Pen(g);
    if (notes.isEmpty) {
      final note = error != null
          ? '⚠️ $error'
          : loading && fetchedAt == 0
              ? 'Loading…'
              : kind == CorkKind.issues
                  ? 'No open issues 🎉'
                  : 'No open PRs';
      final style = _ts(40, FontWeight.w800, _ink);
      final lines = pen.wrap(note.replaceAll('`', ''), style, 760, 4);
      final boxH = 60.0 + lines.length * 50;
      g.drawRect(Rect.fromLTWH(w / 2 - 420, h / 2 - boxH / 2, 840, boxH), Paint()..color = const Color(0xFFFFFAF3));
      for (var i = 0; i < lines.length; i++) {
        pen.text(lines[i], style, w / 2, h / 2 - ((lines.length - 1) * 50) / 2 + i * 50, align: _Align.center, middle: true);
      }
      return;
    }
    // Fewer notes -> bigger notes, so a quiet board is still readable from across the room.
    final n = math.min(notes.length, 15);
    final cols = n <= 2 ? n : n <= 4 ? 2 : n <= 6 ? 3 : n <= 8 ? 4 : 5;
    final rows = math.min(3, (n / cols).ceil());
    final scale = math.min(2.0, math.max(1.0, 3 / math.max(cols.toDouble(), rows * 1.3)));
    final nw = math.min(208 * scale, (w - 40) / cols - 30);
    final nh = math.min(164 * scale, (h - 40) / rows - 30);
    final gx = (w - cols * nw) / (cols + 1);
    final gy = (h - rows * nh) / (rows + 1);
    final shown = notes.take(cols * rows).toList();
    for (var i = 0; i < shown.length; i++) {
      final it = shown[i];
      final c = i % cols;
      final r = i ~/ cols;
      final x = gx + c * (nw + gx);
      final y = gy + r * (nh + gy);
      g.save();
      g.translate(x + nw / 2, y + nh / 2);
      g.rotate(((it.number * 37) % 7 - 3) * 0.012);
      g.drawRect(Rect.fromLTWH(-nw / 2 + 5, -nh / 2 + 7, nw, nh), Paint()..color = const Color(0x40000000));
      g.drawRect(
        Rect.fromLTWH(-nw / 2, -nh / 2, nw, nh),
        Paint()..color = it.draft ? const Color(0xFFE9ECEF) : kNoteColors[it.number % kNoteColors.length],
      );
      final fs = (22 * math.min(scale, nh / 164)).roundToDouble();
      final wk = it.worker;
      final footer = wk != null ? fs * 1.3 : 0;
      pen.text('#${it.number}', _ts((fs * 1.35).roundToDouble(), FontWeight.w900, _ink), -nw / 2 + 14, -nh / 2 + fs * 2);
      final titleStyle = _ts(fs, FontWeight.w700, _ink);
      final lines = pen.wrap(it.title, titleStyle, nw - 28, math.max(2, ((nh - fs * 3 - footer) / (fs * 1.1)).floor()));
      for (var li = 0; li < lines.length; li++) {
        pen.text(lines[li], titleStyle, -nw / 2 + 14, -nh / 2 + fs * 3.4 + li * fs * 1.1);
      }
      if (wk != null) {
        // A dot in the worker's color and its desk.
        final rr = fs * 0.3;
        final yy = nh / 2 - fs * 0.75;
        final centre = Offset(-nw / 2 + 14 + rr, yy);
        g.drawCircle(centre, rr, Paint()..color = wk.color);
        g.drawCircle(centre, rr, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _ink);
        final st = _ts((fs * 0.78).roundToDouble(), FontWeight.w800, const Color(0xFF5C5F73));
        pen.text(pen.clip('${wk.name} · ${wk.desk}', st, nw - 28 - rr * 2 - 8), st, -nw / 2 + 14 + rr * 2 + 8, yy + fs * 0.28);
      }
      final pin = Offset(0, -nh / 2 + 10);
      g.drawCircle(pin, 11, Paint()..color = kPins[i % kPins.length]);
      g.drawCircle(pin, 11, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _ink);
      g.restore();
    }
    if (notes.length > cols * rows) {
      pen.text('+${notes.length - cols * rows} more', _ts(26, FontWeight.w800, _ink), w - 20, h - 16, align: _Align.right);
    }
  }

  @override
  bool shouldRepaint(CorkBoardPainter old) => old.key != key;
}

// ---- The services chalkboard -------------------------------------------------------------------

/// The services board: a chalkboard listing the web servers workers are running.
class ServicesBoardFace extends StatelessWidget {
  const ServicesBoardFace({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store.topics(const [Topic.services, Topic.workers]),
        builder: (context, _) => _Face(ServicesBoardPainter(store.services.items, store.workers)),
      );
}

class ServicesBoardPainter extends CustomPainter {
  ServicesBoardPainter(List<ServiceInfo> items, Map<String, WorkerInfo> workers)
      : rows = [
          for (final s in items)
            () {
              final w = workers[s.workerId];
              final title = (s.title ?? '').isNotEmpty ? s.title! : s.command;
              final who = [w?.name ?? 'A worker', ?w?.worktree?.branch].where((x) => x.isNotEmpty).join(' · ');
              return (port: s.port, title: title, who: who, color: w == null ? const Color(0xFF8D99AE) : parseHex(w.color, const Color(0xFF8D99AE)));
            }(),
        ];

  final List<({int port, String title, String who, Color color})> rows;

  // Worker updates stream in constantly; only redraw when what's shown changes.
  late final String key = rows.map((r) => '${r.port}|${r.title}|${r.who}|${r.color.toARGB32()}').join('\n');

  @override
  void paint(Canvas g, Size size) {
    const w = 1200.0, h = 600.0;
    g.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF23303B));
    // chalk smudges
    final smudge = Paint()..color = const Color(0x06FFFFFF);
    for (var i = 0; i < 18; i++) {
      g.drawRect(Rect.fromLTWH(((i * 997) % w) - 60, ((i * 613) % h) - 20, 260, 34), smudge);
    }
    final pen = _Pen(g);
    const chalk = Color(0xFFE9ECEF);
    if (rows.isEmpty) {
      pen.text('No web servers running', _ts(52, FontWeight.w900, chalk), w / 2, h / 2 - 20, align: _Align.center);
      pen.text('When a worker starts one, it shows up here', _ts(32, FontWeight.w700, const Color(0x99E9ECEF)), w / 2, h / 2 + 36, align: _Align.center);
      return;
    }
    final shown = rows.take(5).toList();
    final rowH = math.min(140.0, (h - 40) / shown.length);
    final fs = (rowH * 0.36).roundToDouble();
    for (var i = 0; i < shown.length; i++) {
      final r = shown[i];
      final y = 20 + i * rowH;
      g.drawRect(Rect.fromLTWH(24, y + 6, w - 48, rowH - 12), Paint()..color = const Color(0x0FFFFFFF));
      final dot = Offset(70, y + rowH / 2);
      g.drawCircle(dot, fs * 0.42, Paint()..color = r.color);
      g.drawCircle(dot, fs * 0.42, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = chalk);
      final portStyle = _ts(fs, FontWeight.w900, const Color(0xFFFFD166), family: 'monospace');
      pen.text(':${r.port}', portStyle, w - 50, y + rowH / 2 + fs * 0.35, align: _Align.right);
      final textW = w - 120 - 50 - pen.width(':${r.port}', portStyle) - 30;
      final titleStyle = _ts(fs, FontWeight.w800, const Color(0xFFF8F9FA));
      pen.text(pen.clip(r.title, titleStyle, textW), titleStyle, 110, y + rowH / 2 - fs * 0.08);
      final whoStyle = _ts((fs * 0.62).roundToDouble(), FontWeight.w700, const Color(0xA6E9ECEF));
      pen.text(pen.clip(r.who, whoStyle, textW), whoStyle, 110, y + rowH / 2 + fs * 0.72);
    }
    if (rows.length > shown.length) {
      pen.text('+${rows.length - shown.length} more', _ts(26, FontWeight.w800, chalk), w - 24, h - 10, align: _Align.right);
    }
  }

  @override
  bool shouldRepaint(ServicesBoardPainter old) => old.key != key;
}

// ---- The task queue whiteboard ------------------------------------------------------------------

/// The task queue: a whiteboard with what's waiting, who is on what, and the PRs that came out of it.
class QueueBoardFace extends StatelessWidget {
  const QueueBoardFace({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store.topics(const [Topic.queue, Topic.workers]),
        builder: (context, _) => _Face(QueueBoardPainter(store.queue, store.workers)),
      );
}

typedef QueueRow = ({String icon, String text, String side, Color color});

const _doneGrey = Color(0xFF8A8F98);

/// The rows the queue board lists: running, then waiting, then the last three finished.
List<QueueRow> queueRows(QueueState state, Map<String, WorkerInfo> workers) {
  String name(QueueTask t) => t.issue != null ? '#${t.issue}  ${t.title.replaceFirst(RegExp('^#${t.issue}\\s*'), '')}' : t.title;
  final running = state.tasks.where((t) => t.status == TaskStatus.running);
  final queued = state.tasks.where((t) => t.status == TaskStatus.queued).toList();
  final done = state.tasks.where((t) => t.status == TaskStatus.done).toList();
  final lastDone = done.skip(math.max(0, done.length - 3)).toList().reversed;
  const status = {
    WorkerStatus.starting: 'starting',
    WorkerStatus.idle: 'ready',
    WorkerStatus.working: 'working',
    WorkerStatus.needsInput: 'needs input ✋',
    WorkerStatus.done: 'done',
    WorkerStatus.exited: 'stopped',
    WorkerStatus.offline: 'asleep',
  };
  return [
    for (final t in running)
      (
        icon: '🤖',
        text: name(t),
        side: '${t.workerName ?? 'a worker'} · ${status[(t.workerId != null ? workers[t.workerId] : null)?.status ?? WorkerStatus.working]}',
        color: const Color(0xFF1E8F4E),
      ),
    for (var i = 0; i < queued.length; i++)
      (icon: '⏳', text: name(queued[i]), side: i == 0 ? 'up next' : '${i + 1}${const ['th', 'st', 'nd', 'rd'][i + 1 <= 3 ? i + 1 : 0]} in line', color: _ink),
    for (final t in lastDone)
      (
        icon: t.outcome == TaskOutcome.done ? '✅' : '⚠️',
        text: name(t),
        side: t.pr != null
            ? 'PR #${t.pr!.number}${t.pr!.state == 'MERGED' ? ' · merged' : ''}'
            : switch (t.outcome) {
                TaskOutcome.done => 'done',
                TaskOutcome.failed => "didn't start",
                TaskOutcome.killed => 'sent home',
                _ => 'stopped',
              },
        color: _doneGrey,
      ),
  ];
}

class QueueBoardPainter extends CustomPainter {
  QueueBoardPainter(QueueState state, Map<String, WorkerInfo> workers)
      : rows = queueRows(state, workers),
        summary = state.maxWorkers == 0
            ? 'paused'
            : '${state.tasks.where((t) => t.status == TaskStatus.running).length} working · ${state.tasks.where((t) => t.status == TaskStatus.queued).length} waiting · up to ${state.maxWorkers} at once';

  final List<QueueRow> rows;
  final String summary;
  late final String key = '$summary\n${rows.map((r) => '${r.icon}|${r.text}|${r.side}').join('\n')}';

  @override
  void paint(Canvas g, Size size) {
    const w = 1200.0, h = 600.0;
    g.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFF7F9FB));
    // A faint sheen and the marker tray along the bottom edge.
    g.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, const Offset(w, h), const [Color(0x99FFFFFF), Color(0x40C8D2DC)]),
    );
    g.drawRect(const Rect.fromLTWH(0, h - 22, w, 22), Paint()..color = const Color(0xFFC9D1D9));
    const markers = [Color(0xFFE63946), Color(0xFF1F5FBF), Color(0xFF1E8F4E), _ink];
    for (var i = 0; i < markers.length; i++) {
      g.drawRect(Rect.fromLTWH(w - 300 + i * 62, h - 30, 48, 14), Paint()..color = markers[i]);
    }
    final pen = _Pen(g);
    const blue = Color(0xFF1F5FBF);
    const grey = Color(0xFF6B7280);
    pen.text('Task queue', _ts(52, FontWeight.w900, blue), 40, 76);
    // A hand-drawn underline.
    g.drawPath(
      Path()
        ..moveTo(42, 92)
        ..quadraticBezierTo(160, 84, 318, 94),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = blue,
    );
    pen.text(summary, _ts(26, FontWeight.w700, grey), w - 40, 72, align: _Align.right);
    if (rows.isEmpty) {
      pen.text('Nothing queued', _ts(50, FontWeight.w900, _ink), w / 2, h / 2 - 10, align: _Align.center);
      pen.text('Add issues from the 📌 Issues board, or press E here', _ts(30, FontWeight.w700, grey), w / 2, h / 2 + 44, align: _Align.center);
      return;
    }
    final shown = rows.take(7).toList();
    final rowH = math.min(62.0, (h - 150) / shown.length);
    final fs = (rowH * 0.5).roundToDouble();
    for (var i = 0; i < shown.length; i++) {
      final r = shown[i];
      final y = 128 + i * rowH + fs;
      final main = _ts(fs, FontWeight.w800, r.color);
      pen.text(r.icon, main, 44, y);
      final sideStyle = _ts((fs * 0.78).roundToDouble(), FontWeight.w700, r.color);
      final sideW = pen.width(r.side, sideStyle);
      pen.text(r.side, sideStyle, w - 44, y, align: _Align.right);
      final maxW = w - 44 - sideW - 30 - 110;
      final text = pen.clip(r.text, main, maxW);
      pen.text(text, main, 110, y);
      if (r.color == _doneGrey) {
        g.drawLine(
          Offset(110, y - fs * 0.32),
          Offset(110 + math.min(pen.width(text, main), maxW), y - fs * 0.36),
          Paint()
            ..color = const Color(0xB38A8F98)
            ..strokeWidth = 3,
        );
      }
    }
    if (rows.length > shown.length) {
      pen.text('+${rows.length - shown.length} more', _ts(24, FontWeight.w800, grey), w - 44, h - 34, align: _Align.right);
    }
  }

  @override
  bool shouldRepaint(QueueBoardPainter old) => old.key != key;
}
