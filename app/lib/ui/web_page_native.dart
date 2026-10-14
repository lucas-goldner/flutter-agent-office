// A pinned page in the desktop app's own web view.

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

Widget webPageView(String url, String title) => _WebPage(key: ValueKey(url), url: url);

class _WebPage extends StatefulWidget {
  const _WebPage({super.key, required this.url});
  final String url;

  @override
  State<_WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<_WebPage> {
  late final WebViewController _c = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _c);
}
