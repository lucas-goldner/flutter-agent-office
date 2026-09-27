// Off the web: the desktop app's storage and browser (browser_io.dart). In widget tests, where the
// app never started, storage stays in memory and links are only recorded.

import 'browser_io.dart' as browser;

String? storageGet(String key) => browser.storageGet(key);
void storageSet(String key, String value) => browser.storageSet(key, value);

/// The URLs [openInNewTab] was asked to open (for tests).
final List<String> openedUrls = [];
void openInNewTab(String url) {
  openedUrls.add(url);
  browser.openExternal(url);
}

/// Flutter's own text field gets the paste on the desktop, so there's nothing to take over (yet).
void Function() interceptPaste(bool Function() active, void Function(String text) onText) => () {};
