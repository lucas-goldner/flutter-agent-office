// The 📝 whiteboard window, and the drawing on the whiteboard in the office: a port of ui/whiteboard.ts
// and the syncing half of ui/whiteboard-app.ts. Excalidraw itself stays JavaScript (app/excalidraw/
// bridge.js), run by the platform's ExcalidrawHost: in the page itself in the browser
// (whiteboard_web.dart), in a web view in the desktop app (whiteboard_native.dart). The syncing is
// whiteboard_sync.dart's, the same for both.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:office_shared/protocol.dart';

import '../net/api.dart';
import '../office_scope.dart';
import '../state/store.dart';
import '../world/office/whiteboard.dart' show WhiteboardStand;
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'whiteboard_logic.dart';
import 'whiteboard_native.dart' if (dart.library.js_interop) 'whiteboard_web.dart';
import 'whiteboard_sync.dart';

/// An open whiteboard window.
class _Board {
  _Board(this.floor);

  /// The floor whose whiteboard this is.
  final String floor;
  late final ModalHandle modal;
  late final ExcalidrawWindow window;
  late final WhiteboardSync sync;

  /// Loading, ready, or couldn't load.
  final ValueNotifier<_Phase> phase = ValueNotifier(_Phase.loading);
}

enum _Phase { loading, ready, failed }

/// The floor's whiteboard: the window, and keeping the board in the office showing the drawing.
class WhiteboardHub {
  WhiteboardHub(this.scope, this.stand, [ExcalidrawHost? host]) : host = host ?? excalidrawHost() {
    store.topic(Topic.whiteboard).addListener(_changed);
    // Arriving: after the office has loaded, since drawing it means loading Excalidraw.
    _soon(1500);
  }

  final OfficeScope scope;
  final WhiteboardStand stand;
  final ExcalidrawHost host;
  Store get store => scope.store;

  _Board? _open;
  bool get isOpen => _open != null;

  late final WbFiles _files = WbFiles(
    floor: () => store.floor ?? '',
    fetch: Api.getText,
    upload: Api.postJson,
    warn: (m) => toast(m, ToastKind.warn),
  );

  // ---- The window --------------------------------------------------------------------------------

  /// Opens the floor's whiteboard, to draw on with everyone else who has it open.
  void open() {
    if (_open != null) return;
    final floor = store.floor;
    if (floor == null) return toast('Take the elevator to a floor first', ToastKind.warn);
    final b = _Board(floor);
    _open = b;
    b.window = host.window(
      ExcalidrawMount(
        name: '${store.project?.name ?? 'office'} whiteboard',
        elements: () => boardJson(store.whiteboard),
        heading: 'Draw together: everyone on this floor sees it live, and it stays up on the board',
      ),
      ExcalidrawEvents(
        onChange: () => b.sync.changed(),
        onPointer: (x, y, tool, button, selected) => b.sync.pointer(x, y, tool, button, selected),
        onReady: () {
          if (_open != b) return;
          b.phase.value = _Phase.ready;
          b.sync.start();
          if (_previewViaWindow) _soon(300);
        },
        onFailed: () {
          if (_open == b) b.phase.value = _Phase.failed;
        },
        // Esc first gets you out of whatever you're doing in Excalidraw (typing, drawing, a menu, a
        // tool), then lets go of what's selected, and once there's nothing left, closes the window.
        onEscape: () {
          if (_open == b) b.modal.close();
        },
      ),
    );
    b.sync = WhiteboardSync(
      driver: b.window,
      store: store,
      send: scope.net.send,
      files: _files,
      warn: (m) => toast(m, ToastKind.warn),
    );
    b.modal = ModalStack.instance.show(
      (modal) => ModalWindow(
        modal: modal,
        width: 1600,
        height: double.infinity,
        bodyPadding: EdgeInsets.zero,
        scrollBody: false,
        background: Colors.white,
        title: _Title(store: store),
        body: _Body(board: b),
      ),
      escCloses: false,
      // Flutter sees Excalidraw's clicks too, and they don't stop at the window (a platform view
      // doesn't take part in hit testing), so a click on the drawing would count as one outside.
      backdropCloses: false,
      onClose: () => _closed(b),
    )..doing = '🖍️ at the whiteboard';
    scope.net.send(const WbOpenCmd());
  }

  void _closed(_Board b) {
    b.sync.close();
    // The last look at the drawing, for the board in the office, from the window's own Excalidraw.
    if (_previewViaWindow && b.phase.value == _Phase.ready) _draw(via: b.window);
    b.window.dispose();
    _open = null;
    scope.net.send(const WbCloseCmd());
    _soon(300);
  }

  /// Whiteboard messages, for the window when it's open (the store has already taken them in).
  void route(ServerMsg msg) {
    final b = _open;
    if (b == null) return;
    switch (msg) {
      case WelcomeMsg _:
        // Back from a dropped connection, and the office has forgotten the window was open.
        if (store.floor != b.floor) return b.modal.close();
        scope.net.send(const WbOpenCmd());
        b.sync.reconnected();
      case FloorEnterMsg _:
        b.modal.close();
      default:
        b.sync.route(msg);
    }
  }

  // ---- The board in the office --------------------------------------------------------------------
  // Redrawn a moment after the drawing changes, and not more than a few times a second while someone
  // draws, or once you close the window if you have it open (it hides the board anyway).
  //
  // When the platform has no page to draw it with while the window is closed (an offscreen web view
  // that doesn't run), the window's own Excalidraw draws it while it's open, and as it closes; the
  // board keeps the last drawing until the next time.

  Timer? _timer;
  bool _busy = false;
  bool _again = false;
  bool _previewViaWindow = false;

  void _changed() => _soon(300);

  void _soon(int ms) {
    if (_open != null && !_previewViaWindow) return;
    _timer ??= Timer(Duration(milliseconds: ms), _draw);
  }

  Future<void> _draw({ExcalidrawPage? via}) async {
    if (via == null) _timer = null;
    if (_busy) {
      if (via == null) _again = true;
      return;
    }
    _busy = true;
    final floor = store.floor;
    try {
      final json = boardJson(store.whiteboard, liveOnly: true);
      ui.Image? drawing;
      var draw = true;
      if (json != '[]') {
        if (via != null) {
          // Closing: the window's Excalidraw has every picture already, and goes away right after.
          drawing = await via.renderPreview(json, stand.fit.width, stand.fit.height);
        } else if (_previewViaWindow) {
          final b = _open;
          if (b != null && b.phase.value == _Phase.ready) {
            drawing = await b.window.renderPreview(json, stand.fit.width, stand.fit.height);
          } else {
            draw = false;
          }
        } else {
          final page = await host.preview();
          await _files.load(page, json);
          drawing = await page.renderPreview(json, stand.fit.width, stand.fit.height);
        }
      }
      // Rode the elevator meanwhile: this floor's drawing is on its way.
      if (draw && store.floor == floor) await stand.show(drawing);
      drawing?.dispose();
    } on PreviewUnavailable catch (e) {
      debugPrint('whiteboard preview: $e; drawing the board from the window instead');
      _previewViaWindow = true;
    } catch (e) {
      // keep whatever the board shows
      debugPrint('whiteboard preview: $e');
    }
    _busy = false;
    if (_again) {
      _again = false;
      _soon(300);
    }
  }

  void dispose() {
    store.topic(Topic.whiteboard).removeListener(_changed);
    _timer?.cancel();
    _open?.modal.close();
  }
}

/// The title bar: 📝 Whiteboard, and who else is drawing (LIVE).
class _Title extends StatelessWidget {
  const _Title({required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Text('📝 Whiteboard'),
      const SizedBox(width: 10),
      Expanded(
        child: ListenableBuilder(
          listenable: store.topics(const [Topic.drawing, Topic.peers]),
          builder: (context, _) => _People(others: othersDrawing(store.drawing, store.you, store.peers)),
        ),
      ),
    ],
  );
}

class _People extends StatelessWidget {
  const _People({required this.others});

  final List<PeerInfo> others;

  @override
  Widget build(BuildContext context) {
    if (others.isEmpty) {
      return Text(
        'Just you for now. Anyone on this floor can join in.',
        style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
        overflow: TextOverflow.ellipsis,
      );
    }
    return ClipRect(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: Swatch.bad, borderRadius: BorderRadius.circular(6)),
            child: Text('LIVE', style: heavy(11, color: Colors.white).copyWith(letterSpacing: 0.66)),
          ),
          for (final p in others)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: '${p.name} is drawing',
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 1, 9, 1),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Swatch.ink, width: 2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Dot(cssColor(p.color), size: 11),
                      const SizedBox(width: 5),
                      Text(p.name, style: heavy(13), maxLines: 1),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Excalidraw in its view, with a note over it while it loads (or if it can't).
class _Body extends StatelessWidget {
  const _Body({required this.board});

  final _Board board;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    // Excalidraw has the keyboard: the office (and Flutter's own shortcuts) leave every key to it.
    onKeyEvent: (_, _) => KeyEventResult.skipRemainingHandlers,
    child: ValueListenableBuilder(
      valueListenable: board.phase,
      builder: (context, phase, view) => Stack(
        children: [
          Positioned.fill(child: view!),
          if (phase != _Phase.ready)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      phase == _Phase.failed
                          ? "Couldn't load the whiteboard. Check your connection and open it again."
                          : '✏️ Getting the markers out…',
                      textAlign: TextAlign.center,
                      style: heavy(16, color: Swatch.muted),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      child: board.window.view,
    ),
  );
}
