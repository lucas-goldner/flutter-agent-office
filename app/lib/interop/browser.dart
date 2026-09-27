// Small wrappers over the browser, so the rest of the app doesn't reach for package:web directly.

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The page's location, e.g. `/join`, `#token`, `?t=…`.
String get locationPath => web.window.location.pathname;
String get locationHash => web.window.location.hash;
String get locationSearch => web.window.location.search;
String get locationHost => web.window.location.host;
bool get isSecure => web.window.location.protocol == 'https:';

/// Goes somewhere else, replacing this page in history (location.replace).
void goReplace(String url) => web.window.location.replace(url);

/// Goes somewhere else (location.href = url).
void goTo(String url) => web.window.location.href = url;

/// Rewrites the address bar without navigating (history.replaceState).
void replaceUrl(String url) => web.window.history.replaceState(null, '', url);

void reloadPage() => web.window.location.reload();

/// localStorage, tolerating a browser that blocks it.
String? storageGet(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void storageSet(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {
    // storage blocked
  }
}

void storageRemove(String key) {
  try {
    web.window.localStorage.removeItem(key);
  } catch (_) {
    // storage blocked
  }
}

/// Asks before leaving the page while [shouldWarn] says so (beforeunload). Returns a remover.
void Function() warnBeforeUnload(bool Function() shouldWarn) {
  final handler = ((web.Event e) {
    if (shouldWarn()) e.preventDefault();
  }).toJS;
  web.window.addEventListener('beforeunload', handler);
  return () => web.window.removeEventListener('beforeunload', handler);
}

/// The tab's title.
set documentTitle(String title) => web.document.title = title;

/// Whether the tab is hidden (another tab or app in front).
bool get pageHidden => web.document.hidden;
