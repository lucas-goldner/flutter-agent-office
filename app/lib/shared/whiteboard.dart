// The whiteboard: an Excalidraw drawing everyone on a floor draws on together. The server keeps
// each floor's elements and passes every change on; browsers merge them the way Excalidraw's own
// live collaboration does, by each element's version (see `newer`).

import 'json_util.dart';

/// An Excalidraw element, as far as the office needs to know: what it takes to merge two copies.
/// Everything else about it (its shape, points, text, colors…) rides along untouched in [raw].
class WbElement {
  WbElement(Map<String, dynamic> raw) : raw = Map.unmodifiable(raw);

  factory WbElement.fromJson(Map<String, dynamic> json) => WbElement(json);

  /// The whole element as Excalidraw has it.
  final Map<String, dynamic> raw;

  String get id => asString(raw['id']);
  String get type => asString(raw['type']);

  /// Goes up by one with every change to the element.
  int get version => asInt(raw['version']);

  /// Random, changed with the version: breaks the tie when two people change it at once.
  double get versionNonce => asDouble(raw['versionNonce']);
  bool get isDeleted => asBool(raw['isDeleted']);

  /// Its place in the stacking order, a fractional index that sorts as a plain string.
  String? get index => asStringOrNull(raw['index']);

  /// When it last changed (epoch ms).
  int? get updated => asIntOrNull(raw['updated']);
  String? get fileId => asStringOrNull(raw['fileId']);

  Map<String, dynamic> toJson() => raw;

  @override
  String toString() => 'WbElement($id v$version)';
}

/// A picture on the whiteboard: Excalidraw's BinaryFileData.
class WbFile {
  const WbFile({required this.id, required this.mimeType, required this.dataURL, required this.created});

  factory WbFile.fromJson(Map<String, dynamic> j) =>
      WbFile(id: asString(j['id']), mimeType: asString(j['mimeType']), dataURL: asString(j['dataURL']), created: asInt(j['created']));

  final String id;
  final String mimeType;
  final String dataURL;
  final int created;

  Map<String, dynamic> toJson() => {'id': id, 'mimeType': mimeType, 'dataURL': dataURL, 'created': created};
}

enum WbTool implements WireEnum {
  pointer('pointer'),
  laser('laser');

  const WbTool(this.wire);
  @override
  final String wire;

  static WbTool parse(Object? v) => parseWire(values, v, WbTool.pointer);
}

enum WbButton implements WireEnum {
  up('up'),
  down('down');

  const WbButton(this.wire);
  @override
  final String wire;

  static WbButton parse(Object? v) => parseWire(values, v, WbButton.up);
}

/// Where someone's mouse is on the whiteboard, in the drawing's own coordinates.
class WbPointer {
  const WbPointer({required this.x, required this.y, required this.tool, required this.button});

  factory WbPointer.fromJson(Map<String, dynamic> j) =>
      WbPointer(x: asDouble(j['x']), y: asDouble(j['y']), tool: WbTool.parse(j['tool']), button: WbButton.parse(j['button']));

  final double x;
  final double y;
  final WbTool tool;
  final WbButton button;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'tool': tool.wire, 'button': button.wire};
}

/// A floor's whiteboard, for whoever arrives there.
class WhiteboardView {
  const WhiteboardView({required this.elements, required this.people});

  factory WhiteboardView.fromJson(Map<String, dynamic> j) =>
      WhiteboardView(elements: asList(j['elements'], WbElement.fromJson), people: asStringList(j['people']));

  /// Every element, deleted ones too, so a deletion reaches whoever still has the element.
  final List<WbElement> elements;

  /// Who has the whiteboard open right now (client ids).
  final List<String> people;

  Map<String, dynamic> toJson() => {'elements': [for (final e in elements) e.toJson()], 'people': people};
}

/// The most elements a board keeps, deleted ones included.
const int wbMaxElements = 20000;

/// One element as JSON: a long freehand stroke is the biggest.
const int wbMaxElementBytes = 512 * 1024;

/// The whole drawing as JSON.
const int wbMaxBytes = 16 * 1024 * 1024;

/// One picture, as a data: URL.
const int wbMaxFileBytes = 6 * 1024 * 1024;

/// Every picture on a board together.
const int wbMaxFilesBytes = 64 * 1024 * 1024;

/// What a picture may be: Excalidraw's image types.
const List<String> wbImageTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml', 'image/bmp', 'image/x-icon', 'image/avif', 'image/jfif'];

final RegExp _idRe = RegExp(r'^[\w-]{1,100}$');

/// Whether `a` should replace `b`: it's a later version, or the same version with the lower nonce.
/// That's Excalidraw's rule, so every copy of the board settles on the same element.
bool newer(WbElement a, WbElement? b) =>
    b == null || a.version > b.version || (a.version == b.version && a.versionNonce < b.versionNonce);

const int _maxSafeInteger = 9007199254740991;

/// An element as someone sent it, if it has what merging needs; anything else is dropped.
WbElement? checkElement(Object? raw) {
  if (raw is! Map) return null;
  final e = Map<String, dynamic>.from(raw);
  final id = e['id'];
  if (id is! String || !_idRe.hasMatch(id)) return null;
  final type = e['type'];
  if (type is! String || type.isEmpty || type.length > 32 || type == 'selection') return null;
  final version = e['version'];
  if (version is! num || !version.isFinite || version != version.truncate() || version.abs() > _maxSafeInteger || version < 1) return null;
  final nonce = e['versionNonce'];
  if (nonce is! num || !nonce.isFinite) return null;
  if (e.containsKey('isDeleted') && e['isDeleted'] != null && e['isDeleted'] is! bool) return null;
  final index = e['index'];
  if (index != null && (index is! String || index.length > 200)) return null;
  final fileId = e['fileId'];
  if (fileId != null && (fileId is! String || !_idRe.hasMatch(fileId))) return null;
  return WbElement(e);
}

/// A picture as someone sent it, or why it can't go on the board: exactly one of the two is set.
({WbFile? file, String? error}) checkFile(Object? raw, {int Function()? now}) {
  if (raw is! Map) return (file: null, error: 'Bad picture');
  final id = raw['id'];
  if (id is! String || !_idRe.hasMatch(id)) return (file: null, error: 'Bad picture id');
  final mimeType = raw['mimeType'];
  if (mimeType is! String || !wbImageTypes.contains(mimeType)) {
    return (file: null, error: 'The whiteboard only takes pictures (PNG, JPEG, GIF, WebP, SVG…)');
  }
  final dataURL = raw['dataURL'];
  if (dataURL is! String || !dataURL.startsWith('data:$mimeType')) return (file: null, error: 'Bad picture data');
  if (dataURL.length > wbMaxFileBytes) {
    return (file: null, error: 'That picture is too big for the whiteboard (over ${wbMaxFileBytes ~/ 1024 ~/ 1024} MB)');
  }
  final c = raw['created'];
  final created = c is num && c.isFinite ? c.toInt() : (now ?? () => DateTime.now().millisecondsSinceEpoch)();
  return (file: WbFile(id: id, mimeType: mimeType, dataURL: dataURL, created: created), error: null);
}

/// Elements in stacking order, bottom first: by fractional index, which compares as a plain string.
int byIndex(WbElement a, WbElement b) {
  final x = a.index ?? '';
  final y = b.index ?? '';
  if (x == y) return a.id.compareTo(b.id).sign;
  // Elements without an index go on top; Excalidraw gives them one when it loads them.
  if (x.isEmpty) return 1;
  if (y.isEmpty) return -1;
  return x.compareTo(y) < 0 ? -1 : 1;
}
