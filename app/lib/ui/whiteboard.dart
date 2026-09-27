// The 📝 whiteboard window, and the drawing on the whiteboard in the office: a port of ui/whiteboard.ts
// and the syncing half of ui/whiteboard-app.ts. Excalidraw itself stays JavaScript (app/excalidraw/
// bridge.js, see interop/excalidraw.dart), loaded the first time either needs it, and runs in an
// HtmlElementView inside the window.
//
// Syncing works like Excalidraw's own live collaboration: every change bumps an element's version,
// each browser sends the elements it changed, and everyone merges what arrives with
// reconcileElements, which keeps the newer copy of each element.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../interop/excalidraw.dart';
import '../net/api.dart';
import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';
import '../state/store.dart';
import '../world/office/whiteboard.dart' show WhiteboardStand;
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'whiteboard_logic.dart';

/// An open whiteboard window.
class _Board {
  _Board(this.floor);

  /// The floor whose whiteboard this is.
  final String floor;
  late final ModalHandle modal;
  ExcalidrawModule? module;
  ExcalidrawApp? app;

  /// Loading, ready, or couldn't load.
  final ValueNotifier<_Phase> phase = ValueNotifier(_Phase.loading);

  /// Your changes on their way out (pictures wait here until they're up).
  final Map<String, WbElement> pending = {};
  Timer? sendTimer;
  final Map<String, WbPointerMsg> pointers = {};

  /// Elements too big to send, which you've been told about.
  final Set<String> tooBig = {};
  Timer? collabTimer;
  void Function()? removeKeys;
}

enum _Phase { loading, ready, failed }

/// The floor's whiteboard: the window, and keeping the board in the office showing the drawing.
class WhiteboardHub {
  WhiteboardHub(this.scope, this.stand) {
    store.topic(Topic.whiteboard).addListener(_changed);
    // Arriving: after the office has loaded, since drawing it means loading Excalidraw.
    _soon(1500);
  }

  final OfficeScope scope;
  final WhiteboardStand stand;
  Store get store => scope.store;

  _Board? _open;
  bool get isOpen => _open != null;

  // ---- Pictures ----------------------------------------------------------------------------------
  // Kept apart from the elements, as Excalidraw does: an image element names its picture by id (a
  // hash of the picture), and the picture itself goes up and down over HTTP.

  /// Pictures the office has, so they needn't go up again.
  final Set<String> _stored = {};
  final Map<String, Future<bool>> _uploads = {};

  /// Pictures the office didn't have when asked, and when; asked again after a while.
  final Map<String, int> _missing = {};

  String _fileUrl([String? id]) =>
      '/api/whiteboard/file?floor=${Uri.encodeComponent(store.floor ?? '')}${id != null ? '&id=${Uri.encodeComponent(id)}' : ''}';

  /// Fetches the pictures these elements (JSON) show that this page doesn't have yet, and hands them to Excalidraw.
  Future<void> _loadFiles(ExcalidrawModule m, String json) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final want = [
      for (final id in (jsonDecode(m.missingFiles(json)) as List).cast<String>())
        if (now - (_missing[id] ?? 0) > 10000) id,
    ];
    if (want.isEmpty) return;
    final got = <String>[];
    await Future.wait(
      want.map((id) async {
        final body = await Api.getText(_fileUrl(id)).catchError((_) => null);
        if (body == null) {
          _missing[id] = DateTime.now().millisecondsSinceEpoch;
          return;
        }
        got.add(body);
        _stored.add(id);
        _missing.remove(id);
      }),
    );
    if (got.isNotEmpty) m.addFiles('[${got.join(',')}]');
  }

  /// Puts a picture (JSON BinaryFileData) on the office's board; resolves to whether it's there now.
  Future<bool> _upload(String id, String json) => _uploads[id] ??= () async {
    try {
      final r = await Api.postJson(_fileUrl(), jsonDecode(json) as Map<String, dynamic>);
      if (r.ok) {
        _stored.add(id);
        return true;
      }
      toast(r.error("Couldn't put that picture on the whiteboard"), ToastKind.warn);
      return false;
    } catch (_) {
      // Offline: try again with the next change.
      _uploads.remove(id);
      return false;
    }
  }();

  // ---- The window --------------------------------------------------------------------------------

  /// Opens the floor's whiteboard, to draw on with everyone else who has it open.
  void open() {
    if (_open != null) return;
    final floor = store.floor;
    if (floor == null) return toast('Take the elevator to a floor first', ToastKind.warn);
    final b = _Board(floor);
    _open = b;
    b.modal = ModalStack.instance.show(
      (modal) => ModalWindow(
        modal: modal,
        width: 1600,
        height: double.infinity,
        bodyPadding: EdgeInsets.zero,
        scrollBody: false,
        background: Colors.white,
        title: _Title(store: store),
        body: _Body(board: b, mount: (el) => _mount(b, el)),
      ),
      escCloses: false,
      // Flutter sees Excalidraw's clicks too, and they don't stop at the window (a platform view
      // doesn't take part in hit testing), so a click on the drawing would count as one outside.
      backdropCloses: false,
      onClose: () => _closed(b),
    );
    // Esc first gets you out of whatever you're doing in Excalidraw (typing, drawing, a menu, a tool),
    // then lets go of what's selected, and once there's nothing left, closes the window.
    b.removeKeys = onWindowKeyDown((e) {
      if (e.key != 'Escape' || _open != b) return false;
      final app = b.app;
      if (app != null && !app.idle()) return false;
      if (app == null || !app.deselect()) b.modal.close();
      return true;
    });
    scope.net.send(const WbOpenCmd());
  }

  void _mount(_Board b, web.HTMLElement host) {
    host.style
      ..width = '100%'
      ..height = '100%';
    loadExcalidraw().then(
      (m) {
        if (_open != b) return;
        b.module = m;
        b.app = m.mount(
          host,
          MountOptions(
            name: '${store.project?.name ?? 'office'} whiteboard',
            elements: boardJson(store.whiteboard),
            heading: 'Draw together: everyone on this floor sees it live, and it stays up on the board',
            onChange: (() => _schedule(b)).toJS,
            onPointer: ((double x, double y, String tool, String button, String selected) {
              scope.net.send(
                WbPointerCmd(
                  WbPointer(x: x, y: y, tool: WbTool.parse(tool), button: WbButton.parse(button)),
                  selected: (jsonDecode(selected) as List).cast<String>(),
                ),
              );
            }).toJS,
            onReady: (() {
              b.phase.value = _Phase.ready;
              _loadFiles(m, boardJson(store.whiteboard));
              _collaboratorsSoon(b);
            }).toJS,
          ),
        );
      },
      onError: (_) {
        if (_open == b) b.phase.value = _Phase.failed;
      },
    );
  }

  void _schedule(_Board b) => b.sendTimer ??= Timer(const Duration(milliseconds: wbSendMs), () => _flush(b));

  /// Sends what you changed since last time: the live elements, as they are now.
  void _flush(_Board b, {bool all = false}) {
    b.sendTimer?.cancel();
    b.sendTimer = null;
    final app = b.app;
    if (app == null) return;
    for (final el in newerThanOffice(app.takeChanges(all), store.whiteboard)) {
      b.pending[el.id] = el;
    }
    final out = <WbElement>[];
    for (final el in b.pending.values.toList()) {
      // A picture goes up before the element that shows it, so nobody gets an image they can't load.
      final fileId = el.fileId;
      if (el.type == 'image' && fileId != null && !el.isDeleted && !_stored.contains(fileId)) {
        final f = app.file(fileId);
        if (f.isNotEmpty) _upload(fileId, f).then((ok) => ok && _open == b ? _schedule(b) : null);
        continue;
      }
      b.pending.remove(el.id);
      out.add(el);
    }
    if (out.isEmpty) return;
    store.drew(out);
    for (final batch in batches(
      out,
      tooBig: (el) {
        if (b.tooBig.add(el.id)) {
          toast("That's too big for the whiteboard, so only you can see it. Try it in smaller pieces.", ToastKind.warn);
        }
      },
    )) {
      scope.net.send(WbUpdateCmd(batch));
    }
  }

  /// Merges elements from the office into the drawing; whatever you're in the middle of stays yours.
  void _merge(_Board b, List<WbElement> remote) {
    final app = b.app, m = b.module;
    if (app == null || m == null || remote.isEmpty) return;
    final json = jsonEncode([for (final e in remote) e.raw]);
    app.merge(json);
    _loadFiles(m, json);
  }

  void _collaboratorsSoon(_Board b) => b.collabTimer ??= Timer(const Duration(milliseconds: 16), () => _showCollaborators(b));

  /// Everyone else with the whiteboard open, with their cursors and selections.
  void _showCollaborators(_Board b) {
    b.collabTimer = null;
    final app = b.app;
    if (app == null) return;
    app.setCollaborators(
      jsonEncode([
        for (final peer in othersDrawing(store.drawing, store.you, store.peers))
          {
            'id': peer.id,
            'name': peer.name,
            'color': peer.color,
            if (b.pointers[peer.id] case final p?) ...{
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

  void _closed(_Board b) {
    b.removeKeys?.call();
    _flush(b);
    b.sendTimer?.cancel();
    b.collabTimer?.cancel();
    b.app?.unmount();
    b.app = null;
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
        // Merges the board as the office has it, and sends what was drawn meanwhile.
        _merge(b, store.whiteboard.values.toList());
        _flush(b, all: true);
      case FloorEnterMsg _:
        b.modal.close();
      case WbUpdateMsg m:
        _merge(b, m.elements);
      case WbPointerMsg m:
        b.pointers[m.id] = m;
        _collaboratorsSoon(b);
      case WbPeopleMsg m:
        b.pointers.removeWhere((id, _) => !m.people.contains(id));
        _collaboratorsSoon(b);
      case PeerUpdateMsg _ || PeerLeaveMsg _:
        _collaboratorsSoon(b);
      default:
        break;
    }
  }

  // ---- The board in the office --------------------------------------------------------------------
  // Redrawn a moment after the drawing changes, and not more than a few times a second while someone
  // draws, or once you close the window if you have it open (it hides the board anyway).

  Timer? _timer;
  bool _busy = false;
  bool _again = false;

  void _changed() => _soon(300);

  void _soon(int ms) {
    if (_open != null) return;
    _timer ??= Timer(Duration(milliseconds: ms), _draw);
  }

  Future<void> _draw() async {
    _timer = null;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final floor = store.floor;
    try {
      final json = boardJson(store.whiteboard, liveOnly: true);
      ui.Image? drawing;
      if (json != '[]') {
        final m = await loadExcalidraw();
        await _loadFiles(m, json);
        drawing = await renderPreview(m, json, stand.fit.width, stand.fit.height);
      }
      // Rode the elevator meanwhile: this floor's drawing is on its way.
      if (store.floor == floor) await stand.show(drawing);
      drawing?.dispose();
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

/// Excalidraw in its element, with a note over it while it loads (or if it can't).
class _Body extends StatelessWidget {
  const _Body({required this.board, required this.mount});

  final _Board board;
  final void Function(web.HTMLElement el) mount;

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
      child: HtmlElementView.fromTagName(
        tagName: 'div',
        onElementCreated: (el) => mount(el as web.HTMLElement),
      ),
    ),
  );
}
