// The desktop app's whiteboard driver (whiteboard_native.dart), Dart's half of the web view's
// channel: a fake web view stands in for WKWebView, recording the JavaScript Dart runs in it and
// posting back what app/excalidraw/host.html would. (The page's half is checked in a real browser.)

import 'dart:convert';

import 'package:agent_office/ui/whiteboard_native.dart';
import 'package:agent_office/ui/whiteboard_sync.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakePlatform extends WebViewPlatform {
  final List<FakeWebView> views = [];

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final v = FakeWebView(params);
    views.add(v);
    return v;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      FakeNavigation(params);
}

class FakeNavigation extends PlatformNavigationDelegate {
  FakeNavigation(super.params) : super.implementation();
  NavigationRequestCallback? onRequest;
  HttpResponseErrorCallback? onHttpError;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async => onRequest = onNavigationRequest;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async => this.onHttpError = onHttpError;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

/// A web view: what it loaded, the JavaScript run in it, and its `Office` channel to post on.
class FakeWebView extends PlatformWebViewController {
  FakeWebView(super.params) : super.implementation();

  final List<String> loaded = [];
  final List<String> js = [];
  void Function(JavaScriptMessage)? channel;
  FakeNavigation? nav;

  /// The calls run so far, as (id, method, args).
  List<(int, String, List<dynamic>)> get calls => [
    for (final s in js)
      if (RegExp(r'^office\.call\((\d+),("[^"]*"),(.*)\)$', dotAll: true).firstMatch(s) case final m?)
        (int.parse(m[1]!), jsonDecode(m[2]!) as String, jsonDecode(m[3]!) as List),
  ];

  void post(Map<String, dynamic> msg) => channel!(JavaScriptMessage(message: jsonEncode(msg)));
  void reply(int id, Object? value) => post({'type': 'reply', 'id': id, 'value': value});

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    expect(params.name, 'Office');
    channel = params.onMessageReceived;
  }

  @override
  Future<void> setOnConsoleMessage(void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async => nav = handler as FakeNavigation;

  @override
  Future<void> loadRequest(LoadRequestParams params) async => loaded.add(params.uri.toString());

  @override
  Future<void> runJavaScript(String javaScript) async => js.add(javaScript);
}

class Events {
  final log = <String>[];
  late final events = ExcalidrawEvents(
    onChange: () => log.add('change'),
    onPointer: (x, y, tool, button, selected) => log.add('pointer $x,$y $tool $button $selected'),
    onReady: () => log.add('ready'),
    onFailed: () => log.add('failed'),
    onEscape: () => log.add('escape'),
  );
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePlatform platform;
  setUp(() => WebViewPlatform.instance = platform = FakePlatform());

  ExcalidrawMount mount([String elements = '[]']) =>
      ExcalidrawMount(name: 'proj whiteboard', elements: () => elements, heading: 'Draw together');

  test('the window loads host.html from the office, and mounts once the bundle is in', () async {
    final e = Events();
    final w = excalidrawHost().window(mount('[{"id":"a"}]'), e.events);
    final v = platform.views.single;
    await tick();
    expect(v.loaded, ['http://localhost:4600/excalidraw/host.html']);
    expect(v.js, isEmpty, reason: 'nothing runs before the page says the bundle is loaded');
    // Asked meanwhile: queued, and run in order once loaded.
    final changes = w.takeChanges(true);
    v.post({'type': 'loaded'});
    await tick();
    expect(v.calls.map((c) => c.$2), ['takeChanges', 'mount']);
    expect(v.calls[1].$3, [
      {'name': 'proj whiteboard', 'elements': '[{"id":"a"}]', 'heading': 'Draw together'},
    ]);
    v.reply(v.calls[0].$1, '[{"id":"b"}]');
    expect(await changes, '[{"id":"b"}]');
    v.post({'type': 'ready'});
    v.post({'type': 'change'});
    v.post({'type': 'pointer', 'x': 1, 'y': 2.5, 'tool': 'laser', 'button': 'down', 'selected': ['a']});
    v.post({'type': 'escape'});
    expect(e.log, ['ready', 'change', 'pointer 1.0,2.5 laser down [a]', 'escape']);
  });

  test('calls carry their arguments as JavaScript literals, answers come back by id', () async {
    final w = excalidrawHost().window(mount(), Events().events);
    final v = platform.views.single;
    v.post({'type': 'loaded'});
    await tick();
    const tricky = 'quote " backslash \\ newline \n line sep   emoji 🖍️ </script>';
    w.merge(tricky);
    final f1 = w.file('x'), f2 = w.file('y');
    final missing = w.missingFiles('[]');
    await tick();
    final calls = v.calls.skip(1).toList();
    expect(calls.map((c) => c.$2), ['merge', 'file', 'file', 'missingFiles']);
    expect(calls[0].$3, [tricky]);
    // Answered out of order: each gets its own.
    v.reply(calls[2].$1, '{"id":"y"}');
    v.reply(calls[1].$1, null);
    v.reply(calls[3].$1, '["p"]');
    expect(await f2, '{"id":"y"}');
    expect(await f1, '', reason: "null (no picture) reads as ''");
    expect(await missing, '["p"]');
    final bad = w.takeChanges(false);
    await tick();
    v.post({'type': 'reply', 'id': v.calls.last.$1, 'error': 'TypeError: boom'});
    await expectLater(bad, throwsA(isA<StateError>()));
  });

  test("the board's preview comes back as a PNG data URL and is decoded into an image", () async {
    final page = await () async {
      final f = excalidrawHost().preview();
      await tick();
      platform.views.single.post({'type': 'loaded'});
      return f;
    }();
    final v = platform.views.single;
    // A 1x1 PNG.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final image = page.renderPreview('[{"id":"a"}]', 300, 200);
    await tick();
    expect(v.calls.single.$2, 'renderPreview');
    expect(v.calls.single.$3, ['[{"id":"a"}]', 300, 200]);
    v.reply(v.calls.single.$1, png);
    final img = await image;
    expect((img!.width, img.height), (1, 1));
    img.dispose();
    final none = page.renderPreview('[]', 300, 200);
    await tick();
    v.reply(v.calls.last.$1, null);
    expect(await none, isNull);
  });

  test('a page the office answers with an error fails the window, and its calls', () async {
    final e = Events();
    final w = excalidrawHost().window(mount(), e.events);
    final v = platform.views.single;
    await tick();
    final pending = w.takeChanges(false);
    v.nav!.onHttpError!(HttpResponseError(response: const WebResourceResponse(uri: null, statusCode: 404)));
    expect(e.log, ['failed']);
    await expectLater(pending, throwsA(isA<StateError>()));
    await expectLater(w.file('x'), throwsA(isA<StateError>()));
  });

  test('links stay out of the web view; a redirect away from the page fails it', () async {
    final e = Events();
    excalidrawHost().window(mount(), e.events);
    final v = platform.views.single;
    await tick();
    final nav = v.nav!.onRequest!;
    expect(await nav(const NavigationRequest(url: 'http://localhost:4600/excalidraw/host.html', isMainFrame: true)), NavigationDecision.navigate);
    expect(await nav(const NavigationRequest(url: 'https://example.com/', isMainFrame: true)), NavigationDecision.prevent);
    expect(e.log, isEmpty);
    expect(await nav(const NavigationRequest(url: 'http://localhost:4600/login', isMainFrame: true)), NavigationDecision.prevent);
    expect(e.log, ['failed']);
  });

  test('closing unmounts, waits for what was asked (the last changes), then lets go of the page', () async {
    final w = excalidrawHost().window(mount(), Events().events);
    final v = platform.views.single;
    v.post({'type': 'loaded'});
    await tick();
    final last = w.takeChanges(false);
    w.dispose();
    await tick();
    expect(v.calls.map((c) => c.$2), ['mount', 'takeChanges', 'unmount']);
    expect(v.loaded, hasLength(1), reason: 'still waiting for answers');
    v.reply(v.calls[1].$1, '[{"id":"z"}]');
    expect(await last, '[{"id":"z"}]');
    v.reply(v.calls[0].$1, null);
    v.reply(v.calls[2].$1, null);
    await tick();
    expect(v.loaded.last, 'about:blank');
  });

  test("an offscreen page that never loads says the preview is unavailable", () {
    fakeAsync((async) {
      Object? error;
      excalidrawHost().preview().then<void>((_) {}, onError: (Object e) => error = e);
      async.elapse(const Duration(seconds: 31));
      expect(error, isA<PreviewUnavailable>());
      expect(platform.views.single.loaded.last, 'about:blank');
    });
  });
}
