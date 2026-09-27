// The queue window's words (see queue.dart), apart so they are tested on the VM.

import 'package:office_shared/protocol.dart';
import 'modal.dart' show timeAgo;
import 'provider.dart';
import 'worker_text.dart';

String taskOutcome(QueueTask t) => switch (t.outcome) {
  TaskOutcome.done => t.pr != null ? 'finished' : 'finished, no PR found yet',
  TaskOutcome.exited => t.error != null ? 'stopped: ${t.error}' : 'stopped before finishing',
  TaskOutcome.killed => 'sent home',
  TaskOutcome.failed => "couldn't start: ${t.error ?? 'unknown error'}",
  null => '',
};

/// The task's name, with its issue number in front when it came from one.
String taskTitleText(QueueTask t) {
  if (t.issue == null) return t.title;
  return t.title.startsWith('#${t.issue}') ? t.title : '#${t.issue} ${t.title}';
}

String _usageSuffix(AgentProvider? provider, Usage? usage, ProjectInfo? project) {
  final state = providerUsageState(provider, project, usage);
  final resolved = resolvedProvider(provider, project);
  if (state == ProviderUsageState.untracked) return ' · usage untracked';
  if (state == ProviderUsageState.waiting && resolved == AgentProvider.opencode) return ' · waiting for metrics';
  if (state == ProviderUsageState.waiting && resolved == AgentProvider.codex) return ' · waiting for first report';
  return '';
}

/// The grey line under a task: provider, who, where, when.
String taskMeta(QueueTask t, {WorkerInfo? w, ProjectInfo? project}) {
  final meta = <String>[];
  final model = t.model != null ? ' · initial: ${t.model}' : '';
  switch (t.status) {
    case TaskStatus.running:
      final p = t.provider ?? w?.provider;
      meta.add('⚙️ ${providerLabel(p, project)}$model${_usageSuffix(p, w?.usage, project)}');
      meta.add('${t.workerName ?? 'a worker'} · ${w != null ? statusLabel(w.status) : 'gone'}');
      if (t.branch != null) meta.add('🌿 ${t.branch}');
      if (t.startedAt != null) meta.add('started ${timeAgo(t.startedAt!)}');
      meta.add('by ${t.addedBy}');
    case TaskStatus.queued:
      meta.add('⚙️ ${providerLabel(t.provider, project)}$model${_usageSuffix(t.provider, w?.usage, project)}');
      meta.add('added by ${t.addedBy} ${timeAgo(t.addedAt)}');
    case TaskStatus.done:
      meta.add('⚙️ ${providerLabel(t.provider, project)}$model${_usageSuffix(t.provider, w?.usage, project)}');
      meta.add(taskOutcome(t));
      if (t.workerName != null) meta.add(t.workerName!);
      if (t.branch != null) meta.add('🌿 ${t.branch}');
      if (t.finishedAt != null) meta.add(timeAgo(t.finishedAt!));
  }
  return meta.join(' · ');
}

/// The PR button of a finished task, e.g. "🔀 PR #61 ✓".
String taskPrLabel(QueueTaskPr pr) =>
    '🔀 PR #${pr.number}${pr.state == 'MERGED'
        ? ' ✓'
        : pr.state == 'DRAFT'
        ? ' (draft)'
        : ''}';
