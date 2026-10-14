// What every part of the office UI can reach: the store, the socket, your settings, and the
// actions that live with the office itself (opening a worker's terminal, hiring, going to a desk).
// Windows get it with OfficeScope.of(context), or are handed it when opened.

import 'package:flutter/widgets.dart';

import 'net/office_socket.dart';

import 'package:office_shared/protocol.dart';

import 'state/store.dart';
import 'ui/settings_rows.dart' show SettingsPane;

/// Office-level actions that windows call back into. Implemented by the office controller; each
/// one is the old main.ts function of the same name.
abstract class OfficeActions {
  void openWorkerTerminal(String workerId, {({int row, String needle})? find});

  /// [repo]: another floor's repository of a worker across repositories (see WorkerInfo.repos).
  void openWorkerChanges(String workerId, [String? repo]);
  void hire(
    String deskId, {
    String? prompt,
    bool worktree = false,
    AgentProvider? provider,
    String? model,
    AgentEffort? effort,
  });
  void killWorker(String workerId);
  void resumeWorker(WorkerInfo w);
  void goToDesk(String deskId);

  /// ✋ Pick it up: the issue's card comes off the board and into your hands.
  void pickUp(GhIssue issue);

  /// A prompt from the boards to a new worker at a free desk, or to one already at a desk. With [issue], that
  /// worker takes the GitHub issue, which moves to In progress.
  void sendToWorker(String title, {String? context, String? initial, int? issue});
  void showSearch();
  void showQueue();

  /// ⚙️ Settings, on [first]'s category or the one it was last on.
  void showSettings([SettingsPane? first]);
  void showElevator();
  void editProfile();
  void ride(String floorId);
  Future<void> signOut();
}

/// The actions of a view where you aren't standing anywhere in the office (the 2D view, pages/lite_page.dart):
/// there's nobody there to carry a card or walk to a desk.
abstract interface class NotInTheOffice {}

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
