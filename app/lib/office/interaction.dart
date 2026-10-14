// Whether a desk key does anything at what's in reach (interaction.ts): a key with nothing to do there falls
// through to walking, so E, P, R, X, B, C and O never swallow a step when nothing is in front of you.

import 'package:office_shared/floorplan.dart' show canLabel;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart' show isAsleep;

import '../world/collider.dart';

/// Keys that use what you're facing: at a desk, each does something else (see the controller's _interact).
/// L hangs a sign over a desk.
enum DeskKey { e, p, r, x, b, c, o, l }

/// What's around the thing in reach: the worker at its desk, whether it's a meeting-room chair, the note on
/// the issues board you're aiming at, and whether you're carrying an issue card.
typedef InteractionState = ({WorkerInfo? worker, bool room, GhIssue? note, bool carrying});

/// Whether [key] has an action at [it], the interaction in reach now.
bool interactionAvailable(Interactable? it, DeskKey key, InteractionState state) {
  if (it == null) return false;

  // A carried issue can be handed to any desk, queued, returned/swapped, or taken into a meeting.
  if (key == DeskKey.e &&
      state.carrying &&
      (it.kind == InteractKind.desk ||
          it.kind == InteractKind.queue ||
          it.kind == InteractKind.issues ||
          it.kind == InteractKind.meeting)) {
    return it.kind != InteractKind.desk || it.deskId != null;
  }

  if (it.kind == InteractKind.desk) {
    final deskId = it.deskId;
    if (deskId == null) return false;
    // Any desk can have a sign hung over it, whoever sits there (not a bean bag or a meeting chair).
    if (key == DeskKey.l) return canLabel(deskId);
    final w = state.worker;
    if (w == null && state.room) return key == DeskKey.e;
    if (key == DeskKey.b) return w == null;
    if (key == DeskKey.p || key == DeskKey.e) return true;
    if (key == DeskKey.r) return w != null && isAsleep(w.status);
    return w != null && (key == DeskKey.c || key == DeskKey.x || key == DeskKey.o);
  }

  if (it.kind == InteractKind.station) {
    if (it.deskId == null) return false;
    return key == DeskKey.e || key == DeskKey.p || (state.worker != null && (key == DeskKey.o || key == DeskKey.x));
  }

  if (state.note != null && it.kind == InteractKind.issues) return key == DeskKey.e || key == DeskKey.o;
  if (key != DeskKey.e) return false;

  if (it.kind == InteractKind.decor) return it.decorId != null;
  if (it.kind == InteractKind.seat) return it.seatId != null;
  if (it.kind == InteractKind.pole) return it.pole != null;
  return true;
}
