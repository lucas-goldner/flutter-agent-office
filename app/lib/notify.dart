// Getting your attention when the office isn't the tab you're looking at: desktop notifications
// for workers that need input or finish (the tab title counts them too, see ui/tab_title.dart).

import 'interop/notify.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart';

export 'interop/notify.dart' show NotifyApi, NotifyPermission;

/// Waiting on a person: needs input, or finished its turn and nobody has looked yet.
bool waitingOnSomeone(WorkerInfo w) =>
    w.status == WorkerStatus.needsInput || (w.status == WorkerStatus.done && !w.acked);

class DesktopNotifier {
  DesktopNotifier({required this.enabled, required this.openWorker, NotifyApi? api})
    : api = api ?? browserNotifications() {
    // Back in the office, which shows who's waiting by itself.
    this.api.onWindowFocus(_closeAll);
  }

  /// Your own on/off, from Settings.
  final bool Function() enabled;
  final void Function(String workerId) openWorker;
  final NotifyApi api;

  /// The notification up for each worker, to take down once it's handled.
  final Map<String, ShownNotification> _shown = {};

  NotifyPermission get permission => api.permission;
  Future<NotifyPermission> askPermission() => api.requestPermission();

  /// A worker just started waiting on input, or finished its turn.
  void alert(WorkerInfo w) {
    if (!waitingOnSomeone(w)) return;
    if (!enabled() || api.permission != NotifyPermission.granted) return;
    if (api.pageFocused) return;
    final title = '${w.name} ${w.status == WorkerStatus.done ? 'is done' : 'needs input'}';
    final body = [w.task?.name, alertDetail(w)].where((s) => s != null && s.isNotEmpty).join('\n');
    _shown[w.id]?.close();
    // Needs input blocks the worker, so that one stays up until you deal with it.
    final n = api.show(
      title,
      body: body,
      tag: 'worker-${w.id}',
      requireInteraction: w.status == WorkerStatus.needsInput,
    );
    if (n == null) return;
    n.onClick = () {
      api.focusWindow();
      n.close();
      openWorker(w.id);
    };
    n.onClose = () {
      if (identical(_shown[w.id], n)) _shown.remove(w.id);
    };
    _shown[w.id] = n;
  }

  /// Takes down notifications for workers nobody needs to get to any more (someone else did).
  void sync(Map<String, WorkerInfo> workers) {
    for (final id in _shown.keys.toList()) {
      final w = workers[id];
      if (w != null && waitingOnSomeone(w)) continue;
      _shown.remove(id)?.close();
    }
  }

  /// What one looks like, from ⚙️ Settings.
  void sample() {
    final n = api.show(
      '🔔 Notifications are on',
      body: 'This is how a worker that needs input or is done gets your attention while you are in another tab.',
    );
    if (n == null) return;
    n.onClick = () {
      api.focusWindow();
      n.close();
    };
  }

  void _closeAll() {
    for (final n in _shown.values.toList()) {
      n.close();
    }
    _shown.clear();
  }
}
