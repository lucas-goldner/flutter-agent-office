// Carrying an issue card from the board to a desk (see OfficeController's "Carrying an issue
// card"): the rules that don't need the scene, apart so they're tested on the VM.

import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

import '../ui/gh_logic.dart' show issuePrompt;

/// Why the worker at a desk can't be handed an issue card right now, or '' when it can.
String cantTakeCard(WorkerInfo w) {
  if (w.kind == WorkerKind.shell) return '${w.name} is a shell, not an agent';
  if (isAsleep(w.status)) return '${w.name} is asleep — press R to resume first';
  if (w.status == WorkerStatus.needsInput) return '${w.name} is waiting on an answer — open the terminal first';
  return '';
}

/// The task a worker gets for a carried card: the one 🤖 Hand to a worker gives ([known] is the
/// issue as the board has it, when it does).
String cardPrompt(CarriedIssue card, [GhIssue? known]) => issuePrompt(
  known ??
      GhIssue(
        number: card.issue,
        title: card.title,
        state: 'OPEN',
        url: '',
        author: '',
        labels: const [],
        assignees: const [],
        createdAt: '',
        updatedAt: '',
        body: '',
        comments: 0,
      ),
);
