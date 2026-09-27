// The tab title and the waiting-elsewhere count: the bits of main.ts that tell you someone's
// waiting on you when you can't see them (another tab, another floor).

import '../notify.dart';
import '../shared/protocol.dart';

/// Workers waiting on someone on the floors you're not on.
int waitingElsewhere(List<FloorInfo> floors, String? floor) =>
    floors.fold(0, (n, f) => n + (f.id == floor ? 0 : f.waiting));

/// The tab title counts the workers waiting on someone, on every floor, so you can see them from
/// another tab: "(2) my-app · Agent Office".
String officeTitle({
  String? project,
  required List<FloorInfo> floors,
  String? floor,
  required Iterable<WorkerInfo> workers,
}) {
  final waiting = workers.where(waitingOnSomeone).length + waitingElsewhere(floors, floor);
  return '${waiting > 0 ? '($waiting) ' : ''}${project != null ? '$project · ' : ''}Agent Office';
}

/// The project panel's second line.
String projectMeta({
  required ProjectInfo? project,
  required List<FloorInfo> floors,
  String? floor,
  required String defaultProvider,
}) {
  if (project == null) {
    return floors.isNotEmpty ? '🛗 Take the elevator to a floor' : '🛗 No floors yet — add a project in the elevator';
  }
  final n = floors.indexWhere((f) => f.id == floor);
  return [
    if (n >= 0) '🛗 floor ${n + 1} of ${floors.length}',
    if (project.branch != null && project.branch!.isNotEmpty) '⎇ ${project.branch}',
    if (project.dir.isNotEmpty) project.dir,
    'default: $defaultProvider',
  ].join(' · ');
}

/// The project panel's tooltip.
String projectTooltip(int elsewhere) => elsewhere > 0
    ? '$elsewhere worker${elsewhere == 1 ? '' : 's'} on other floors waiting on someone — click to ride the elevator'
    : 'The elevator: ride to another project';

/// Remembers how many workers were waiting on each floor, to notice when that goes up somewhere else.
class FloorWaitWatch {
  final Map<String, int> _waitingOn = {};

  /// The other floors where more workers are waiting than last time (none the first time a floor is seen).
  List<FloorInfo> update(List<FloorInfo> floors, String? floor) {
    final more = <FloorInfo>[];
    for (final f in floors) {
      final before = _waitingOn[f.id];
      _waitingOn[f.id] = f.waiting;
      if (f.id == floor) continue;
      if (before != null && f.waiting > before) more.add(f);
    }
    return more;
  }
}
