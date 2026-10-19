// Files dragged onto the page, or a picture pasted, while a worker's terminal is open (#171): the
// browser hands them over here instead of opening them in a tab. The desktop app has no drop plugin, but
// ⌘V reads files and pictures off its clipboard through the macOS runner ([clipboardFiles]).

import 'dart:typed_data';

import 'drops_stub.dart' if (dart.library.js_interop) 'drops_web.dart' as impl;

/// A file dropped or pasted: its name, type and size, and its bytes when wanted.
class DroppedFile {
  const DroppedFile({required this.name, required this.type, required this.size, required this.bytes});
  final String name;

  /// Its MIME type; empty when the browser doesn't know.
  final String type;
  final int size;
  final Future<Uint8List> Function() bytes;
}

/// Watches the whole page for files dragged over it while [active] says so: [over] as they come and go,
/// and [dropped] with what was let go. Returns a remover.
void Function() watchDrops({
  required bool Function() active,
  required void Function(bool over) over,
  required void Function(List<DroppedFile> files) dropped,
}) => impl.watchDrops(active: active, over: over, dropped: dropped);

/// Whether a paste with [files] in it is those files rather than its [text]: a screenshot has no text, and a
/// file copied in Finder comes with just its name.
bool pastedAsFiles(String text, List<String> files) {
  final t = text.trim();
  if (t.isEmpty) return true;
  final lines = t.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty);
  return lines.every((l) => files.contains(l) || files.contains(l.split('/').last));
}

/// Files copied in Finder, or a picture, on the desktop app's clipboard (none on the web, whose paste event
/// brings them: see [watchPastedFiles]).
Future<List<DroppedFile>> clipboardFiles() => impl.clipboardFiles();

/// A picture on the clipboard with no text (a screenshot), pasted while [active] says so: it goes to
/// [pasted] like a dropped file, before the terminal would paste it as nothing. Returns a remover.
void Function() watchPastedFiles(bool Function() active, void Function(List<DroppedFile> files) pasted) =>
    impl.watchPastedFiles(active, pasted);
