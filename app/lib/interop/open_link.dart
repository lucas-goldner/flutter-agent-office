// Opening a link in a new tab (an <a target=_blank rel=noopener>).

import 'package:web/web.dart' as web;

void openInNewTab(String url) => web.window.open(url, '_blank', 'noopener');
