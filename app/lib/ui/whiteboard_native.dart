// Excalidraw in the desktop app: a web view (WKWebView on macOS, through webview_flutter) loads a
// small page from the office, /excalidraw/host.html (app/excalidraw/host.html), which imports the
// same bundle the browser does and drives the bridge the way whiteboard_web.dart does. Dart and the
// page talk over the web view: Dart runs `office.call(id, method, args)` in it, and the page posts
// JSON back on the `Office` channel (the replies, and Excalidraw's events). The syncing is
// whiteboard_sync.dart's, the same as in the browser; the drawing and its pictures go through the
// app's own connection to the office, never the web view's.
//
// The board in the office is drawn by a second page in a web view that's never on screen. If that
// one doesn't run (or can't draw), the window's own page draws the board while it's open and as it
// closes (see whiteboard_hub.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../interop/browser.dart' show openExternal, serverOrigin;
import 'whiteboard_sync.dart';

ExcalidrawHost excalidrawHost() => _NativeHost();

/// How long the page may take to load the bundle (several MB, from the office).
const Duration _loadTimeout = Duration(seconds: 30);

/// How long drawing the board may take before the offscreen page counts as not running.
const Duration _previewTimeout = Duration(seconds: 20);

class _NativeHost implements ExcalidrawHost {
  HostPage? _preview;

  @override
  ExcalidrawWindow window(ExcalidrawMount mount, ExcalidrawEvents events) => _NativeWindow(mount, events);

  @override
  Future<ExcalidrawPage> preview() async {
    // Never on screen: it only draws the board in the office.
    final page = _preview ??= HostPage();
    try {
      await page.loaded.timeout(_loadTimeout);
    } on TimeoutException {
      // Most likely a web view that's in no window doesn't run: the window's page draws instead.
      if (identical(_preview, page)) _preview = null;
      page.close();
      throw const PreviewUnavailable("the offscreen whiteboard page didn't load");
    } catch (e) {
      // The office can't be reached (or hasn't got the page): try afresh next time.
      if (identical(_preview, page)) _preview = null;
      page.close();
      rethrow;
    }
    return page;
  }
}

/// The page in a web view: its calls, and its events (for the window's).
class HostPage implements ExcalidrawPage {
  HostPage({this.onEvent, this.onFailed}) {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Office', onMessageReceived: (m) => _message(m.message))
      ..setOnConsoleMessage((m) => debugPrint('whiteboard page: ${m.message}'))
      ..setNavigationDelegate(
        NavigationDelegate(
          // Links in a drawing go to the system's browser; the web view stays on the board.
          onNavigationRequest: (req) {
            if (req.url == _url.toString() || req.url == 'about:blank') return NavigationDecision.navigate;
            final to = Uri.tryParse(req.url);
            if (to != null && to.hasScheme && to.origin == _url.origin) {
              // The office sent the page elsewhere (an office too old to have it, say).
              if (!_ready) _fail('the office answered ${_url.path} with ${to.path}');
            } else if (req.isMainFrame) {
              openExternal(req.url);
            }
            return NavigationDecision.prevent;
          },
          // Only the page's own load counts (WebKit names no request here; it's the main frame's).
          // Afterwards, a link the web view was kept from following shows up as an error too.
          onHttpError: (e) {
            if (!_ready) _fail('HTTP ${e.response?.statusCode} for ${_url.path}');
          },
          onWebResourceError: (e) {
            if (!_ready && (e.isForMainFrame ?? true)) _fail(e.description);
          },
        ),
      );
    if (kDebugMode && controller.platform is WebKitWebViewController) {
      // Safari's Develop menu can inspect it.
      (controller.platform as WebKitWebViewController).setInspectable(true);
    }
    controller.loadRequest(_url);
  }

  late final WebViewController controller;
  final void Function(Map<String, dynamic> msg)? onEvent;
  final void Function()? onFailed;

  final Uri _url = Uri.parse(serverOrigin).resolve('/excalidraw/host.html');
  final Completer<void> _loaded = Completer();
  bool _ready = false;
  Object? _failed;
  bool _closing = false;
  int _seq = 0;
  final Map<int, Completer<Object?>> _calls = {};
  final List<String> _queue = [];

  /// Done when the bridge is imported; an error if it couldn't be.
  Future<void> get loaded => _loaded.future;

  void _message(String raw) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'loaded':
        _ready = true;
        if (!_loaded.isCompleted) _loaded.complete();
        for (final js in _queue) {
          _run(js);
        }
        _queue.clear();
      case 'failed':
        _fail(msg['error'] ?? 'the whiteboard bundle failed to load');
      case 'reply':
        final c = _calls.remove(msg['id']);
        if (c == null) break;
        if (msg['error'] != null) {
          c.completeError(StateError('whiteboard page: ${msg['error']}'));
        } else {
          c.complete(msg['value']);
        }
        _blankWhenDone();
      default:
        onEvent?.call(msg);
    }
  }

  void _fail(Object why) {
    if (_failed != null || _closing) return;
    _failed = why;
    debugPrint('whiteboard page: $why');
    if (!_loaded.isCompleted) {
      _loaded.completeError(StateError('$why'));
      _loaded.future.ignore();
    }
    for (final c in _calls.values) {
      c.completeError(StateError('$why'));
    }
    _calls.clear();
    _queue.clear();
    onFailed?.call();
  }

  void _run(String js) => controller.runJavaScript(js).catchError((Object e) => _fail(e));

  /// Calls [method] in the page with [args] (strings, numbers, bools, maps): its answer.
  Future<Object?> call(String method, [List<Object?> args = const []]) {
    if (_failed case final why?) return Future.error(StateError('$why'));
    final id = ++_seq;
    final c = _calls[id] = Completer<Object?>();
    // JSON is JavaScript: the arguments go in as literals.
    final js = 'office.call($id,${jsonEncode(method)},${jsonEncode(args)})';
    if (_ready) {
      _run(js);
    } else {
      _queue.add(js);
    }
    return c.future;
  }

  /// A call nobody waits for.
  void tell(String method, [List<Object?> args = const []]) =>
      call(method, args).then<void>((_) {}, onError: (Object e) => debugPrint('whiteboard $method: $e'));

  @override
  Future<String> missingFiles(String json) async => (await call('missingFiles', [json])) as String? ?? '[]';

  @override
  void addFiles(String json) => tell('addFiles', [json]);

  @override
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH) async {
    final Object? url;
    try {
      url = await call('renderPreview', [json, maxW, maxH]).timeout(_previewTimeout);
    } on TimeoutException {
      throw const PreviewUnavailable("the whiteboard page didn't draw the board");
    }
    if (url is! String) return null;
    final codec = await ui.instantiateImageCodec(UriData.parse(url).contentAsBytes());
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// Lets go of the page once what's been asked is answered (the last of the drawing, say).
  void close() {
    _closing = true;
    Timer(const Duration(seconds: 10), _blank);
    _blankWhenDone();
  }

  void _blankWhenDone() {
    if (_closing && _calls.isEmpty) _blank();
  }

  bool _blanked = false;
  void _blank() {
    if (_blanked) return;
    _blanked = true;
    for (final c in _calls.values) {
      c.completeError(StateError('the whiteboard page closed'));
    }
    _calls.clear();
    controller.loadRequest(Uri.parse('about:blank')).catchError((_) {});
  }
}

/// The window's Excalidraw, in a web view.
class _NativeWindow implements ExcalidrawWindow {
  _NativeWindow(ExcalidrawMount mount, this.events) {
    page = HostPage(onEvent: _event, onFailed: events.onFailed);
    page.loaded.then(
      (_) => page.tell('mount', [
        {'name': mount.name, 'elements': mount.elements(), 'heading': mount.heading},
      ]),
      onError: (_) {},
    );
  }

  final ExcalidrawEvents events;
  late final HostPage page;
  bool _disposed = false;

  void _event(Map<String, dynamic> msg) {
    if (_disposed) return;
    switch (msg['type']) {
      case 'change':
        events.onChange();
      case 'pointer':
        events.onPointer(
          (msg['x'] as num).toDouble(),
          (msg['y'] as num).toDouble(),
          msg['tool'] as String? ?? 'pointer',
          msg['button'] as String? ?? 'up',
          [for (final s in msg['selected'] as List? ?? const []) '$s'],
        );
      case 'ready':
        events.onReady();
      case 'escape':
        events.onEscape();
    }
  }

  @override
  late final Widget view = WebViewWidget(controller: page.controller);

  @override
  Future<String> takeChanges(bool all) async => (await page.call('takeChanges', [all])) as String? ?? '';

  @override
  void merge(String json) => page.tell('merge', [json]);

  @override
  Future<String> file(String id) async => (await page.call('file', [id])) as String? ?? '';

  @override
  void setCollaborators(String json) => page.tell('setCollaborators', [json]);

  @override
  Future<String> missingFiles(String json) => page.missingFiles(json);

  @override
  void addFiles(String json) => page.addFiles(json);

  @override
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH) => page.renderPreview(json, maxW, maxH);

  @override
  void dispose() {
    _disposed = true;
    page.tell('unmount');
    page.close();
  }
}
