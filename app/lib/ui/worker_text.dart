// Words and pills for a worker: its status (STATUS_LABEL and .pill from dom.ts / style.css) and its
// reported usage (the formatting half of usage.ts). Pure, so the windows' tests can use it.

import 'package:flutter/material.dart';

import 'package:office_shared/protocol.dart';
import 'provider.dart';
import 'theme.dart';

const Map<WorkerStatus, String> kStatusLabel = {
  WorkerStatus.starting: 'starting',
  WorkerStatus.idle: 'ready',
  WorkerStatus.working: 'working',
  WorkerStatus.needsInput: 'needs input',
  WorkerStatus.done: 'done',
  WorkerStatus.exited: 'exited',
  WorkerStatus.offline: 'asleep',
};

String statusLabel(WorkerStatus s) => kStatusLabel[s] ?? s.wire;

/// The `.pill.<status>` colours: background and text.
(Color, Color) statusPillColors(WorkerStatus s) => switch (s) {
  WorkerStatus.starting || WorkerStatus.idle => (const Color(0xFFE0F2FE), Swatch.ink),
  WorkerStatus.working => (Swatch.warn, Swatch.ink),
  WorkerStatus.needsInput => (Swatch.bad, Colors.white),
  WorkerStatus.done => (Swatch.good, Colors.white),
  WorkerStatus.exited || WorkerStatus.offline => (const Color(0xFFDEE2E6), Swatch.ink),
};

/// A worker's status pill; it pulses while the worker needs input.
class StatusPill extends StatefulWidget {
  const StatusPill(this.status, {super.key});

  final WorkerStatus status;

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusPill old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.status == WorkerStatus.needsInput) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = statusPillColors(widget.status);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // @keyframes pulse { 50% { transform: scale(1.08) } }
        final t = _pulse.value;
        return Transform.scale(scale: 1 + 0.08 * (1 - (2 * t - 1).abs()), child: child);
      },
      child: Pill(statusLabel(widget.status), color: bg, textColor: fg),
    );
  }
}

// ---- Usage (from usage.ts) --------------------------------------------------------------------

int tokensOf(Usage u) => u.totalTokens ?? (u.input + u.output + (u.reasoning ?? 0) + u.cacheWrite + u.cacheRead);

String fmtTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1e6) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1e6).toStringAsFixed(n < 10e6 ? 2 : 1)}M';
}

String fmtCost(double usd) {
  if (usd > 0 && usd < 0.005) return r'<$0.01';
  final fixed = usd.toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final whole = fixed.substring(0, dot).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '\$$whole${fixed.substring(dot)}';
}

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

/// The terminal header's cost: the usage, or why there is none yet.
String workerCostText(WorkerInfo w, ProjectInfo? project) {
  if (w.kind != WorkerKind.agent) return '';
  final provider = resolvedProvider(w.provider, project);
  final state = providerUsageState(w.provider, project, w.usage);
  if (state == ProviderUsageState.tracked && w.usage != null) return usageLabel(w.usage!, provider);
  if (provider == AgentProvider.opencode && state == ProviderUsageState.waiting) return 'waiting for metrics';
  if (provider == AgentProvider.codex && state == ProviderUsageState.waiting) return 'waiting for first report';
  if (state == ProviderUsageState.untracked) return 'usage untracked';
  return '';
}

String workerCostTitle(WorkerInfo w, ProjectInfo? project) {
  if (w.kind != WorkerKind.agent) return '';
  final provider = resolvedProvider(w.provider, project);
  return w.usage != null ? usageTitle(w.usage!, provider) : providerUsageNote(provider);
}

/// '#rrggbb' as a colour (grey when it isn't one).
Color hexColor(String hex) {
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 3 ? h.split('').map((c) => '$c$c').join() : h, radix: 16);
  return v == null || (h.length != 6 && h.length != 3) ? const Color(0xFF888888) : Color(0xFF000000 | v);
}
