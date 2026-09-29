// How a worker's bubble shows its pull request (office_shared's workerPr): GitHub's open green, or
// the PR board's merged purple (time to send it home). From character.ts's drawBubble.

import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

/// The outline of a worker's bubble, and its pill, once it has a pull request.
const Map<WorkerPrState, String> prInk = {WorkerPrState.open: '#2da44e', WorkerPrState.merged: '#9d4edd'};
const Map<WorkerPrState, String> _prIcon = {WorkerPrState.open: '🔀', WorkerPrState.merged: '🎉'};

/// What its bubble says about its pull request while it rests ("🎉 PR #12 merged"), in place of
/// ready / done / asleep; null while it's working on or waiting for something more, or has none.
String? prLabel(WorkerPr? pr, WorkerStatus status) {
  if (pr == null ||
      status == WorkerStatus.working ||
      status == WorkerStatus.needsInput ||
      status == WorkerStatus.starting) {
    return null;
  }
  return '${_prIcon[pr.state]} PR #${pr.number} ${pr.state.name}';
}
