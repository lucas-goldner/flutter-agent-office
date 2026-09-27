import 'package:agent_office/shared/protocol.dart';
import 'package:agent_office/ui/provider.dart';
import 'package:agent_office/ui/usage.dart';
import 'package:flutter_test/flutter_test.dart';

Usage u(double cost, {int input = 1000, int output = 500, bool? costKnown, bool? incomplete, int calls = 3}) =>
    Usage.fromJson({
      'input': input,
      'output': output,
      'cacheWrite': 0,
      'cacheRead': 0,
      'cost': cost,
      'calls': calls,
      'costKnown': ?costKnown,
      'incomplete': ?incomplete,
    });

WorkerInfo w(String id, {String? provider, Usage? usage, String kind = 'agent'}) =>
    WorkerInfo.fromJson({'id': id, 'name': id, 'kind': kind, 'provider': ?provider, 'usage': ?usage?.toJson()});

final project = ProjectInfo.fromJson({
  'name': 'app',
  'dir': '/w/app',
  'agentCmd': 'claude',
  'defaultProvider': 'claude',
  'agentProviders': ['claude', 'opencode', 'codex', 'custom'],
});

void main() {
  test('formats tokens and dollars like the TS', () {
    expect(fmtTokens(999), '999');
    expect(fmtTokens(1234), '1.2k');
    expect(fmtTokens(38000), '38k');
    expect(fmtTokens(2500000), '2.50M');
    expect(fmtTokens(25000000), '25.0M');
    expect(fmtCost(0), '\$0.00');
    expect(fmtCost(0.004), '<\$0.01');
    expect(fmtCost(0.42), '\$0.42');
    expect(fmtCost(1234.5), '\$1,234.50');
    expect(fmtCost(1234567), '\$1,234,567.00');
  });

  test('labels say which provider counted what', () {
    expect(usageLabel(u(0.42)), '\$0.42 · 1.5k tokens');
    expect(usageLabel(u(0.42), AgentProvider.opencode), '\$0.42 reported · 1.5k tokens');
    expect(usageLabel(u(0.42), AgentProvider.codex), 'cost unavailable · 1.5k tokens');
    expect(usageLabel(u(0.42, incomplete: true)), 'Partial: \$0.42 · 1.5k tokens');
    expect(usageTitle(u(0.42)), startsWith('\$0.42 over 3 API calls\ninput 1.0k · output 500'));
  });

  test('provider usage states', () {
    expect(providerUsageState(null, project), ProviderUsageState.waiting);
    expect(providerUsageState(AgentProvider.custom, project), ProviderUsageState.untracked);
    expect(providerUsageState(AgentProvider.codex, project, u(1)), ProviderUsageState.tracked);
    expect(providerLabel(null, project), 'Claude Code');
  });

  test('nothing to say: the spend lines hide', () {
    final s = summarizeUsage(UsageState.fromJson(const {}), [w('a')], project);
    expect(s.visible, isFalse);
    expect(s.headCost, '');
  });

  test('today against the budget, and the current desks per provider', () {
    final state = UsageState.fromJson({
      'total': u(10).toJson(),
      'today': u(18).toJson(),
      'day': '2026-09-27',
      'budget': 20,
      'pauseHiring': true,
    });
    final s = summarizeUsage(state, [
      w('a', usage: u(1.5)),
      w('b', provider: 'opencode', usage: u(0.25)),
      w('c', provider: 'codex', usage: u(2, costKnown: true)),
      w('d', provider: 'codex'),
      w('e', provider: 'custom'),
      w('f', kind: 'shell'),
    ], project);
    expect(s.visible, isTrue);
    expect(s.over, isFalse);
    expect(s.headCost, '\$3.75');
    final fig = s.rows[0] as UsageFigure;
    expect(fig.label, '💸 Claude Code today');
    expect(fig.figure, '\$18.00');
    expect(fig.trailing, 'of \$20.00');
    final budget = s.rows[1] as UsageBudget;
    expect(budget.pct, 90);
    expect(budget.level, MeterLevel.near);
    expect(budget.title, "90% of today's budget");
    final notes = s.rows.whereType<UsageNote>().map((n) => n.text).toList();
    expect(notes, [
      'Claude Code all time \$10.00 · 1.5k tokens',
      'OpenCode current desks \$0.25 reported · 1.5k tokens',
      'Codex current desks \$2.00 · 1.5k tokens',
      'Codex metrics waiting for first report',
      'Custom usage untracked · budget and totals cover Claude Code only',
    ]);
    expect(hiringPaused(state), isFalse);
  });

  test('over budget with --budget-pause stops hiring', () {
    final state = UsageState.fromJson({
      'total': u(30).toJson(),
      'today': u(25).toJson(),
      'budget': 20,
      'pauseHiring': true,
    });
    final s = summarizeUsage(state, const [], project);
    expect(s.over, isTrue);
    expect((s.rows[1] as UsageBudget).title, 'Budget spent — no new hires until tomorrow');
    expect((s.rows[1] as UsageBudget).pct, 100);
    expect(hiringPaused(state), isTrue);
  });
}
