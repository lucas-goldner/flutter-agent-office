// What a worker's status means, for the checks the server and the browser both make.

import 'protocol.dart';

/// Its process isn't running: it exited, or came back asleep after a restart. R wakes it.
bool isAsleep(WorkerStatus status) => status == WorkerStatus.exited || status == WorkerStatus.offline;

/// In the middle of a turn: booting, working, or waiting on an answer.
bool isBusy(WorkerStatus status) => status == WorkerStatus.starting || status == WorkerStatus.working || status == WorkerStatus.needsInput;

/// One line for a notification about a worker: what it's asking for when it needs input, or what it
/// was on when it's done (its last activity may be a permission prompt it has long got past).
String? alertDetail(WorkerInfo w) => w.status == WorkerStatus.needsInput ? (w.activity ?? w.task?.summary) : (w.task?.summary ?? w.prompt);
