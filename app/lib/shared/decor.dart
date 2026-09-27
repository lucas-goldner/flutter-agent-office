// Pictures people hang on the office walls. The server keeps the list; every browser draws them
// in frames, loading each image through the office (GET /api/image), so any image host works.

import 'dart:math' as math;

import 'json_util.dart';
import 'layout.dart';

/// The wall a picture hangs on: the same four sides as [Side].
typedef WallId = Side;

/// Where a picture hangs, what it shows and how it's framed: what a client sends.
class DecorPlacement {
  const DecorPlacement({required this.url, this.title, required this.wall, required this.u, required this.y, required this.w, required this.h, required this.frame});

  factory DecorPlacement.fromJson(Map<String, dynamic> j) => DecorPlacement(
        url: asString(j['url']),
        title: asStringOrNull(j['title']),
        wall: Side.parse(j['wall']),
        u: asDouble(j['u']),
        y: asDouble(j['y']),
        w: asDouble(j['w']),
        h: asDouble(j['h']),
        frame: asInt(j['frame']),
      );

  /// The image, somewhere online (http or https).
  final String url;
  final String? title;
  final WallId wall;

  /// The picture's center along the wall: x on the north and south walls, z on the east and west ones.
  final double u;

  /// Height of the picture's center above the floor.
  final double y;

  /// Size of the picture inside its frame, in meters.
  final double w;
  final double h;

  /// Index into [frames].
  final int frame;

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': ?title,
        'wall': wall.wire,
        'u': u,
        'y': y,
        'w': w,
        'h': h,
        'frame': frame,
      };
}

/// Some of a [DecorPlacement]'s fields, for 'decor.update' (TS `Partial<DecorPlacement>`).
class DecorPatch {
  const DecorPatch({this.url, this.title, this.wall, this.u, this.y, this.w, this.h, this.frame});

  factory DecorPatch.fromJson(Map<String, dynamic> j) => DecorPatch(
        url: asStringOrNull(j['url']),
        title: asStringOrNull(j['title']),
        wall: Side.tryParse(j['wall']),
        u: asDoubleOrNull(j['u']),
        y: asDoubleOrNull(j['y']),
        w: asDoubleOrNull(j['w']),
        h: asDoubleOrNull(j['h']),
        frame: asIntOrNull(j['frame']),
      );

  final String? url;
  final String? title;
  final WallId? wall;
  final double? u;
  final double? y;
  final double? w;
  final double? h;
  final int? frame;

  Map<String, dynamic> toJson() => {
        'url': ?url,
        'title': ?title,
        'wall': ?wall?.wire,
        'u': ?u,
        'y': ?y,
        'w': ?w,
        'h': ?h,
        'frame': ?frame,
      };
}

class Decoration extends DecorPlacement {
  const Decoration({
    required this.id,
    required this.by,
    required this.at,
    required super.url,
    super.title,
    required super.wall,
    required super.u,
    required super.y,
    required super.w,
    required super.h,
    required super.frame,
  });

  factory Decoration.fromJson(Map<String, dynamic> j) {
    final p = DecorPlacement.fromJson(j);
    return Decoration(
      id: asString(j['id']),
      by: asString(j['by']),
      at: asInt(j['at']),
      url: p.url,
      title: p.title,
      wall: p.wall,
      u: p.u,
      y: p.y,
      w: p.w,
      h: p.h,
      frame: p.frame,
    );
  }

  final String id;

  /// Who hung it.
  final String by;
  final int at;

  @override
  Map<String, dynamic> toJson() => {'id': id, ...super.toJson(), 'by': by, 'at': at};
}

typedef FrameDef = ({String name, String color});

const List<FrameDef> frames = [
  (name: 'Wood', color: '#c98b5a'),
  (name: 'Black', color: '#2b2d42'),
  (name: 'White', color: '#fffaf3'),
  (name: 'Gold', color: '#e9b949'),
  (name: 'Coral', color: '#ff8a5b'),
  (name: 'Teal', color: '#2a9d8f'),
];

/// How wide the frame is around the picture.
const double frameBorder = 0.07;

/// Bounds for the picture's longest side.
const double pictureMin = 0.3;
const double pictureMax = 3.4;
const int maxDecor = 200;
const double _floorGap = 0.4;
const double _ceilingGap = 0.05;

/// Keeps a frame clear of the frames on the wall around the corner.
const double _cornerGap = 0.15;

typedef WallDef = ({double rotY, double min, double max});

/// Each wall's inside face: the way it faces and how far it runs along u. (Zones say where it's tall enough.)
const Map<WallId, WallDef> walls = {
  Side.north: (rotY: 0, min: Floor.minX, max: Floor.maxX),
  Side.south: (rotY: math.pi, min: Floor.minX, max: Floor.maxX),
  Side.west: (rotY: math.pi / 2, min: Floor.minZ, max: Floor.maxZ),
  Side.east: (rotY: -math.pi / 2, min: Floor.minZ, max: Floor.maxZ),
};

/// A stretch of wall a picture can hang on: [u0, u1] along it, [y0, y1] up it.
typedef _Zone = ({double u0, double u1, double y0, double y1});

/// Underside of the loft's floor slab (see buildLoft in office.ts).
const double _loftUnderside = Loft.y - 0.25;

/// Where pictures can hang; each one fits inside one of its wall's zones. The loft fills the
/// south-east corner, so the south and east walls run on under its floor and again up inside it.
const Map<WallId, List<_Zone>> _zones = {
  Side.north: [(u0: Floor.minX, u1: Floor.maxX, y0: 0, y1: wallHeight)],
  Side.west: [(u0: Floor.minZ, u1: Floor.maxZ, y0: 0, y1: wallHeight)],
  Side.south: [
    (u0: Floor.minX, u1: Floor.maxX, y0: 0, y1: _loftUnderside),
    (u0: Floor.minX, u1: Loft.minX, y0: 0, y1: wallHeight),
    (u0: Loft.minX, u1: Loft.maxX, y0: Loft.y, y1: Loft.y + Loft.height),
  ],
  Side.east: [
    (u0: Floor.minZ, u1: Floor.maxZ, y0: 0, y1: _loftUnderside),
    (u0: Floor.minZ, u1: Loft.minZ, y0: 0, y1: wallHeight),
    (u0: Loft.minZ, u1: Loft.maxZ, y0: Loft.y, y1: Loft.y + Loft.height),
  ],
};

/// How high the wall goes at u (inside the loft it goes past the ceiling downstairs).
double wallTop(WallId wall, double u) {
  var top = 0.0;
  for (final z in _zones[wall]!) {
    if (u >= z.u0 && u <= z.u1) top = math.max(top, z.y1);
  }
  return top;
}

/// The world point `out` meters in front of (u, y) on a wall, and the way the wall faces.
({double x, double y, double z, double rotY}) wallPose(WallId wall, double u, double y, [double out = 0]) {
  final rotY = walls[wall]!.rotY;
  return switch (wall) {
    Side.north => (x: u, y: y, z: Floor.minZ + out, rotY: rotY),
    Side.south => (x: u, y: y, z: Floor.maxZ - out, rotY: rotY),
    Side.west => (x: Floor.minX + out, y: y, z: u, rotY: rotY),
    Side.east => (x: Floor.maxX - out, y: y, z: u, rotY: rotY),
  };
}

/// Which wall something facing `rotY` hangs on.
WallId wallFacing(double rotY) {
  final a = math.atan2(math.sin(rotY), math.cos(rotY));
  if (a.abs() < math.pi / 4) return Side.north;
  if (a.abs() > (3 * math.pi) / 4) return Side.south;
  return a > 0 ? Side.west : Side.east;
}

/// A rectangle on a wall: [u0, u1] along it, [y0, y1] up it.
class WallRect {
  const WallRect({required this.wall, required this.u0, required this.u1, required this.y0, required this.y1});

  final WallId wall;
  final double u0;
  final double u1;
  final double y0;
  final double y1;
}

/// The outline of a picture's frame on its wall.
WallRect frameRect({required WallId wall, required double u, required double y, required double w, required double h}) {
  final hw = w / 2 + frameBorder;
  final hh = h / 2 + frameBorder;
  return WallRect(wall: wall, u0: u - hw, u1: u + hw, y0: y - hh, y1: y + hh);
}

/// [frameRect] of a placed picture.
WallRect frameRectOf(DecorPlacement d) => frameRect(wall: d.wall, u: d.u, y: d.y, w: d.w, h: d.h);

bool overlaps(WallRect a, WallRect b, [double gap = 0.04]) =>
    a.wall == b.wall && a.u0 < b.u1 + gap && b.u0 < a.u1 + gap && a.y0 < b.y1 + gap && b.y0 < a.y1 + gap;

double _clamp(double v, double lo, double hi) => math.min(hi, math.max(lo, v));

/// Slides a w×h picture the least it takes for its whole frame to be on one stretch of wall, or
/// null if it's too big for any.
({double u, double y})? clampToWall(WallId wall, double u, double y, double w, double h) {
  final hw = w / 2 + frameBorder;
  final hh = h / 2 + frameBorder;
  ({double u, double y})? best;
  var bestD = double.infinity;
  for (final z in _zones[wall]!) {
    final u0 = z.u0 + _cornerGap + hw;
    final u1 = z.u1 - _cornerGap - hw;
    final y0 = z.y0 + _floorGap + hh;
    final y1 = z.y1 - _ceilingGap - hh;
    if (u0 > u1 + 1e-9 || y0 > y1 + 1e-9) continue;
    final at = (u: _clamp(u, u0, math.max(u0, u1)), y: _clamp(y, y0, math.max(y0, y1)));
    final d = (at.u - u) * (at.u - u) + (at.y - y) * (at.y - y);
    if (d < bestD) {
      best = at;
      bestD = d;
    }
  }
  return best;
}

/// A picture `size` meters on its longest side, shaped like an image of this aspect (width / height).
({double w, double h}) pictureSize(double size, double aspect) {
  final a = aspect.isFinite && aspect > 0 ? _clamp(aspect, 0.2, 5) : 1.0;
  final s = _clamp(size, pictureMin, pictureMax);
  var w = a >= 1 ? s : s * a;
  var h = a >= 1 ? s / a : s;
  // The tallest picture that still fits between the floor gap and the ceiling.
  const maxH = wallHeight - _floorGap - _ceilingGap - 2 * frameBorder;
  if (h > maxH) {
    w *= maxH / h;
    h = maxH;
  }
  return (w: w, h: h);
}

/// The tidied link, or why it won't do: exactly one of the two is set.
typedef UrlCheck = ({String? url, String? error});

/// Parses an http(s) link the way `new URL(s).href` would, closely enough for checking it.
/// Null when it isn't an absolute URL.
Uri? parseWebUrl(String s) {
  final u = Uri.tryParse(s);
  if (u == null || !u.hasScheme) return null;
  if ((u.scheme == 'http' || u.scheme == 'https') && u.host.isEmpty) return null;
  // WHATWG URLs give an empty http(s) path a '/'.
  if ((u.scheme == 'http' || u.scheme == 'https') && u.path.isEmpty) return u.replace(path: '/');
  return u;
}

/// Checks a link someone wants to hang. Returns the tidied URL, or why it won't do.
UrlCheck checkImageUrl(Object? raw) {
  final s = raw is String ? raw.trim() : '';
  if (s.isEmpty) return (url: null, error: 'Paste a link to an image');
  if (s.length > 2048) return (url: null, error: 'That link is too long');
  final u = parseWebUrl(s);
  if (u == null) return (url: null, error: "That isn't a web link. Paste an address that starts with https://");
  if (u.scheme != 'https' && u.scheme != 'http') return (url: null, error: 'Only http and https links can hang on the wall');
  return (url: u.toString(), error: null);
}

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');

bool _isInteger(Object? v) => v is num && v.isFinite && v == v.truncate();

/// JS `Math.round`: halves round up (toward +∞), not away from zero.
double _jsRound(double v) => (v + 0.5).floorToDouble();

/// Checks and tidies a placement from a client: moves it onto its wall, or says why it can't hang.
/// Exactly one of `placement` and `error` is set.
({DecorPlacement? placement, String? error}) sanitizePlacement(Object? x) {
  final o = x is Map ? x : const <String, dynamic>{};
  final url = checkImageUrl(o['url']);
  if (url.error != null) return (placement: null, error: url.error);
  final wall = Side.tryParse(o['wall']);
  if (wall == null) return (placement: null, error: 'Pick a wall to hang it on');
  double n(Object? v) => v is num && v.isFinite ? v.toDouble() : double.nan;
  var w = n(o['w']);
  var h = n(o['h']);
  final u = n(o['u']);
  final y = n(o['y']);
  if ([w, h, u, y].any((v) => v.isNaN) || w <= 0 || h <= 0) return (placement: null, error: 'That picture has no size');
  final size = pictureSize(math.max(w, h), w / h);
  w = size.w;
  h = size.h;
  final at = clampToWall(wall, u, y, w, h);
  if (at == null) return (placement: null, error: 'That picture is too big for the wall');
  final rawTitle = o['title'];
  var title = rawTitle is String ? rawTitle.replaceAll(_controlChars, ' ').trim() : '';
  if (title.length > 80) title = title.substring(0, 80);
  final f = o['frame'];
  final frame = _isInteger(f) && (f as num) >= 0 && f < frames.length ? f.toInt() : 0;
  double round(double v) => _jsRound(v * 1000) / 1000;
  return (
    placement: DecorPlacement(
      url: url.url!,
      title: title.isEmpty ? null : title,
      wall: wall,
      u: round(at.u),
      y: round(at.y),
      w: round(w),
      h: round(h),
      frame: frame,
    ),
    error: null,
  );
}
