// Tabs on a worker's terminal (ui/termtabs.ts): the terminal itself, plus any web pages pinned open
// beside it (a linked chat, docs for the task). They're this browser's own: nothing goes to the office or
// to anyone else, and they're kept per worker until the page reloads.

import 'dart:math' as math;

/// A web page pinned open beside a worker's terminal, or one of its files ([file]: its path in the worker's folder).
class WebTab {
  const WebTab({required this.id, required this.title, required this.url, this.file});
  final String id;
  final String title;
  final String url;
  final String? file;
}

/// The tab for the worker's file at [path].
WebTab newFileTab(String path) => WebTab(
  id: 'file-${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(1 << 30).toRadixString(36)}',
  title: path.split('/').last,
  url: '',
  file: path,
);

/// Web tabs survive closing and reopening a worker's terminal, until the page reloads.
final Map<String, List<WebTab>> tabsByWorker = {};

final _rng = math.Random();

/// The tab [name] and [address] make, or why they don't: only http(s) pages, and never the office's own
/// ([officeOrigin]), which would run in the frame signed in as you.
({WebTab? tab, String? problem}) newWebTab(String name, String address, {required String officeOrigin}) {
  const notAddress = 'That doesn’t look like a web address';
  final url = Uri.tryParse(address.trim());
  if (url == null || !url.hasScheme) return (tab: null, problem: notAddress);
  if (url.scheme != 'http' && url.scheme != 'https') {
    return (tab: null, problem: 'Only http:// and https:// addresses can open in a tab');
  }
  if (url.host.isEmpty) return (tab: null, problem: notAddress);
  if (url.origin == Uri.parse(officeOrigin).origin) {
    return (tab: null, problem: "The office's own pages can't open in a tab");
  }
  final named = name.trim();
  final title = named.isNotEmpty
      ? (named.length > 40 ? named.substring(0, 40) : named)
      : url.host.replaceFirst(RegExp(r'^www\.'), '');
  final id = 'web-${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(1 << 30).toRadixString(36)}';
  return (tab: WebTab(id: id, title: title, url: url.toString()), problem: null);
}
