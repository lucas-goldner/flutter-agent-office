import 'package:agent_office/interop/notify.dart';
import 'package:agent_office/notify.dart';
import 'package:agent_office/shared/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeShown implements ShownNotification {
  FakeShown(this.title, this.body, this.tag, this.sticky);
  final String title;
  final String? body;
  final String? tag;
  final bool sticky;
  void Function()? click;
  void Function()? closed;
  bool isClosed = false;
  @override
  set onClick(void Function()? fn) => click = fn;
  @override
  set onClose(void Function()? fn) => closed = fn;
  @override
  void close() {
    if (isClosed) return;
    isClosed = true;
    closed?.call();
  }
}

class FakeApi implements NotifyApi {
  NotifyPermission perm = NotifyPermission.granted;
  bool focused = false;
  int focusCalls = 0;
  void Function()? focusListener;
  final shown = <FakeShown>[];
  @override
  NotifyPermission get permission => perm;
  @override
  Future<NotifyPermission> requestPermission() async => perm = NotifyPermission.granted;
  @override
  ShownNotification? show(String title, {String? body, String? tag, bool requireInteraction = false}) {
    final n = FakeShown(title, body, tag, requireInteraction);
    shown.add(n);
    return n;
  }

  @override
  bool get pageFocused => focused;
  @override
  void focusWindow() => focusCalls++;
  @override
  void onWindowFocus(void Function() fn) => focusListener = fn;
}

WorkerInfo worker(String id, String status, {bool acked = false}) => WorkerInfo.fromJson({
  'id': id,
  'name': 'Ada',
  'status': status,
  'acked': acked,
  'activity': 'Allow edit to main.ts?',
  'task': {'name': 'Fix Login', 'summary': 'fixing the redirect'},
});

void main() {
  test('waitingOnSomeone', () {
    expect(waitingOnSomeone(worker('a', 'needs_input')), isTrue);
    expect(waitingOnSomeone(worker('a', 'done')), isTrue);
    expect(waitingOnSomeone(worker('a', 'done', acked: true)), isFalse);
    expect(waitingOnSomeone(worker('a', 'working')), isFalse);
  });

  test('alerts only while the tab is in the background, and click opens the worker', () {
    final api = FakeApi();
    final opened = <String>[];
    var on = true;
    final n = DesktopNotifier(enabled: () => on, openWorker: opened.add, api: api);
    api.focused = true;
    n.alert(worker('a', 'needs_input'));
    expect(api.shown, isEmpty);
    api.focused = false;
    n.alert(worker('a', 'needs_input'));
    expect(api.shown.single.title, 'Ada needs input');
    expect(api.shown.single.body, 'Fix Login\nAllow edit to main.ts?');
    expect(api.shown.single.sticky, isTrue);
    expect(api.shown.single.tag, 'worker-a');
    api.shown.single.click!();
    expect(opened, ['a']);
    expect(api.focusCalls, 1);
    expect(api.shown.single.isClosed, isTrue);

    n.alert(worker('b', 'done'));
    expect(api.shown.last.title, 'Ada is done');
    expect(api.shown.last.sticky, isFalse);

    on = false;
    n.alert(worker('c', 'done'));
    expect(api.shown, hasLength(2));
    on = true;
    api.perm = NotifyPermission.denied;
    n.alert(worker('c', 'done'));
    expect(api.shown, hasLength(2));
  });

  test('sync takes down notifications nobody needs, and focus takes down all', () {
    final api = FakeApi();
    final n = DesktopNotifier(enabled: () => true, openWorker: (_) {}, api: api);
    n.alert(worker('a', 'needs_input'));
    n.alert(worker('b', 'done'));
    n.sync({'a': worker('a', 'working'), 'b': worker('b', 'done')});
    expect(api.shown[0].isClosed, isTrue);
    expect(api.shown[1].isClosed, isFalse);
    api.focusListener!();
    expect(api.shown[1].isClosed, isTrue);
  });

  test('a new alert for the same worker replaces the old one', () {
    final api = FakeApi();
    final n = DesktopNotifier(enabled: () => true, openWorker: (_) {}, api: api);
    n.alert(worker('a', 'needs_input'));
    n.alert(worker('a', 'done'));
    expect(api.shown[0].isClosed, isTrue);
    expect(api.shown[1].isClosed, isFalse);
  });
}
