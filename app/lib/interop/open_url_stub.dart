// Off the web: links open in the system's browser (browser_io.dart), and are recorded for tests.

import 'browser_io.dart' as browser;

/// Links opened off the web, for tests.
final List<String> openedUrls = [];

void openUrl(String url) {
  openedUrls.add(url);
  browser.openExternal(url);
}
