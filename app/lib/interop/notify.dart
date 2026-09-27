// The browser's Notification API, behind an interface so the notifier's logic runs (and is tested)
// off the web. [browserNotifications] is the real one on the web and a no-op everywhere else.

import 'notify_stub.dart' if (dart.library.js_interop) 'notify_web.dart' as impl;

/// What the browser says about notifications from the office. They need https or localhost.
enum NotifyPermission {
  /// Not asked yet: the browser shows its prompt on [NotifyApi.requestPermission].
  ask,
  granted,
  denied,
  unsupported,
}

/// One notification that's up.
abstract class ShownNotification {
  set onClick(void Function()? fn);
  set onClose(void Function()? fn);
  void close();
}

abstract class NotifyApi {
  NotifyPermission get permission;

  /// Shows the browser's permission prompt; call it from a click or key press.
  Future<NotifyPermission> requestPermission();

  /// Null when the browser won't show it (Chrome on Android only shows them from a service worker).
  ShownNotification? show(String title, {String? body, String? tag, bool requireInteraction = false});

  /// The office is the tab you're looking at: visible, and focused.
  bool get pageFocused;

  /// Brings the office's tab to the front.
  void focusWindow();

  /// Calls [fn] whenever the office's window gets the focus back.
  void onWindowFocus(void Function() fn);
}

NotifyApi browserNotifications() => impl.create();
