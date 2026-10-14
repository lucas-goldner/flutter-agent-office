// What the office's machine says (see MachineState), for the hire dialogs, the queue and the monitor
// on the wall. Ported from src/shared/machine.ts.

import 'protocol.dart';

/// The office has as many workers as it takes.
bool officeFull(MachineState s) => s.limit != null && s.workers >= s.limit!;

/// What the hire dialog says while the machine is under pressure.
String? pressureNote(MachineState s) => s.pressure != null
    ? '⚠️ This machine is under pressure: ${s.pressure}. Another worker may slow down the ones already working.'
    : null;
