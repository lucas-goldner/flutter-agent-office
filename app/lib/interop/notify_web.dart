// Desktop notifications with package:web.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'notify.dart';

NotifyApi create() => _WebNotifications();

class _WebNotifications implements NotifyApi {
  bool get _supported => web.window.has('Notification') && web.window.isSecureContext;

  @override
  NotifyPermission get permission {
    if (!_supported) return NotifyPermission.unsupported;
    return switch (web.Notification.permission) {
      'granted' => NotifyPermission.granted,
      'denied' => NotifyPermission.denied,
      _ => NotifyPermission.ask,
    };
  }

  @override
  Future<NotifyPermission> requestPermission() async {
    if (permission != NotifyPermission.ask) return permission;
    try {
      await web.Notification.requestPermission().toDart;
    } catch (_) {
      // an old Safari that only takes a callback, or the prompt was blocked
    }
    return permission;
  }

  @override
  ShownNotification? show(String title, {String? body, String? tag, bool requireInteraction = false}) {
    try {
      final opts = web.NotificationOptions(icon: '/favicon.svg', requireInteraction: requireInteraction);
      if (body != null) opts.body = body;
      if (tag != null) opts.tag = tag;
      return _Shown(web.Notification(title, opts));
    } catch (_) {
      // Chrome on Android only shows them from a service worker
      return null;
    }
  }

  @override
  bool get pageFocused => !web.document.hidden && web.document.hasFocus();

  @override
  void focusWindow() => web.window.focus();

  @override
  void onWindowFocus(void Function() fn) => web.window.addEventListener('focus', ((web.Event _) => fn()).toJS);
}

class _Shown implements ShownNotification {
  _Shown(this._n);
  final web.Notification _n;

  @override
  set onClick(void Function()? fn) => _n.onclick = fn == null ? null : ((web.Event _) => fn()).toJS;

  @override
  set onClose(void Function()? fn) => _n.onclose = fn == null ? null : ((web.Event _) => fn()).toJS;

  @override
  void close() => _n.close();
}
