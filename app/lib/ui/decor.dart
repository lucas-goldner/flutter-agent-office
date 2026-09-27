// Pictures on the walls: the dialog to pick an image, a title and a frame, and the closer look at
// one that's hanging (ui/decor.ts). Placing it on a wall is the world's job (hanging.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Decoration;
import 'package:http/http.dart' as http;

import '../interop/browser.dart';
import '../interop/open_link.dart';
import '../office_scope.dart';
import '../shared/decor.dart';
import '../state/store.dart';
import 'confirm.dart';
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

// ---- Pictures -------------------------------------------------------------------------------------

/// An image the office fetched for us: its bytes and its width / height.
class Picture {
  Picture(this.url, this.bytes, this.aspect);
  final String url;
  final Uint8List bytes;
  final double aspect;
}

class PictureError implements Exception {
  PictureError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The office fetches images for us, so a picture shows up whatever its host allows.
String imageUrl(String url) => '/api/image?url=${Uri.encodeQueryComponent(url)}';

final Map<String, Future<Picture>> _pictures = {};

Future<Picture> _fetchPicture(String url) async {
  http.Response res;
  try {
    res = await http.get(Uri.parse(imageUrl(url)));
  } catch (_) {
    throw PictureError("Couldn't reach the office to load that image");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    var error = "The office couldn't load that image (${res.statusCode})";
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] is String) error = body['error'] as String;
    } catch (_) {
      // not JSON
    }
    throw PictureError(error);
  }
  try {
    final codec = await ui.instantiateImageCodec(res.bodyBytes);
    final frame = await codec.getNextFrame();
    final aspect = frame.image.width / frame.image.height;
    frame.image.dispose();
    codec.dispose();
    return Picture(url, res.bodyBytes, aspect);
  } catch (_) {
    throw PictureError("Your browser can't show that image");
  }
}

/// Loads an image once for everything that shows it. Failures aren't kept, so asking again retries.
Future<Picture> loadPicture(String url) {
  final cached = _pictures[url];
  if (cached != null) return cached;
  final fresh = _fetchPicture(url);
  _pictures[url] = fresh;
  fresh.catchError((Object _) {
    if (identical(_pictures[url], fresh)) _pictures.remove(url);
    return Picture(url, Uint8List(0), 1);
  });
  return fresh;
}

// ---- Hanging one ----------------------------------------------------------------------------------

class HangChoice {
  HangChoice({required this.picture, required this.title, required this.frame});
  final Picture picture;
  final String title;
  final int frame;
}

const _frameKey = 'agent-office.frame';

int _lastFrame() {
  final n = int.tryParse(storageGet(_frameKey) ?? '');
  return n != null && n >= 0 && n < frames.length ? n : 0;
}

const _tip = 'Paste a link to an image. Online, right-click any picture and choose “Copy image address”.';

/// Pick an image, a title and a frame. Editing a picture ([initial]) fills them in.
ModalHandle openHangDialog({Decoration? initial, required void Function(HangChoice choice) onDone}) =>
    ModalStack.instance.show((modal) => _HangWindow(modal: modal, initial: initial, onDone: onDone));

class _HangWindow extends StatefulWidget {
  const _HangWindow({required this.modal, required this.initial, required this.onDone});
  final ModalHandle modal;
  final Decoration? initial;
  final void Function(HangChoice choice) onDone;

  @override
  State<_HangWindow> createState() => _HangWindowState();
}

enum _Status { tip, loading, error, none }

class _HangWindowState extends State<_HangWindow> {
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late int _frame = widget.initial?.frame ?? _lastFrame();
  Picture? _pic;
  int _seq = 0;
  bool _loading = false;

  /// Enter was pressed before the image loaded: go on as soon as it does.
  bool _submitWhenLoaded = false;
  Timer? _timer;
  (_Status, String) _status = (_Status.tip, _tip);

  @override
  void initState() {
    super.initState();
    if (_url.text.isNotEmpty) _load();
  }

  @override
  void dispose() {
    _seq++;
    _timer?.cancel();
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final my = ++_seq;
    setState(() {
      _loading = false;
      _pic = null;
    });
    final raw = _url.text.trim();
    if (raw.isEmpty) return setState(() => _status = (_Status.tip, _tip));
    final checked = checkImageUrl(raw);
    if (checked.error != null) return setState(() => _status = (_Status.error, checked.error!));
    setState(() {
      _status = (_Status.loading, 'Loading the image…');
      _loading = true;
    });
    try {
      final p = await loadPicture(checked.url!);
      if (my != _seq || !mounted) return;
      setState(() {
        _loading = false;
        _pic = p;
        _status = (_Status.none, '');
      });
      if (_submitWhenLoaded) _finish();
    } catch (err) {
      if (my != _seq || !mounted) return;
      setState(() {
        _loading = false;
        _submitWhenLoaded = false;
        _status = (_Status.error, '$err');
      });
    }
  }

  void _typed(String _) {
    _submitWhenLoaded = false;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), _load);
  }

  /// With the button disabled, Enter would do nothing: go on once the image is in.
  void _enter() {
    if (_pic != null) return _finish();
    if (_url.text.trim().isEmpty) return;
    _submitWhenLoaded = true;
    if (!_loading) {
      _timer?.cancel();
      _load();
    }
  }

  void _finish() {
    final pic = _pic;
    if (pic == null) return;
    storageSet(_frameKey, '$_frame');
    final choice = HangChoice(picture: pic, title: _title.text.trim(), frame: _frame);
    widget.modal.close();
    widget.onDone(choice);
  }

  @override
  Widget build(BuildContext context) {
    final init = widget.initial;
    return ModalWindow(
      modal: widget.modal,
      width: 560,
      title: Text(init != null ? '🖼️ Edit picture' : '🖼️ Hang a picture'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Image link'),
          BoxInput(
            controller: _url,
            autofocus: init == null,
            hint: 'https://…/picture.png',
            onChanged: _typed,
            onSubmitted: (_) => _enter(),
          ),
          const FieldLabel('Title', top: 12),
          BoxInput(
            controller: _title,
            autofocus: init != null,
            maxLength: 80,
            hint: 'Optional',
            onSubmitted: (_) => _enter(),
          ),
          const FieldLabel('Frame', top: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (i, f) in frames.indexed)
                SmallButton(
                  label: f.name,
                  leading: Dot(cssColor(f.color)),
                  kind: i == _frame ? BtnKind.on : BtnKind.plain,
                  onPressed: () => setState(() => _frame = i),
                ),
            ],
          ),
          if (_pic != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Center(child: FramedPicture(_pic!, frameColor: cssColor(frames[_frame].color))),
            ),
          if (_status.$1 != _Status.none) _statusLine(),
        ],
      ),
      footer: Row(
        children: [
          FooterNote(init != null ? '' : 'Then aim at a wall and click.'),
          const SizedBox(width: 8),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          const SizedBox(width: 8),
          OfficeButton(
            label: init != null ? 'Save' : 'Pick a spot on the wall →',
            kind: BtnKind.primary,
            onPressed: _pic == null ? null : _finish,
          ),
        ],
      ),
    );
  }

  Widget _statusLine() {
    final (kind, text) = _status;
    if (kind == _Status.error) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFD6E0),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Swatch.ink, width: 2),
        ),
        child: Text(text, style: heavy(13, weight: FontWeight.w700).copyWith(height: 1.45)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          if (kind == _Status.loading) ...[const Spinner(), const SizedBox(width: 8)],
          Expanded(
            child: Text(
              text,
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w700).copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// The preview in its frame: a 12px border in the frame's colour, a 3px ink outline and a shadow.
class FramedPicture extends StatelessWidget {
  const FramedPicture(this.picture, {super.key, required this.frameColor, this.maxHeight = 240});

  final Picture picture;
  final Color frameColor;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Swatch.ink,
      boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
    ),
    padding: const EdgeInsets.all(3),
    child: Container(
      color: frameColor,
      padding: const EdgeInsets.all(12),
      child: Container(
        color: Colors.white,
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(aspectRatio: picture.aspect, child: _image(picture)),
      ),
    ),
  );
}

Widget _image(Picture p) => Image.memory(p.bytes, fit: BoxFit.contain, gaplessPlayback: true);

// ---- A closer look ----------------------------------------------------------------------------------

/// A closer look at a picture on the wall, with who hung it and ways to move, edit or take it down.
ModalHandle openPicture(
  OfficeScope scope,
  Decoration d, {
  required VoidCallback move,
  required VoidCallback edit,
  required VoidCallback remove,
}) => ModalStack.instance.show(
  (modal) => _PictureWindow(scope: scope, modal: modal, d: d, move: move, edit: edit, remove: remove),
);

class _PictureWindow extends StatefulWidget {
  const _PictureWindow({
    required this.scope,
    required this.modal,
    required this.d,
    required this.move,
    required this.edit,
    required this.remove,
  });
  final OfficeScope scope;
  final ModalHandle modal;
  final Decoration d;
  final VoidCallback move;
  final VoidCallback edit;
  final VoidCallback remove;

  @override
  State<_PictureWindow> createState() => _PictureWindowState();
}

class _PictureWindowState extends State<_PictureWindow> with ListenTo {
  late final Future<Picture> _pic = loadPicture(widget.d.url);

  @override
  void initState() {
    super.initState();
    // Someone else took it down while you were looking.
    final store = widget.scope.store;
    listenTo(store.topic(Topic.decor), () {
      if (!store.decor.any((x) => x.id == widget.d.id)) widget.modal.close();
    });
  }

  void _then(VoidCallback fn) {
    widget.modal.close();
    fn();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final name = d.title != null && d.title!.isNotEmpty ? d.title! : 'A picture';
    final maxH = MediaQuery.sizeOf(context).height - 260;
    return ModalWindow(
      modal: widget.modal,
      width: 980,
      title: Text('🖼️ $name'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 200),
            padding: const EdgeInsets.all(16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Swatch.ink,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Swatch.ink, width: kBorder),
            ),
            child: FutureBuilder(
              future: _pic,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD6E0),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Swatch.ink, width: 2),
                    ),
                    child: Text('⚠️ ${snap.error}', style: heavy(13, weight: FontWeight.w700)),
                  );
                }
                final p = snap.data;
                if (p == null) return const Spinner(light: true);
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH.clamp(120, 2000)),
                  child: _image(p),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Hung by ${d.by} · ${timeAgo(d.at)} · '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => openInNewTab(d.url),
                        child: Text(
                          'Open the original ↗',
                          style: heavy(
                            13,
                            color: const Color(0xFF1D6FD6),
                          ).copyWith(decoration: TextDecoration.underline),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
      footer: Row(
        children: [
          OfficeButton(
            label: 'Take down',
            kind: BtnKind.danger,
            onPressed: () => confirmDialog(
              'Take this picture down?',
              'It comes off the wall for everyone.',
              'Take down',
              () => _then(widget.remove),
            ),
          ),
          const Spacer(),
          OfficeButton(label: '✏️ Edit', onPressed: () => _then(widget.edit)),
          const SizedBox(width: 8),
          OfficeButton(label: '↔️ Move', kind: BtnKind.primary, onPressed: () => _then(widget.move)),
        ],
      ),
    );
  }
}
