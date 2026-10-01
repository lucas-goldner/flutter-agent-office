// Excalidraw, from Dart: the bridge module (app/excalidraw/bridge.js) that tool/build_whiteboard.dart
// bundles with React and Excalidraw into web/excalidraw/. It's several MB, so it's imported the
// first time the whiteboard is needed, not with the app.

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

extension type ExcalidrawModule._(JSObject _) implements JSObject {
  external ExcalidrawApp mount(web.HTMLElement host, MountOptions opts);

  /// Pictures from the office (a JSON array of Excalidraw's BinaryFileData).
  external void addFiles(String json);
  external bool hasFile(String id);

  /// The picture ids these elements (JSON) show that this page doesn't have yet (JSON array).
  external String missingFiles(String json);
  external JSPromise<web.HTMLCanvasElement?> renderPreview(String json, int maxW, int maxH);
}

extension type MountOptions._(JSObject _) implements JSObject {
  external factory MountOptions({
    String name,
    String elements,
    String heading,
    JSFunction onChange,
    JSFunction onPointer,
    JSFunction onReady,
  });
}

/// One mounted Excalidraw.
extension type ExcalidrawApp._(JSObject _) implements JSObject {
  /// Nothing under way that Esc should finish first (typing, drawing, a menu, a tool).
  external bool idle();

  /// Lets go of whatever is selected; false when nothing was.
  external bool deselect();

  /// The elements changed since last taken or merged (all of them with [all]) as JSON, or ''.
  external String takeChanges(bool all);
  external void merge(String json);

  /// A picture (JSON BinaryFileData), or '' when Excalidraw hasn't got it.
  external String file(String id);
  external void setCollaborators(String json);
  external void unmount();
}

@JS('EXCALIDRAW_ASSET_PATH')
external set _assetPath(String v);

Future<ExcalidrawModule>? _loading;

/// The bridge, loaded once (again after a failure). Its fonts come from the office, next to it.
Future<ExcalidrawModule> loadExcalidraw() => _loading ??= () async {
  final base = Uri.parse(web.document.baseURI).resolve('excalidraw/');
  _assetPath = base.toString();
  try {
    final m = await importModule(base.resolve('whiteboard.js').toString().toJS).toDart;
    return m as ExcalidrawModule;
  } catch (_) {
    _loading = null;
    rethrow;
  }
}();

/// The board drawn by Excalidraw as an image, at most [maxW] x [maxH]; null when nothing is drawn.
Future<ui.Image?> renderBoard(ExcalidrawModule m, String json, int maxW, int maxH) async {
  final canvas = await m.renderPreview(json, maxW, maxH).toDart;
  if (canvas == null) return null;
  return ui_web.createImageFromTextureSource(canvas, width: canvas.width, height: canvas.height, transferOwnership: true);
}

/// A capture-phase keydown listener on the window, ahead of Excalidraw's own. Returns the remover.
void Function() onWindowKeyDown(bool Function(web.KeyboardEvent e) handle) {
  final fn = ((web.KeyboardEvent e) {
    if (handle(e)) {
      e.preventDefault();
      e.stopPropagation();
    }
  }).toJS;
  web.window.addEventListener('keydown', fn, true.toJS);
  return () => web.window.removeEventListener('keydown', fn, true.toJS);
}
