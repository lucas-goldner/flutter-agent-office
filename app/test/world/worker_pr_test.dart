import 'package:agent_office/world/worker_pr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

void main() {
  test('the bubble names the pull request only while the worker rests', () {
    const open = (state: WorkerPrState.open, number: 12);
    const merged = (state: WorkerPrState.merged, number: 7);
    expect(prLabel(open, WorkerStatus.idle), '🔀 PR #12 open');
    expect(prLabel(merged, WorkerStatus.done), '🎉 PR #7 merged');
    expect(prLabel(merged, WorkerStatus.offline), '🎉 PR #7 merged');
    expect(prLabel(open, WorkerStatus.working), isNull);
    expect(prLabel(open, WorkerStatus.needsInput), isNull);
    expect(prLabel(open, WorkerStatus.starting), isNull);
    expect(prLabel(null, WorkerStatus.idle), isNull);
    expect(prInk[WorkerPrState.merged], '#9d4edd');
  });
}
