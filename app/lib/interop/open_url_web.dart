import 'package:web/web.dart' as web;

/// Not used on the web; kept so both sides export the same names.
final List<String> openedUrls = [];

/// Opens [url] in a new tab, without giving it a handle on this one.
void openUrl(String url) => web.window.open(url, '_blank', 'noopener,noreferrer');
