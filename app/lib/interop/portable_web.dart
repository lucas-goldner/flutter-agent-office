import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'browser.dart' as browser;

String? storageGet(String key) => browser.storageGet(key);
void storageSet(String key, String value) => browser.storageSet(key, value);

/// Opens [url] in a new tab, without giving it a handle on this one.
void openInNewTab(String url) => web.window.open(url, '_blank', 'noopener');

/// Takes over the browser's paste while [active] says so, handing the text to [onText] (so a
/// terminal can bracket it) instead of letting it land in Flutter's hidden text field. Returns a remover.
void Function() interceptPaste(bool Function() active, void Function(String text) onText) {
  final handler = ((web.ClipboardEvent e) {
    if (!active()) return;
    final text = e.clipboardData?.getData('text/plain') ?? '';
    e.preventDefault();
    e.stopImmediatePropagation();
    if (text.isNotEmpty) onText(text);
  }).toJS;
  web.document.addEventListener('paste', handler, true.toJS);
  return () => web.document.removeEventListener('paste', handler, true.toJS);
}
