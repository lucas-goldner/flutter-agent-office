// Hanging pictures (hanging.ts): pick an image, then aim at a wall (the crosshair in first person,
// the mouse in third) and click. Also looking at one closer, moving, editing and taking it down.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size, VoidCallback;

import 'package:flutter/services.dart' show PhysicalKeyboardKey;
import 'package:flutter_scene/scene.dart';

import '../interop/browser.dart';
import '../net/office_socket.dart' show OfficeSocket;
import '../office_scope.dart';
import 'package:office_shared/decor.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import '../ui/decor.dart';
import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../world/gallery.dart';
import '../world/office/office.dart';
import '../world/player.dart';
import '../world/space.dart';

class _Hanging {
  _Hanging({
    required this.url,
    required this.title,
    required this.frame,
    required this.texture,
    required this.aspect,
    required this.shape,
    required this.size,
    required this.release,
    this.moving,
  });
  final String url;
  final String title;
  final int frame;
  final Texture2D texture;

  /// The image's width / height, for cropping it into the frame.
  final double aspect;

  /// The frame's width / height.
  final double shape;

  /// Longest side of the picture, in meters.
  double size;

  /// Set when moving a picture that's already up.
  final String? moving;
  final VoidCallback release;
}

typedef Spot = GhostSpot;

const _sizeKey = 'agent-office.picture-size';

double _lastSize() {
  final n = double.tryParse(storageGet(_sizeKey) ?? '');
  return n != null && n >= pictureMin && n <= pictureMax ? n : 1.2;
}

/// Hanging pictures: pick an image, then aim at a wall and click.
class Hanger {
  Hanger({
    required this.scope,
    required this.player,
    required this.office,
    required this.gallery,
    required this.camera,
  }) {
    store.topic(Topic.decor).addListener(_onDecor);
  }

  final OfficeScope scope;
  final PlayerController player;
  final Office office;
  final Gallery gallery;

  /// The camera this frame, in engine space.
  final Camera Function() camera;
  final Ghost ghost = Ghost();

  /// Called when hanging starts or stops.
  VoidCallback onChange = () {};

  Store get store => scope.store;
  OfficeSocket get net => scope.net;

  _Hanging? _cur;
  Spot? _at;

  /// Where the mouse is over the scene, for aiming in third person.
  Offset? mouse;
  Size _view = Size.zero;
  bool _wasLocked = false;

  /// A moved picture stays hidden until the office confirms where it went.
  Timer? _revealTimer;

  bool get active => _cur != null;
  bool get moving => _cur?.moving != null;

  /// Where the picture would hang right now, if you're aiming at a wall.
  Spot? get spot => _at;

  void dispose() => store.topic(Topic.decor).removeListener(_onDecor);

  void _onDecor() {
    final moving = _cur?.moving;
    if (moving != null && !store.decor.any((d) => d.id == moving)) {
      toast('Someone took that picture down', ToastKind.warn);
      cancel();
    }
    if (_revealTimer != null) _reveal();
  }

  /// Pick an image, then a spot on the wall.
  void start() => openHangDialog(onDone: (c) => _begin(c, _lastSize()));

  /// A closer look at a picture on the wall.
  void view(String id) {
    final d = store.decor.where((x) => x.id == id).firstOrNull;
    if (d == null) return;
    openPicture(scope, d, move: () => move(id), edit: () => edit(id), remove: () => net.send(DecorRemoveCmd(id)));
  }

  void move(String id) {
    final d = store.decor.where((x) => x.id == id).firstOrNull;
    if (d == null) return;
    final release = holdPicture(d.url);
    void go(Texture2D texture, double aspect) {
      if (!store.decor.any((x) => x.id == id)) return release();
      _stop();
      _cur = _Hanging(
        url: d.url,
        title: d.title ?? '',
        frame: d.frame,
        texture: texture,
        aspect: aspect,
        shape: d.w / d.h,
        size: math.max(d.w, d.h),
        moving: id,
        release: release,
      );
      gallery.hide(id);
      onChange();
    }

    loadPictureTex(d.url).then(
      (pic) => go(pic.texture, pic.aspect),
      // Still movable when its image won't load.
      onError: (Object _) async => go(await brokenTexture(), 4 / 3),
    );
  }

  void edit(String id) {
    final d = store.decor.where((x) => x.id == id).firstOrNull;
    if (d == null) return;
    openHangDialog(
      initial: d,
      onDone: (c) {
        // A new image keeps the picture's size along its longest side, in the new image's shape.
        final size = c.picture.url == d.url ? (w: d.w, h: d.h) : pictureSize(math.max(d.w, d.h), c.picture.aspect);
        net.send(
          DecorUpdateCmd(id, DecorPatch(url: c.picture.url, title: c.title, frame: c.frame, w: size.w, h: size.h)),
        );
      },
    );
  }

  /// Bigger (+1) or smaller (-1).
  void resize(int dir) {
    final cur = _cur;
    if (cur == null) return;
    // A tall picture tops out below pictureMax; start shrinking from where it stopped growing.
    final s = pictureSize(cur.size * (dir > 0 ? 1.1 : 1 / 1.1), cur.shape);
    cur.size = math.max(s.w, s.h);
  }

  /// Hangs the picture where you aim. [at] is where you clicked, in third person.
  void place([Offset? at]) {
    final cur = _cur;
    if (cur == null) return;
    if (at != null && player.view == ViewMode.third) mouse = at;
    update(_view);
    final spot = _at;
    if (spot == null) return toast('Aim at a wall to hang it there');
    if (!spot.ok) return toast("Something's already on the wall there", ToastKind.warn);
    if (cur.moving != null) {
      net.send(DecorUpdateCmd(cur.moving!, DecorPatch(wall: spot.wall, u: spot.u, y: spot.y, w: spot.w, h: spot.h)));
      // Reveal it when the office says where it went (or soon anyway, if it refused).
      _revealTimer = Timer(const Duration(milliseconds: 1500), _reveal);
    } else {
      net.send(
        DecorAddCmd(
          DecorPlacement(
            url: cur.url,
            title: cur.title.isEmpty ? null : cur.title,
            frame: cur.frame,
            wall: spot.wall,
            u: spot.u,
            y: spot.y,
            w: spot.w,
            h: spot.h,
          ),
        ),
      );
    }
    storageSet(_sizeKey, '${cur.size}');
    _stop(keepHidden: cur.moving != null);
  }

  void cancel() {
    if (_cur == null) return;
    _stop();
  }

  /// Every frame: move the ghost to where you aim. [locked]: whether the mouse is captured.
  void update(Size view, {bool? locked}) {
    _view = view;
    // Esc frees the mouse before the page ever sees the key; treat that as cancel too.
    if (locked != null) {
      if (_wasLocked && !locked && _cur != null && player.view == ViewMode.first) cancel();
      _wasLocked = locked;
    }
    final cur = _cur;
    if (cur == null || view.isEmpty) return;
    final center = Offset(view.width / 2, view.height / 2);
    final ray = camera().screenPointToRay(player.view == ViewMode.first ? center : (mouse ?? center), view);
    final hit = aimAtWall(fromEngine(ray.origin), fromEngine(ray.direction)..normalize());
    final size = pictureSize(cur.size, cur.shape);
    final on = hit == null ? null : clampToWall(hit.wall, hit.u, hit.y, size.w, size.h);
    if (hit == null || on == null) {
      _at = null;
      ghost.hide();
      return;
    }
    final rect = frameRect(wall: hit.wall, u: on.u, y: on.y, w: size.w, h: size.h);
    final ok = ![...office.fixtures(), ...gallery.rects(cur.moving)].any((r) => overlaps(rect, r));
    _at = (wall: hit.wall, u: on.u, y: on.y, w: size.w, h: size.h, ok: ok);
    ghost.show(_at!, cur.frame, cur.texture, cur.aspect);
  }

  /// Keys while hanging a picture. Walking, chat and voice work as usual. True when it was one.
  bool key(PhysicalKeyboardKey k, {required VoidCallback reach}) {
    if (_cur == null) return false;
    if (k == PhysicalKeyboardKey.escape || k == PhysicalKeyboardKey.keyF) {
      cancel();
    } else if (k == PhysicalKeyboardKey.keyE || k == PhysicalKeyboardKey.enter) {
      reach();
      place();
    } else if (k == PhysicalKeyboardKey.bracketLeft || k == PhysicalKeyboardKey.minus) {
      resize(-1);
    } else if (k == PhysicalKeyboardKey.bracketRight || k == PhysicalKeyboardKey.equal) {
      resize(1);
    } else {
      return false;
    }
    return true;
  }

  /// The hint bar while hanging: its key (to redraw only on change) and its parts.
  (String, List<HintPart>) hint() {
    final spot = _at;
    final title = spot == null
        ? '🖼️ Aim at a wall'
        : !spot.ok
        ? "🚫 Something's in the way"
        : moving
        ? '🖼️ Moving a picture'
        : '🖼️ Hanging a picture';
    return (
      'hang|$moving|${spot?.ok ?? '-'}',
      [
        HintTitle(title),
        const HintKey('Click', 'Hang'),
        const HintKey('Scroll', 'Size'),
        const HintKey('Esc', 'Cancel'),
      ],
    );
  }

  Future<void> _begin(HangChoice c, double size) async {
    final release = holdPicture(c.picture.url);
    PictureTex pic;
    try {
      pic = await loadPictureTex(c.picture.url);
    } catch (e) {
      release();
      return toast('$e', ToastKind.warn);
    }
    _stop();
    final aspect = c.picture.aspect;
    _cur = _Hanging(
      url: c.picture.url,
      title: c.title,
      frame: c.frame,
      texture: pic.texture,
      aspect: aspect,
      shape: aspect,
      size: size,
      release: release,
    );
    onChange();
  }

  /// Stops hanging. A moved picture stays hidden ([keepHidden]) until the office says where it went.
  void _stop({bool keepHidden = false}) {
    final cur = _cur;
    if (cur == null) return;
    _cur = null;
    _at = null;
    ghost.clear();
    cur.release();
    if (cur.moving != null && !keepHidden) gallery.hide(null);
    onChange();
  }

  void _reveal() {
    _revealTimer?.cancel();
    _revealTimer = null;
    if (_cur?.moving == null) gallery.hide(null);
  }
}
