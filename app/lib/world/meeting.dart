// The meeting room's board and door sign (world/meeting.ts): the meeting's output file as it's being
// written, and a room-booking panel saying what's on, the round, who has the floor and the tokens.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:office_shared/meetings.dart';
import 'package:office_shared/protocol.dart';

import '../ui/screen_paint.dart';

const _ink = '#2b2d42';
const double boardWidth = 1500, boardHeight = 500;
const double signWidth = 500, signHeight = 800;

/// Who has the floor right now: the roles on the parts being worked on.
List<String> speaking(Meeting m) => [
  for (final t in m.turns)
    if (t.state != MeetingTurnState.done) t.seat >= 0 && t.seat < m.seats.length ? m.seats[t.seat].role : '?',
];

/// What's on the table in a line: "Round 2 of 3 · critiquing".
String meetingStage(Meeting m) {
  final doing = {
    for (final t in m.turns)
      if (t.state != MeetingTurnState.done) t.doing,
  }.join(', ');
  return 'Round ${m.round} of ${m.rounds}${doing.isNotEmpty ? ' · $doing' : ''}';
}

/// Breaks [text] into lines no wider than [maxW] in [style], cutting words too long for a line of their own.
List<String> wrapText(Pen g, String text, double maxW, TextStyle style) {
  final lines = <String>[];
  var cur = '';
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    if (cur.isNotEmpty && g.measure('$cur $word', style) > maxW) {
      lines.add(cur);
      cur = word;
    } else {
      cur = cur.isNotEmpty ? '$cur $word' : word;
    }
    while (g.measure(cur, style) > maxW && cur.length > 1) {
      var cut = cur.length - 1;
      while (cut > 1 && g.measure(cur.substring(0, cut), style) > maxW) {
        cut--;
      }
      lines.add(cur.substring(0, cut));
      cur = cur.substring(cut);
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  return lines;
}

/// The board on the back wall, 1500×500: the output file as it's being written, like a shared screen.
void paintMeetingBoard(Canvas canvas, MeetingState state) {
  final g = Pen(canvas);
  const w = boardWidth, h = boardHeight;
  g.rect(0, 0, w, h, css('#fbfdff'));
  final m = state.current;
  if (m == null) {
    g.text('🤝 The meeting room is free', w / 2, h / 2 - 30, g.style(64, weight: FontWeight.w900, color: css(_ink)));
    g.text(
      'Press E at the table to call a meeting: whatever it writes shows up here.',
      w / 2,
      h / 2 + 40,
      g.style(36, weight: FontWeight.w700, color: css('#5c5f73')),
    );
    return;
  }
  final p = meetingPatterns[m.pattern]!;
  // Across the top: the file, and where the meeting is.
  g.rect(
    0,
    0,
    w,
    70,
    css(switch (m.status) {
      MeetingStatus.stopped => '#ffd6e0',
      MeetingStatus.done => '#caffbf',
      _ => '#e7f5ff',
    }),
  );
  final ink = css(_ink);
  g.text(
    '📄 ${m.output}',
    24,
    35,
    g.style(34, weight: FontWeight.w800, color: ink),
    align: TextAlignX.left,
  );
  final where = switch (m.status) {
    MeetingStatus.running => meetingStage(m),
    MeetingStatus.done => '✅ done',
    _ => '⛔ stopped',
  };
  g.text(
    '${p.icon} ${p.label} · $where',
    w - 24,
    35,
    g.style(34, weight: FontWeight.w800, color: ink),
    align: TextAlignX.right,
  );

  final text = (m.preview ?? '').replaceAll('\r', '');
  if (text.trim().isEmpty) {
    final who = speaking(m);
    final says = m.status == MeetingStatus.running
        ? "Nothing written yet: ${who.isNotEmpty ? who.join(', ') : 'the table'} ${who.length == 1 ? 'is' : 'are'} on it"
        : m.reason != null
        ? '⛔ ${m.reason}'
        : 'Nothing was written';
    g.text(says, w / 2, h / 2 + 20, g.style(44, weight: FontWeight.w800, color: css('#8d99ae')));
    return;
  }
  // The file, markdown-ish: headings bold and bigger, the rest as it is. Only what fits: its start.
  var y = 100.0;
  const x = 30.0, maxW = w - 60;
  final headRe = RegExp(r'^(#{1,6})\s+(.*)$');
  for (final raw in text.split('\n')) {
    if (y > h - 30) break;
    final heading = headRe.firstMatch(raw);
    final line = heading != null
        ? heading[2]!
        : raw
              .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (mm) => mm[1]!)
              .replaceAllMapped(RegExp('`([^`]*)`'), (mm) => mm[1]!);
    final size = heading != null ? (heading[1]!.length == 1 ? 44.0 : 36.0) : 28.0;
    final style = g.style(
      size,
      weight: heading != null ? FontWeight.w900 : FontWeight.w600,
      color: css(heading != null ? _ink : '#3d405b'),
    );
    if (line.trim().isEmpty) {
      y += size * 0.5;
      continue;
    }
    for (final l in wrapText(g, line, maxW, style)) {
      if (y > h - 30) break;
      g.text(l, x, y + size / 2, style, align: TextAlignX.left);
      y += size * 1.25;
    }
  }
}

/// The panel by the door, 500×800: what's on, the round, who has the floor and the tokens against the
/// budget; once it's over, its one-line summary.
void paintMeetingSign(Canvas canvas, MeetingState state) {
  final g = Pen(canvas);
  const w = signWidth, h = signHeight, pad = 28.0;
  final m = state.current;
  double lines(String text, TextStyle style, double y, int max, double lh) {
    for (final l in wrapText(g, text, w - 2 * pad, style).take(max)) {
      g.text(l, pad, y, style, align: TextAlignX.left);
      y += lh;
    }
    return y;
  }

  g.rect(
    0,
    0,
    w,
    h,
    css(
      m == null
          ? '#2b2d42'
          : switch (m.status) {
              MeetingStatus.running => '#1d3557',
              MeetingStatus.done => '#1b4332',
              _ => '#6a040f',
            },
    ),
  );
  // A strip across the top says whether the room is taken.
  final (strip, label) = m == null
      ? ('#06d6a0', '● FREE')
      : switch (m.status) {
          MeetingStatus.running => ('#ffd166', '● IN A MEETING'),
          MeetingStatus.done => ('#9ef01a', '✅ DONE'),
          _ => ('#ffb3c1', '⛔ STOPPED'),
        };
  g.rect(0, 0, w, 78, css(strip));
  g.text(
    label,
    pad,
    40,
    g.style(38, weight: FontWeight.w900, color: css(_ink)),
    align: TextAlignX.left,
  );
  final paper = css('#fffaf3'), light = css('#e9ecef');
  if (m == null) {
    final y = lines('🤝 Meeting room', g.style(50, weight: FontWeight.w900, color: paper), 150, 2, 58);
    lines(
      'Press E at the table to call a meeting: a debate, lead & team, map-reduce, red / blue or a review panel.',
      g.style(32, weight: FontWeight.w700, color: light),
      y + 30,
      8,
      42,
    );
    return;
  }
  final p = meetingPatterns[m.pattern]!;
  var y = lines('${p.icon} ${p.label}', g.style(34, weight: FontWeight.w800, color: css('#ffd166')), 120, 1, 40);
  y = lines(m.title, g.style(44, weight: FontWeight.w900, color: paper), y + 16, 3, 50);
  y += 18;
  if (m.status == MeetingStatus.running) {
    y = lines(meetingStage(m), g.style(32, weight: FontWeight.w800, color: light), y, 3, 40);
    final who = speaking(m);
    if (who.isNotEmpty)
      lines('💬 ${who.join(', ')}', g.style(30, weight: FontWeight.w700, color: css('#bde0fe')), y + 8, 3, 38);
    // The budget, as a bar that fills up, and what's been spent.
    final f = math.min(1.0, m.tokens / math.max(1, m.budget));
    const barY = h - 118;
    g.rect(pad, barY, w - 2 * pad, 20, css('rgba(255, 255, 255, 0.18)'));
    g.rect(
      pad,
      barY,
      (w - 2 * pad) * f,
      20,
      css(
        f > 0.9
            ? '#ef476f'
            : f > 0.7
            ? '#ffd166'
            : '#06d6a0',
      ),
    );
    g.text(
      '${fmtTokens(m.tokens)} of ${fmtTokens(m.budget)} tokens',
      pad,
      h - 70,
      g.style(30, weight: FontWeight.w800, color: paper),
      align: TextAlignX.left,
    );
    if (m.cost > 0) {
      g.text(
        '${fmtCost(m.cost)}${m.costKnown ? '' : '+'} so far',
        pad,
        h - 32,
        g.style(28, weight: FontWeight.w700, color: light),
        align: TextAlignX.left,
      );
    }
  } else {
    // The summary line after the pattern, which is up top already.
    lines(
      meetingSummary(m).split(' · ').skip(1).join(' · '),
      g.style(30, weight: FontWeight.w700, color: light),
      y,
      ((h - y) / 38).floor(),
      38,
    );
  }
}
