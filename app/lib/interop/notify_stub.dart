// Off the web there are no browser notifications.

import 'notify.dart';

NotifyApi create() => _NoNotifications();

class _NoNotifications implements NotifyApi {
  @override
  NotifyPermission get permission => NotifyPermission.unsupported;
  @override
  Future<NotifyPermission> requestPermission() async => NotifyPermission.unsupported;
  @override
  ShownNotification? show(String title, {String? body, String? tag, bool requireInteraction = false}) => null;
  @override
  bool get pageFocused => true;
  @override
  void focusWindow() {}
  @override
  void onWindowFocus(void Function() fn) {}
}
