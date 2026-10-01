// The whiteboard's syncing, the same in the browser and in the desktop app: what to send and when,
// the pictures, and who's drawing. Excalidraw itself stays JavaScript (app/excalidraw/bridge.js),
// and each platform drives it its own way (an ExcalidrawDriver): by JS interop in the browser
// (whiteboard_web.dart), over a web view's message channel in the desktop app (whiteboard_native.dart).
// Everything crosses as JSON strings, and asks that answer are futures, so either can be behind them.
//
// Syncing works like Excalidraw's own live collaboration: every change bumps an element's version,
// each client sends the elements it changed, and everyone merges what arrives with
// reconcileElements, which keeps the newer copy of each element.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show Widget;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';

import '../net/api.dart' show ApiResult;
import '../state/store.dart';
import 'whiteboard_logic.dart';

/// A page with the bridge loaded: its pictures, and drawing the board for the office.
abstract interface class ExcalidrawPage {
  /// The picture ids these elements (JSON) show that the page doesn't have yet (JSON array).
  Future<String> missingFiles(String json);

  /// Pictures from the office (a JSON array of Excalidraw's BinaryFileData).
  void addFiles(String json);

  /// The drawing (JSON elements) as an image at most [maxW] x [maxH]; null when nothing is drawn.
  /// Throws [PreviewUnavailable] when this page can't draw at all.
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH);
}

/// The page that would draw the board in the office doesn't run (an offscreen web view, say).
class PreviewUnavailable implements Exception {
  const PreviewUnavailable(this.why);
  final String why;
  @override
  String toString() => 'PreviewUnavailable: $why';
}

/// One mounted Excalidraw (the whiteboard window's), as the syncing sees it.
abstract interface class ExcalidrawDriver implements ExcalidrawPage {
  /// The elements changed since last taken or merged (all of them with [all]) as JSON, or ''.
  Future<String> takeChanges(bool all);

  /// Merges elements from the office (JSON); whatever you're in the middle of stays yours.
  void merge(String json);

  /// A picture (JSON BinaryFileData), or '' when Excalidraw hasn't got it.
  Future<String> file(String id);

  /// Everyone else with the whiteboard open (JSON: [{id, name, color, x?, y?, tool?, button?, selected?}]).
  void setCollaborators(String json);
}

/// What a whiteboard window's Excalidraw starts with.
class ExcalidrawMount {
  const ExcalidrawMount({required this.name, required this.elements, required this.heading});

  /// For exports.
  final String name;

  /// The board as the office has it (JSON), asked for when Excalidraw is about to show it.
  final String Function() elements;

  /// The welcome screen's.
  final String heading;
}

/// What a whiteboard window's Excalidraw tells the office.
class ExcalidrawEvents {
  const ExcalidrawEvents({
    required this.onChange,
    required this.onPointer,
    required this.onReady,
    required this.onFailed,
    required this.onEscape,
  });

  /// Something changed: take the changes (soon).
  final void Function() onChange;
  final void Function(double x, double y, String tool, String button, List<String> selected) onPointer;
  final void Function() onReady;

  /// Excalidraw couldn't load.
  final void Function() onFailed;

  /// Esc with nothing left for it to finish or let go of in Excalidraw: close the window.
  final void Function() onEscape;
}

/// A whiteboard window's Excalidraw: the widget it shows in, and the driver.
abstract interface class ExcalidrawWindow implements ExcalidrawDriver {
  Widget get view;
  void dispose();
}

/// How a platform runs Excalidraw.
abstract interface class ExcalidrawHost {
  ExcalidrawWindow window(ExcalidrawMount mount, ExcalidrawEvents events);

  /// The page that draws the board in the office while the window is closed.
  Future<ExcalidrawPage> preview();
}

// ---- Pictures ------------------------------------------------------------------------------------
// Kept apart from the elements, as Excalidraw does: an image element names its picture by id (a
// hash of the picture), and the picture itself goes up and down over HTTP.

class WbFiles {
  WbFiles({required this.floor, required this.fetch, required this.upload, required this.warn});

  /// The floor you're on ('' if none).
  final String Function() floor;

  /// GETs a path on the office: the body, or null if it isn't there (or the office can't be reached).
  final Future<String?> Function(String path) fetch;

  /// POSTs JSON to a path on the office; throws when it can't be reached.
  final Future<ApiResult> Function(String path, Map<String, dynamic> body) upload;
  final void Function(String message) warn;

  /// Pictures the office has, so they needn't go up again.
  final Set<String> stored = {};
  final Map<String, Future<bool>> _uploads = {};

  /// Pictures the office didn't have when asked, and when; asked again after a while.
  final Map<String, int> _missing = {};

  String url([String? id]) =>
      '/api/whiteboard/file?floor=${Uri.encodeComponent(floor())}${id != null ? '&id=${Uri.encodeComponent(id)}' : ''}';

  /// Fetches the pictures these elements (JSON) show that [page] doesn't have yet, and hands them to it.
  Future<void> load(ExcalidrawPage page, String json) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final want = [
      for (final id in (jsonDecode(await page.missingFiles(json)) as List).cast<String>())
        if (now - (_missing[id] ?? 0) > 10000) id,
    ];
    if (want.isEmpty) return;
    final got = <String>[];
    await Future.wait(
      want.map((id) async {
        final body = await fetch(url(id)).catchError((_) => null);
        if (body == null) {
          _missing[id] = DateTime.now().millisecondsSinceEpoch;
          return;
        }
        got.add(body);
        stored.add(id);
        _missing.remove(id);
      }),
    );
    if (got.isNotEmpty) page.addFiles('[${got.join(',')}]');
  }

  /// Puts picture [id] on the office's board, read with [read] (JSON BinaryFileData, '' if there's
  /// none yet); resolves to whether it's there now. Once at a time per picture.
  Future<bool> put(String id, Future<String> Function() read) => _uploads[id] ??= () async {
    try {
      final json = await read();
      if (json.isEmpty) {
        // Excalidraw hasn't got it (yet): asked again with the next change.
        _uploads.remove(id);
        return false;
      }
      final r = await upload(url(), jsonDecode(json) as Map<String, dynamic>);
      if (r.ok) {
        stored.add(id);
        return true;
      }
      warn(r.error("Couldn't put that picture on the whiteboard"));
      return false;
    } catch (_) {
      // Offline: try again with the next change.
      _uploads.remove(id);
      return false;
    }
  }();
}

// ---- One open whiteboard ---------------------------------------------------------------------------

/// The syncing of an open whiteboard window: your changes out, everyone else's in, their cursors.
class WhiteboardSync {
  WhiteboardSync({required this.driver, required this.store, required this.send, required this.files, required this.warn});

  final ExcalidrawDriver driver;
  final Store store;
  final void Function(ClientMsg msg) send;
  final WbFiles files;
  final void Function(String message) warn;

  /// Excalidraw is up (nothing to take or merge before).
  bool _ready = false;
  bool _closed = false;
  bool get ready => _ready && !_closed;

  /// Your changes on their way out (pictures wait here until they're up).
  final Map<String, WbElement> pending = {};
  Timer? _sendTimer;
  final Map<String, WbPointerMsg> pointers = {};

  /// Elements too big to send, which you've been told about.
  final Set<String> _tooBig = {};
  Timer? _collabTimer;

  /// Excalidraw is up: it gets whatever arrived while it loaded, its pictures, and everyone's cursors.
  void start() {
    if (_closed) return;
    _ready = true;
    merge(store.whiteboard.values.toList());
    _collaboratorsSoon();
  }

  /// Something changed in Excalidraw.
  void changed() => _schedule();

  void pointer(double x, double y, String tool, String button, List<String> selected) => send(
    WbPointerCmd(WbPointer(x: x, y: y, tool: WbTool.parse(tool), button: WbButton.parse(button)), selected: selected),
  );

  void _schedule() {
    if (_closed) return;
    _sendTimer ??= Timer(const Duration(milliseconds: wbSendMs), flush);
  }

  /// Sends what you changed since last time: the live elements, as they are now.
  Future<void> flush({bool all = false}) async {
    _sendTimer?.cancel();
    _sendTimer = null;
    if (!_ready) return;
    // Asked straight away (before anything else is), so closing right after still gets them.
    final String changes;
    try {
      changes = await driver.takeChanges(all);
    } catch (e) {
      // Excalidraw's page went away (the desktop app's web view): nothing to take.
      debugPrint('whiteboard: $e');
      return;
    }
    for (final el in newerThanOffice(changes, store.whiteboard)) {
      pending[el.id] = el;
    }
    final out = <WbElement>[];
    for (final el in pending.values.toList()) {
      // A picture goes up before the element that shows it, so nobody gets an image they can't load.
      final fileId = el.fileId;
      if (el.type == 'image' && fileId != null && !el.isDeleted && !files.stored.contains(fileId)) {
        if (!_closed) {
          files.put(fileId, () => driver.file(fileId)).then((ok) => ok ? _schedule() : null);
        }
        continue;
      }
      pending.remove(el.id);
      out.add(el);
    }
    if (out.isEmpty) return;
    store.drew(out);
    for (final batch in batches(
      out,
      tooBig: (el) {
        if (_tooBig.add(el.id)) warn("That's too big for the whiteboard, so only you can see it. Try it in smaller pieces.");
      },
    )) {
      send(WbUpdateCmd(batch));
    }
  }

  /// Merges elements from the office into the drawing; whatever you're in the middle of stays yours.
  void merge(List<WbElement> remote) {
    if (!ready || remote.isEmpty) return;
    final json = jsonEncode([for (final e in remote) e.raw]);
    driver.merge(json);
    files.load(driver, json).catchError((Object e) => debugPrint('whiteboard pictures: $e'));
  }

  void _collaboratorsSoon() => _collabTimer ??= Timer(const Duration(milliseconds: 16), _showCollaborators);

  /// Everyone else with the whiteboard open, with their cursors and selections.
  void _showCollaborators() {
    _collabTimer = null;
    if (!ready) return;
    driver.setCollaborators(
      jsonEncode([
        for (final peer in othersDrawing(store.drawing, store.you, store.peers))
          {
            'id': peer.id,
            'name': peer.name,
            'color': peer.color,
            if (pointers[peer.id] case final p?) ...{
              'x': p.pointer.x,
              'y': p.pointer.y,
              'tool': p.pointer.tool.wire,
              'button': p.pointer.button.wire,
              'selected': ?p.selected,
            },
          },
      ]),
    );
  }

  /// Back from a dropped connection: merges the board as the office has it, and sends what was
  /// drawn meanwhile.
  void reconnected() {
    merge(store.whiteboard.values.toList());
    flush(all: true);
  }

  /// Whiteboard messages for the window (the store has already taken them in).
  void route(ServerMsg msg) {
    switch (msg) {
      case WbUpdateMsg m:
        merge(m.elements);
      case WbPointerMsg m:
        pointers[m.id] = m;
        _collaboratorsSoon();
      case WbPeopleMsg m:
        pointers.removeWhere((id, _) => !m.people.contains(id));
        _collaboratorsSoon();
      case PeerUpdateMsg _ || PeerLeaveMsg _:
        _collaboratorsSoon();
      default:
        break;
    }
  }

  /// The window is closing: what you drew last still goes out (taken before Excalidraw goes away).
  void close() {
    flush();
    _closed = true;
    _sendTimer?.cancel();
    _sendTimer = null;
    _collabTimer?.cancel();
    _collabTimer = null;
  }
}
