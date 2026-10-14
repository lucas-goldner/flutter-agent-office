// A pinned page in an iframe.

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// What a pinned page may do in its frame: run, sign in, send forms and open links in a new tab, but
/// never navigate the office's own tab away, or reach camera, mic or clipboard.
const _sandbox = 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox';

Widget webPageView(String url, String title) => HtmlElementView.fromTagName(
  key: ValueKey(url),
  tagName: 'iframe',
  onElementCreated: (el) {
    final f = el as web.HTMLIFrameElement;
    f
      ..src = url
      ..title = title
      ..referrerPolicy = 'no-referrer'
      ..setAttribute('sandbox', _sandbox)
      ..setAttribute('loading', 'lazy');
    f.style
      ..border = 'none'
      ..width = '100%'
      ..height = '100%'
      ..background = '#fff';
  },
);
