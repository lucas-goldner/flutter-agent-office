// Excalidraw in the browser: the bridge (app/excalidraw/bridge.js, see interop/excalidraw.dart) is
// imported into the page itself the first time the whiteboard is needed, the window's Excalidraw
// runs in an HtmlElementView, and the board in the office is drawn by the same module. The syncing
// is whiteboard_sync.dart's (shared with the desktop app's web view, whiteboard_native.dart).

import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../interop/excalidraw.dart';
import 'whiteboard_sync.dart';

ExcalidrawHost excalidrawHost() => _WebHost();

class _WebHost implements ExcalidrawHost {
  @override
  ExcalidrawWindow window(ExcalidrawMount mount, ExcalidrawEvents events) => _WebWindow(mount, events);

  @override
  Future<ExcalidrawPage> preview() async => _WebPage(await loadExcalidraw());
}

/// The bridge module, as a page: its pictures are the window's too (they're kept module-wide).
class _WebPage implements ExcalidrawPage {
  _WebPage(this.m);

  final ExcalidrawModule m;

  @override
  Future<String> missingFiles(String json) async => m.missingFiles(json);

  @override
  void addFiles(String json) => m.addFiles(json);

  @override
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH) => renderBoard(m, json, maxW, maxH);
}

/// The window's Excalidraw, mounted in a div of the page once the view has one.
class _WebWindow implements ExcalidrawWindow {
  _WebWindow(this.mount, this.events) {
    _removeKeys = onWindowKeyDown((e) {
      if (e.key != 'Escape') return false;
      final app = _app;
      if (app != null && !app.idle()) return false;
      if (app == null || !app.deselect()) events.onEscape();
      return true;
    });
  }

  final ExcalidrawMount mount;
  final ExcalidrawEvents events;
  ExcalidrawModule? _module;
  ExcalidrawApp? _app;
  bool _disposed = false;
  late final void Function() _removeKeys;

  @override
  late final Widget view = HtmlElementView.fromTagName(
    tagName: 'div',
    onElementCreated: (el) => _mount(el as web.HTMLElement),
  );

  void _mount(web.HTMLElement host) {
    host.style
      ..width = '100%'
      ..height = '100%';
    loadExcalidraw().then(
      (m) {
        if (_disposed) return;
        _module = m;
        _app = m.mount(
          host,
          MountOptions(
            name: mount.name,
            elements: mount.elements(),
            heading: mount.heading,
            onChange: events.onChange.toJS,
            onPointer: ((double x, double y, String tool, String button, String selected) {
              events.onPointer(x, y, tool, button, (jsonDecode(selected) as List).cast<String>());
            }).toJS,
            onReady: events.onReady.toJS,
          ),
        );
      },
      onError: (_) {
        if (!_disposed) events.onFailed();
      },
    );
  }

  @override
  Future<String> takeChanges(bool all) async => _app?.takeChanges(all) ?? '';

  @override
  void merge(String json) => _app?.merge(json);

  @override
  Future<String> file(String id) async => _app?.file(id) ?? '';

  @override
  void setCollaborators(String json) => _app?.setCollaborators(json);

  @override
  Future<String> missingFiles(String json) async => _module?.missingFiles(json) ?? '[]';

  @override
  void addFiles(String json) => _module?.addFiles(json);

  @override
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH) async {
    final m = _module;
    return m == null ? null : renderBoard(m, json, maxW, maxH);
  }

  @override
  void dispose() {
    _disposed = true;
    _removeKeys();
    _app?.unmount();
    _app = null;
  }
}
