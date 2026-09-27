// What every part of the office UI can reach: the store, the socket, your settings, and the
// actions that live with the office itself (opening a worker's terminal, hiring, going to a desk).
// Windows get it with OfficeScope.of(context), or are handed it when opened.

import 'package:flutter/widgets.dart';

import 'net/office_socket.dart';
import 'package:office_shared/protocol.dart';
import 'state/store.dart';

/// Office-level actions that windows call back into. Implemented by the office controller; each
/// one is the old main.ts function of the same name.
abstract class OfficeActions {
  void openWorkerTerminal(String workerId, {({int row, String needle})? find});
  void openWorkerChanges(String workerId);
  void hire(String deskId, {String? prompt, bool worktree = false, AgentProvider? provider, String? model});
  void killWorker(String workerId);
  void resumeWorker(WorkerInfo w);
  void goToDesk(String deskId);

  /// A prompt from the boards to a new worker at a free desk, or to one already at a desk.
  void sendToWorker(String title, {String? context, String? initial});
  void showSearch();
  void showQueue();
  void showSettings();
  void showElevator();
  void editProfile();
  void ride(String floorId);
  Future<void> signOut();
}

class OfficeScope extends InheritedWidget {
  const OfficeScope({
    super.key,
    required this.store,
    required this.net,
    required this.settings,
    required this.actions,
    required super.child,
  });

  final Store store;
  final OfficeSocket net;
  final Settings settings;
  final OfficeActions actions;

  static OfficeScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<OfficeScope>();
    assert(s != null, 'No OfficeScope above this widget');
    return s!;
  }

  /// Without a rebuild dependency, for callbacks.
  static OfficeScope read(BuildContext context) => context.getInheritedWidgetOfExactType<OfficeScope>()!;

  @override
  bool updateShouldNotify(OfficeScope oldWidget) =>
      store != oldWidget.store || net != oldWidget.net || actions != oldWidget.actions;
}
