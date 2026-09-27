// Pictures on the walls (world/gallery.ts): each one framed and hung where the office says, the
// "ghost" of the one you're hanging, and where your aim meets a wall. Images come through the
// office (GET /api/image, see ui/decor.dart), are drawn at most 1024 pixels on a side, and are
// shared by every frame that shows them.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' hide Decoration;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/decor.dart';
import '../ui/decor.dart' show loadPicture, Picture;
import '../ui/theme.dart' show kFallback, kFont;
import 'collider.dart';
export 'wall_aim.dart';
import 'office/geo.dart';
import 'text.dart' show pictureTexture;
import 'toon.dart';

// ---- Pictures -------------------------------------------------------------------------------------

/// An image ready to draw on a wall.
class PictureTex {
  PictureTex(this.url, this.texture, this.aspect);
  final String url;
  final Texture2D texture;

  /// The image's width / height.
  final double aspect;
}

/// A wall picture never needs more pixels than this, and big photos would eat GPU memory.
const int maxTexture = 1024;
final Map<String, Future<PictureTex>> _textures = {};
final Map<String, int> _holds = {};

/// Decodes a fetched image at most [maxTexture] pixels on its longest side and uploads it.
Future<Texture2D> textureOf(Picture p) async {
  var codec = await ui.instantiateImageCodec(p.bytes);
  var frame = await codec.getNextFrame();
  final iw = frame.image.width, ih = frame.image.height;
  if (math.max(iw, ih) > maxTexture) {
    frame.image.dispose();
    codec.dispose();
    final k = maxTexture / math.max(iw, ih);
    codec = await ui.instantiateImageCodec(
      p.bytes,
      targetWidth: math.max(1, (iw * k).round()),
      targetHeight: math.max(1, (ih * k).round()),
    );
    frame = await codec.getNextFrame();
  }
  try {
    return await Texture2D.fromImage(frame.image);
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

/// Loads an image once for everything that shows it. Failures aren't kept, so asking again retries.
Future<PictureTex> loadPictureTex(String url) {
  final cached = _textures[url];
  if (cached != null) return cached;
  final fresh = () async {
    final p = await loadPicture(url);
    return PictureTex(url, await textureOf(p), p.aspect);
  }();
  _textures[url] = fresh;
  fresh.then(
    (_) {},
    onError: (Object _) {
      if (identical(_textures[url], fresh)) _textures.remove(url);
    },
  );
  return fresh;
}

/// Keeps a picture loaded while something besides the walls shows it. Call the result to let go.
VoidCallback holdPicture(String url) {
  _holds[url] = (_holds[url] ?? 0) + 1;
  var held = true;
  return () {
    if (!held) return;
    held = false;
    final n = (_holds[url] ?? 1) - 1;
    if (n > 0) {
      _holds[url] = n;
    } else {
      _holds.remove(url);
    }
  };
}

/// Frees the pictures nothing shows anymore (the GPU texture goes with its last reference).
void _prunePictures(Set<String> onWalls) {
  _textures.removeWhere((url, _) => !onWalls.contains(url) && !_holds.containsKey(url));
}

/// A 512×384 card with [text] in the middle: "Loading…" and "Image unavailable".
Future<Texture2D> _notice(String text, String bg, String fg) {
  const w = 512, h = 384;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 512, 384), Paint()..color = hex(bg));
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: kFont,
        fontFamilyFallback: kFallback,
        fontSize: 44,
        fontWeight: FontWeight.w800,
        color: hex(fg),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset((w - tp.width) / 2, (h - tp.height) / 2));
  final picture = rec.endRecording();
  return pictureTexture(picture, w, h).whenComplete(picture.dispose);
}

Future<Texture2D>? _loadingTex;
Future<Texture2D>? _brokenTex;
Future<Texture2D> _loadingTexture() => _loadingTex ??= _notice('🖼️ Loading…', '#e9ecef', '#7a6f65');
Future<Texture2D> brokenTexture() => _brokenTex ??= _notice('⚠️ Image unavailable', '#ffd6e0', '#2b2d42');

// ---- Frames ---------------------------------------------------------------------------------------

/// How far the frame stands off the wall; the picture sits recessed inside it.
const double _frameDepth = 0.06;

/// The frame: a w×h rectangle's border, [frameBorder] wide, extruded with the picture's hole in it.
Geometry _frameGeometry(double w, double h) {
  final ow = w / 2 + frameBorder, oh = h / 2 + frameBorder;
  final iw = w / 2, ih = h / 2;
  final shape = Shape2()
    ..moveTo(-ow, -oh)
    ..lineTo(ow, -oh)
    ..lineTo(ow, oh)
    ..lineTo(-ow, oh);
  shape.holes.add([vm.Vector2(-iw, -ih), vm.Vector2(-iw, ih), vm.Vector2(iw, ih), vm.Vector2(iw, -ih)]);
  return extrudeShape(shape, _frameDepth);
}

class _Frame {
  _Frame(this.group, this.picture, this.material);
  final Node group;
  final Node picture;
  final UnlitMaterial material;
}

/// A framed w×h picture facing +z, its back against z = 0. It shows "Loading…" until given a texture.
_Frame _buildFrame(double w, double h, int frame) {
  final group = Node(name: 'picture');
  final color = (frame >= 0 && frame < frames.length ? frames[frame] : frames[0]).color;
  group.add(mesh(_frameGeometry(w, h), toon(hex(color)), 0, 0, 0, false));
  final mat = UnlitMaterial()..baseColorFactor = linear(hex('#e9ecef'));
  final picture = mesh(planeXY(w, h), mat, 0, 0, _frameDepth * 0.35, false);
  group.add(picture);
  return _Frame(group, picture, mat);
}

/// Shows an image of [aspect] on a w×h picture, cropped to fill it (like CSS object-fit: cover).
void _showTexture(_Frame f, double w, double h, Texture2D texture, double aspect) {
  final shape = w / h;
  final fx = aspect > shape ? shape / aspect : 1.0;
  final fy = aspect > shape ? 1.0 : aspect / shape;
  f.material
    ..baseColorTexture = texture
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
    ..baseColorTextureTransform = TextureTransform(
      offset: vm.Vector2(0.5 - fx / 2, 0.5 - fy / 2),
      scale: vm.Vector2(fx, fy),
    );
}

void _placeOnWall(Node group, WallId wall, double u, double y, [double out = 0.005]) {
  final p = wallPose(wall, u, y, out);
  group.position = vm.Vector3(p.x, p.y, p.z);
  group.rotation = yaw(p.rotY);
}

class _FrameView {
  _FrameView(this.d, this.key, this.frame, this.it);
  Decoration d;

  /// What the frame was built for; a change means building it again.
  final String key;
  final _Frame frame;
  final Interactable it;
  bool loaded = false;
}

/// The pictures on the walls. Put [group] in the office so looking at a picture targets it.
class Gallery {
  final Node group = Node(name: 'gallery');

  /// For walking up to a picture in third person.
  final List<Interactable> interactables = [];
  final Map<String, _FrameView> _frames = {};
  String? _hidden;

  void sync(List<Decoration> items) {
    final seen = <String>{};
    for (final d in items) {
      seen.add(d.id);
      final key = '${d.url}|${d.w}|${d.h}|${d.frame}';
      var v = _frames[d.id];
      if (v != null && v.key != key) {
        _drop(v);
        v = null;
      }
      if (v == null) {
        v = _build(d, key);
        _frames[d.id] = v;
      }
      v.d = d;
      _placeOnWall(v.frame.group, d.wall, d.u, d.y);
      final front = wallPose(d.wall, d.u, 0, 1.4);
      v.it
        ..x = front.x
        ..z = front.z;
    }
    for (final id in _frames.keys.toList()) {
      if (seen.contains(id)) continue;
      _drop(_frames.remove(id)!);
    }
    _refresh();
    _prunePictures({for (final d in items) d.url});
  }

  /// Hides a picture while it's being moved; null puts it back.
  void hide(String? id) {
    _hidden = id;
    _refresh();
  }

  /// The frames' outlines, except the one with id [except].
  List<WallRect> rects([String? except]) => [
    for (final v in _frames.values)
      if (v.d.id != except) frameRectOf(v.d),
  ];

  void _refresh() {
    interactables.clear();
    for (final v in _frames.values) {
      final shown = v.d.id != _hidden;
      v.frame.group.visible = shown;
      if (shown) interactables.add(v.it);
    }
  }

  _FrameView _build(Decoration d, String key) {
    final f = _buildFrame(d.w, d.h, d.frame);
    final it = Interactable(kind: InteractKind.decor, decorId: d.id, x: 0, z: 0, radius: math.max(1.6, d.w / 2 + 0.8));
    tagInteract(f.group, it);
    group.add(f.group);
    final v = _FrameView(d, key, f, it);
    bool current() => identical(_frames[d.id], v);
    _loadingTexture().then((t) {
      if (current() && !v.loaded) {
        f.material
          ..baseColorTexture = t
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
      }
    });
    loadPictureTex(d.url).then(
      (pic) {
        v.loaded = true;
        if (current()) _showTexture(f, d.w, d.h, pic.texture, pic.aspect);
      },
      onError: (Object e) async {
        v.loaded = true;
        final t = await brokenTexture();
        if (current()) _showTexture(f, d.w, d.h, t, 4 / 3);
      },
    );
    return v;
  }

  void _drop(_FrameView v) => v.frame.group.detach();
}

// ---- Hanging one ------------------------------------------------------------------------------------

/// Where a picture would hang.
typedef GhostSpot = ({WallId wall, double u, double y, double w, double h, bool ok});

/// The picture you're about to hang, following your aim, with a green (fits) or red (blocked) glow.
class Ghost {
  Ghost() {
    _halo = mesh(planeXY(1, 1), _haloMat, 0, 0, -0.002, false);
    group
      ..add(_halo)
      ..visible = false;
  }

  final Node group = Node(name: 'ghost');
  final UnlitMaterial _haloMat = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = linear(hex('#06d6a0'), 0.5);
  late final Node _halo;
  _Frame? _body;
  String _key = '';

  void show(GhostSpot at, int frame, Texture2D texture, double aspect) {
    final key = '${at.w}|${at.h}|$frame|${identityHashCode(texture)}|$aspect';
    if (key != _key) {
      _clearBody();
      final f = _buildFrame(at.w, at.h, frame);
      _showTexture(f, at.w, at.h, texture, aspect);
      _body = f;
      group.add(f.group);
      _key = key;
    }
    _halo.scale = vm.Vector3(at.w + 2 * frameBorder + 0.16, at.h + 2 * frameBorder + 0.16, 1);
    _haloMat.baseColorFactor = linear(hex(at.ok ? '#06d6a0' : '#ef476f'), 0.5);
    // Where it can't hang it floats out in front, so a board or the TV doesn't hide it.
    _placeOnWall(group, at.wall, at.u, at.y, at.ok ? 0.005 : 0.32);
    group.visible = true;
  }

  void hide() => group.visible = false;

  /// Lets go of the picture it showed.
  void clear() {
    hide();
    _clearBody();
  }

  void _clearBody() {
    _body?.group.detach();
    _body = null;
    _key = '';
  }
}
