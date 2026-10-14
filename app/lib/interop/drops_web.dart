// Drag and drop, and pasted pictures, with package:web.

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'drops.dart';

bool _hasFiles(web.DragEvent e) {
  final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
  return types.any((t) => t.toDart == 'Files');
}

List<DroppedFile> _files(web.FileList? list) {
  if (list == null) return const [];
  return [
    for (var i = 0; i < list.length; i++)
      if (list.item(i) case final f?)
        DroppedFile(
          name: f.name,
          type: f.type,
          size: f.size,
          bytes: () async => (await f.arrayBuffer().toDart).toDart.asUint8List(),
        ),
  ];
}

void Function() watchDrops({
  required bool Function() active,
  required void Function(bool over) over,
  required void Function(List<DroppedFile> files) dropped,
}) {
  // The whole screen is the drop zone while the terminal is open, so a near miss doesn't open the file in
  // the browser. dragenter and dragleave come for every element passed over, so they're counted.
  var depth = 0;
  void end() {
    depth = 0;
    over(false);
  }

  final enter = ((web.DragEvent e) {
    if (!active() || !_hasFiles(e)) return;
    e.preventDefault();
    depth++;
    over(true);
  }).toJS;
  final overIt = ((web.DragEvent e) {
    if (!active() || !_hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer?.dropEffect = 'copy';
  }).toJS;
  final leave = ((web.DragEvent e) {
    if (!active() || !_hasFiles(e)) return;
    if (--depth <= 0) end();
  }).toJS;
  final drop = ((web.DragEvent e) {
    if (!active() || !_hasFiles(e)) return;
    e.preventDefault();
    end();
    dropped(_files(e.dataTransfer?.files));
  }).toJS;
  final doc = web.document;
  doc.addEventListener('dragenter', enter);
  doc.addEventListener('dragover', overIt);
  doc.addEventListener('dragleave', leave);
  doc.addEventListener('drop', drop);
  return () {
    doc.removeEventListener('dragenter', enter);
    doc.removeEventListener('dragover', overIt);
    doc.removeEventListener('dragleave', leave);
    doc.removeEventListener('drop', drop);
  };
}

void Function() watchPastedFiles(bool Function() active, void Function(List<DroppedFile> files) pasted) {
  final handler = ((web.ClipboardEvent e) {
    if (!active()) return;
    final data = e.clipboardData;
    final files = _files(data?.files);
    if (files.isEmpty || (data?.getData('text/plain') ?? '').isNotEmpty) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    pasted(files);
  }).toJS;
  // Before interceptPaste (portable_web.dart), which is also on the capture phase: added first, it runs
  // first, and it stops the event when it's a picture.
  web.document.addEventListener('paste', handler, true.toJS);
  return () => web.document.removeEventListener('paste', handler, true.toJS);
}
