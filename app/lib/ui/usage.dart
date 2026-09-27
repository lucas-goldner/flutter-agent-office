// What the workers spend: the labels on each worker and the spend lines under the Workers panel
// (a port of ui/usage.ts). The numbers are worked out here, apart from the widgets, to test them.

import 'package:flutter/material.dart';

import 'package:office_shared/protocol.dart';
import 'provider.dart';
import 'theme.dart';

int tokensOf(Usage u) => u.totalTokens ?? (u.input + u.output + (u.reasoning ?? 0) + u.cacheWrite + u.cacheRead);

/// JS `toFixed`, near enough for display.
String _fixed(double v, int digits) => v.toStringAsFixed(digits);

String fmtTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1e6) return '${_fixed(n / 1000, n < 10000 ? 1 : 0)}k';
  return '${_fixed(n / 1e6, n < 10e6 ? 2 : 1)}M';
}

/// "$1,234.50", the way en-US toLocaleString writes dollars.
String fmtCost(double usd) {
  if (usd > 0 && usd < 0.005) return '<\$0.01';
  final s = usd.abs().toStringAsFixed(2);
  final dot = s.indexOf('.');
  final whole = s.substring(0, dot);
  final b = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) b.write(',');
    b.write(whole[i]);
  }
  return '${usd < 0 ? '-' : ''}\$$b${s.substring(dot)}';
}

String _displayedCost(Usage u) => u.costKnown == false ? 'cost unavailable' : fmtCost(u.cost);

/// e.g. "$0.42 · 38k tokens"; OpenCode's amount is explicitly an estimate.
String usageLabel(Usage u, [AgentProvider provider = AgentProvider.claude]) {
  final money = provider == AgentProvider.codex && u.costKnown != true
      ? 'cost unavailable'
      : u.costKnown == false
      ? 'cost unavailable'
      : '${fmtCost(u.cost)}${provider == AgentProvider.opencode ? ' reported' : ''}';
  return '${u.incomplete == true ? 'Partial: ' : ''}$money · ${fmtTokens(tokensOf(u))} tokens';
}

/// The breakdown behind a figure, for a tooltip.
String usageTitle(Usage u, [AgentProvider provider = AgentProvider.claude]) {
  final money = provider == AgentProvider.codex && u.costKnown != true
      ? 'cost unavailable'
      : u.costKnown == false
      ? 'cost unavailable'
      : fmtCost(u.cost);
  final calls = provider == AgentProvider.codex || u.callsKnown == false
      ? 'API call count unavailable'
      : provider == AgentProvider.opencode
      ? '${u.calls} reported call${u.calls == 1 ? '' : 's'}'
      : '${u.calls} API call${u.calls == 1 ? '' : 's'}';
  return [
    if (u.incomplete == true) 'Partial metrics: some session history is still loading or unavailable.',
    provider == AgentProvider.codex
        ? 'Codex root-session metrics; subagent usage is not included; $money; $calls'
        : provider == AgentProvider.opencode
        ? 'OpenCode reported estimate $money; model/provider estimate, not billing; $calls'
        : '$money over $calls',
    'input ${fmtTokens(u.input)} · output ${fmtTokens(u.output)}',
    'reasoning ${fmtTokens(u.reasoning ?? 0)}',
    'cache write ${fmtTokens(u.cacheWrite)} · cache read ${fmtTokens(u.cacheRead)}',
  ].join('\n');
}

bool overBudget(UsageState s) => s.budget != null && s.today.cost >= s.budget!;

/// New hires are refused: the daily budget is spent and the office runs with --budget-pause.
bool hiringPaused(UsageState s) => s.pauseHiring && overBudget(s);

// ---- The spend lines ---------------------------------------------------------------------------

sealed class UsageRow {
  const UsageRow();
}

/// "💸 Claude Code today **$1.20** of $20.00"
class UsageFigure extends UsageRow {
  const UsageFigure(this.label, this.figure, this.figureTitle, this.trailing);
  final String label;
  final String figure;
  final String figureTitle;
  final String trailing;
}

/// Today's spend against the budget.
class UsageBudget extends UsageRow {
  const UsageBudget(this.pct, this.level, this.title);
  final double pct;
  final MeterLevel level;
  final String title;
}

/// A muted line that wraps.
class UsageNote extends UsageRow {
  const UsageNote(this.text, this.title);
  final String text;
  final String? title;
}

enum MeterLevel { ok, near, over }

class UsageSummary {
  const UsageSummary({required this.headCost, required this.visible, required this.over, required this.rows});

  /// What the workers at their desks cost right now, for the panel's heading ('' for nothing).
  final String headCost;
  final bool visible;
  final bool over;
  final List<UsageRow> rows;

  static const headTitle =
      'Current desks: tracked Claude Code costs plus reported OpenCode estimates; Codex root-session tokens appear below; sessions with unavailable cost or partial history are excluded.';
}

/// Sums one provider's current desks.
class _Tally {
  double cost = 0;
  int tokens = 0, input = 0, output = 0, reasoning = 0, cacheWrite = 0, cacheRead = 0, reports = 0;
  bool costUnknown = false, incomplete = false, waiting = false;

  void add(Usage u, {required bool costKnown}) {
    reports++;
    if (u.incomplete == true) incomplete = true;
    tokens += tokensOf(u);
    input += u.input;
    output += u.output;
    reasoning += u.reasoning ?? 0;
    cacheWrite += u.cacheWrite;
    cacheRead += u.cacheRead;
    if (!costKnown) {
      costUnknown = true;
    } else {
      cost += u.cost;
    }
  }

  String breakdown(String first) => [
    first,
    'input ${fmtTokens(input)} · output ${fmtTokens(output)}',
    'reasoning ${fmtTokens(reasoning)}',
    'cache write ${fmtTokens(cacheWrite)} · cache read ${fmtTokens(cacheRead)}',
  ].join('\n');
}

/// The sidebar's spend lines: what the workers at their desks cost, today's total and the budget.
UsageSummary summarizeUsage(UsageState s, Iterable<WorkerInfo> workers, ProjectInfo? project) {
  var now = 0.0;
  final openCode = _Tally();
  final codex = _Tally();
  var untracked = false;
  for (final w in workers) {
    if (w.kind != WorkerKind.agent) continue;
    final provider = resolvedProvider(w.provider, project);
    final state = providerUsageState(provider, project, w.usage);
    if (state == ProviderUsageState.untracked) untracked = true;
    final u = w.usage;
    if (provider == AgentProvider.opencode) {
      if (u == null) {
        openCode.waiting = true;
        continue;
      }
      openCode.add(u, costKnown: u.costKnown != false);
    }
    if (provider == AgentProvider.codex) {
      if (u == null) {
        codex.waiting = true;
        continue;
      }
      codex.add(u, costKnown: u.costKnown == true);
    }
    if (providerUsageTracked(provider, project, u) && u?.costKnown != false && u?.incomplete != true) {
      now += u?.cost ?? 0;
    }
  }
  final head = now > 0 ? fmtCost(now) : '';
  final claude = s.total.calls > 0 || s.budget != null;
  final any = claude || untracked || openCode.reports > 0 || openCode.waiting || codex.reports > 0 || codex.waiting;
  if (!any) return UsageSummary(headCost: head, visible: false, over: false, rows: const []);
  final over = overBudget(s);
  final rows = <UsageRow>[];
  if (claude) {
    rows.add(
      UsageFigure(
        '💸 Claude Code today',
        _displayedCost(s.today),
        usageTitle(s.today),
        s.budget != null ? 'of ${fmtCost(s.budget!)}' : '· ${fmtTokens(tokensOf(s.today))} tokens',
      ),
    );
  }
  if (s.budget != null) {
    final pct = (s.today.cost / s.budget! * 100).clamp(0, 100).toDouble();
    final state = over
        ? (s.pauseHiring ? 'Budget spent — no new hires until tomorrow' : 'Budget spent')
        : "${pct.round()}% of today's budget";
    rows.add(
      UsageBudget(
        pct,
        over
            ? MeterLevel.over
            : pct >= 80
            ? MeterLevel.near
            : MeterLevel.ok,
        state,
      ),
    );
  }
  if (claude) {
    rows.add(
      UsageNote(
        'Claude Code all time ${_displayedCost(s.total)} · ${fmtTokens(tokensOf(s.total))} tokens',
        usageTitle(s.total),
      ),
    );
  }
  if (openCode.reports > 0) {
    final amount = openCode.costUnknown ? 'cost unavailable' : '${fmtCost(openCode.cost)} reported';
    rows.add(
      UsageNote(
        'OpenCode ${openCode.incomplete ? 'partial' : 'current desks'} $amount · ${fmtTokens(openCode.tokens)} tokens',
        openCode.breakdown('OpenCode current-desk metrics are model/provider estimates, not billing.'),
      ),
    );
  }
  if (openCode.waiting) {
    rows.add(
      const UsageNote(
        'OpenCode metrics waiting for first report',
        'OpenCode usage appears after its first metrics report.',
      ),
    );
  }
  if (codex.reports > 0) {
    final amount = codex.costUnknown ? 'cost unavailable' : fmtCost(codex.cost);
    rows.add(
      UsageNote(
        'Codex ${codex.incomplete ? 'partial' : 'current desks'} $amount · ${fmtTokens(codex.tokens)} tokens',
        codex.breakdown(
          'Codex current-desk metrics cover the root session only; subagent usage is not included; cost is unavailable.',
        ),
      ),
    );
  }
  if (codex.waiting) {
    rows.add(
      const UsageNote(
        'Codex metrics waiting for first report',
        'Codex usage appears after its first root-session metrics report; subagent usage is not included.',
      ),
    );
  }
  if (untracked) {
    rows.add(
      const UsageNote(
        'Custom usage untracked · budget and totals cover Claude Code only',
        'Custom provider usage is not reported by the office.',
      ),
    );
  }
  return UsageSummary(headCost: head, visible: true, over: over, rows: rows);
}

// ---- Widgets -----------------------------------------------------------------------------------

/// The .budget / .meter: a 10px pill with a fill that turns yellow when near, red when over.
class Meter extends StatelessWidget {
  const Meter({super.key, required this.pct, this.level = MeterLevel.ok, this.tooltip});

  final double pct;
  final MeterLevel level;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget m = Container(
      height: 10,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Swatch.ink, width: 2),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedFractionallySizedBox(
          duration: const Duration(milliseconds: 300),
          widthFactor: (pct / 100).clamp(0, 1),
          heightFactor: 1,
          child: ColoredBox(
            color: switch (level) {
              MeterLevel.ok => Swatch.good,
              MeterLevel.near => Swatch.warn,
              MeterLevel.over => Swatch.bad,
            },
          ),
        ),
      ),
    );
    if (tooltip != null) m = Tooltip(message: tooltip!, child: m);
    return m;
  }
}

const _tabular = [FontFeature.tabularFigures()];

/// The spend lines under the workers (.usage): a dashed rule, then the rows.
class UsagePanel extends StatelessWidget {
  const UsagePanel(this.summary, {super.key});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    if (!summary.visible) return const SizedBox.shrink();
    final base = heavy(12, weight: FontWeight.w700);
    final muted = heavy(12, color: Swatch.muted, weight: FontWeight.w600);
    Widget row(UsageRow r) => switch (r) {
      UsageFigure f => Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${f.label} '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Tooltip(
                message: f.figureTitle,
                child: Text(
                  f.figure,
                  style: heavy(
                    12,
                    weight: FontWeight.w900,
                    color: summary.over ? Swatch.bad : Swatch.ink,
                  ).copyWith(fontFeatures: _tabular),
                ),
              ),
            ),
            TextSpan(text: ' ${f.trailing}', style: muted),
          ],
        ),
        style: base,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      UsageBudget b => Meter(pct: b.pct, level: b.level, tooltip: b.title),
      UsageNote n =>
        n.title == null
            ? Text(n.text, style: muted)
            : Tooltip(
                message: n.title!,
                child: Text(n.text, style: muted),
              ),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(top: 8),
      decoration: const BoxDecoration(border: _DashedTop()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in summary.rows.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 5),
              child: row(r),
            ),
        ],
      ),
    );
  }
}

/// border-top: 2px dashed rgba(43,45,66,.25).
class _DashedTop extends BoxBorder {
  const _DashedTop();

  static const _color = Color(0x402B2D42);

  @override
  BorderSide get top => const BorderSide(color: _color, width: 2);
  @override
  BorderSide get bottom => BorderSide.none;
  @override
  bool get isUniform => false;
  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only(top: 2);
  @override
  ShapeBorder scale(double t) => this;

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) {
    final p = Paint()
      ..color = _color
      ..strokeWidth = 2;
    for (var x = rect.left; x < rect.right; x += 10) {
      canvas.drawLine(Offset(x, rect.top + 1), Offset((x + 6).clamp(rect.left, rect.right), rect.top + 1), p);
    }
  }
}
