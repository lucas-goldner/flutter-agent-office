// A stand-in for the WorkerHandle the worker manager gives a provider adapter.
import 'package:agent_office_server/src/providers/providers.dart';
import 'package:agent_office_server/src/usage.dart';
import 'package:office_shared/shared.dart';

/// A worker as an adapter sees it, recording what the adapter does with it.
class FakeHandle implements WorkerHandle {
  FakeHandle(this.info, this.state);

  @override
  final LiveInfo info;
  @override
  final Object? state;
  @override
  bool running = true;
  @override
  bool bootBlocked = false;
  @override
  int leftNeedsInputAt = 0;
  @override
  int failStreak = 0;
  @override
  final UsageTracker tracker = newTracker();
  @override
  String? pendingPrompt;
  final prompts = <String>[];
  final statuses = <WorkerStatus>[];
  var emits = 0;
  @override
  void setStatus(WorkerStatus status) {
    if (info.status == status) return;
    info.status = status;
    statuses.add(status);
  }

  @override
  void emit() => emits++;
  @override
  void persist() {}
  @override
  void notePrompt(String prompt) {}
  @override
  void noteTool(String tool) {}
  @override
  void clearTask() {}
  @override
  void scheduleScan() {}
  @override
  String? prompt(String text) {
    prompts.add(text);
    return null;
  }
}

LiveInfo liveInfo(AgentProvider provider, {String? model, AgentEffort? effort, String? sessionId}) => LiveInfo(
  id: 'w1',
  kind: WorkerKind.agent,
  provider: provider,
  model: model,
  effort: effort,
  deskId: 'd1',
  name: 'Pixel',
  color: '#fff',
  status: WorkerStatus.starting,
  createdBy: 'ann',
  createdAt: 0,
  sessionId: sessionId,
);

FakeHandle handleFor(AgentProvider provider, {String? model, AgentEffort? effort, String? sessionId}) => FakeHandle(
  liveInfo(provider, model: model, effort: effort, sessionId: sessionId),
  providerAdapter(provider)!.createState(),
);
