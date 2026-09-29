// The office's worker limit and how busy its machine is, as the windows word it (the text parts of
// world/machine.ts and ui/settings.ts, #92): the hire dialog's warning, the queue's "office full"
// and ⚙️ Settings' worker limit.

import 'package:office_shared/protocol.dart';

/// Whether the office has as many workers as it takes.
bool officeFull(MachineState s) => s.limit != null && s.workers >= s.limit!;

/// What the hire dialog says while the machine is under pressure.
String? pressureNote(MachineState s) => s.pressure == null
    ? null
    : '⚠️ This machine is under pressure: ${s.pressure}. Another worker may slow down the ones already working.';

/// The queue's note while it waits for room under the limit.
String? queueFullNote(MachineState s, int queued) {
  if (queued == 0 || !officeFull(s)) return null;
  final n = s.limit!;
  return "⏸ The office is at its limit of $n worker${n == 1 ? '' : 's'}, so the next task waits until one goes home. A queue worker that's finished goes home by itself to make room.";
}

/// ⚙️ Settings' note under the worker limit.
String limitNote(MachineState m, {required bool admin, String Function(int at)? ago}) {
  final now = m.limit == null
      ? 'No limit: the office hires a worker for every free seat. ${m.workers} ${m.workers == 1 ? 'is' : 'are'} here now, across every floor.'
      : 'At most ${m.limit} worker${m.limit == 1 ? '' : 's'} at once, across every floor (${m.workers} now), shells and board agents too. Hiring past that is refused.';
  final set = m.set;
  final from = set != null ? ' Set by ${set.by}${ago != null ? ' ${ago(set.at)}' : ''}.' : '';
  final cap = m.ceiling != null
      ? " The office was started with --max-workers ${m.ceiling}, so it can't go any higher."
      : '';
  return '$now$from$cap${admin ? '' : ' Admins can change it.'}';
}

/// A limit typed into Settings: a whole number from 1, or null for anything else.
int? parseLimit(String text) {
  final n = int.tryParse(text.trim());
  return n != null && n >= 1 ? n : null;
}
