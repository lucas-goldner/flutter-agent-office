// A worker that needs you is the one thing in the office that can't wait, so it's the hardest to miss
// (features/needsyou): a beacon over its desk you can see from across the room, a banner under the top bar
// saying who and what for, a flash round the edge of the screen and an alarm when it starts asking, and (if
// you ask for it) a reminder until someone's at its terminal.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../needs_you_logic.dart';
import '../nextup.dart' show needingYou;
import '../state/store.dart';
import '../world/labels.dart';
import '../world/needs_you_beacon.dart';
import '../world/space.dart' show fromEngine;

/// What the office gives the beacons, the banner and the alarm.
class NeedsYouHost {
  const NeedsYouHost({
    required this.store,
    required this.settings,
    required this.alarm,
    required this.labels,
    required this.root,
    required this.workerRoot,
    required this.deskFloor,
  });

  final Store store;
  final Settings settings;

  /// Rings the alarm; `again` is the soft reminder.
  final void Function(bool again) alarm;
  final LabelHub labels;

  /// Where the beacons go: the office's (mirrored) root.
  final Node root;

  /// Worker [id]'s model, while it's drawn.
  final Node? Function(String id) workerRoot;

  /// The height of the floor worker [id]'s desk stands on, in the office.
  final double? Function(String id) deskFloor;
}

class NeedsYouHub {
  NeedsYouHub(this.host) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _second());
  }

  final NeedsYouHost host;
  final Fresh _fresh = Fresh();
  final Reminders _reminders = Reminders();

  /// The waits the banner was put away on (see [waitKey]): it comes back for anyone else, or when one of
  /// these asks again.
  final Set<String> _hidden = {};
  final Map<String, NeedsYouBeacon> _beacons = {};
  Timer? _timer;

  /// What the banner says, or null with nobody to show.
  final ValueNotifier<BannerText?> banner = ValueNotifier(null);

  /// Bumped each time a worker starts asking: the edge of the screen flashes red.
  final ValueNotifier<int> flash = ValueNotifier(0);

  Store get _store => host.store;

  double _now() => DateTime.now().millisecondsSinceEpoch.toDouble();

  void _paintBanner() {
    final asking = needingYou(_store.workers.values);
    _hidden.removeWhere((key) => !asking.any((w) => waitKey(w) == key));
    final next = bannerText([
      for (final w in asking)
        if (!_hidden.contains(waitKey(w))) w,
    ], DateTime.now().millisecondsSinceEpoch);
    if (next != banner.value) banner.value = next;
  }

  /// The workers changed: who just started asking rings (not ones that were asking already when the page
  /// first saw them: a reload, a floor you've just arrived on), and the beacons follow who's asking.
  void sync() {
    if (_fresh.take(_store.workers).isNotEmpty) {
      flash.value++;
      if (host.settings.needsYouSound != NeedsYouSound.off) {
        host.alarm(false);
        _reminders.rang(_now());
      }
    }
    for (final id in _beacons.keys.toList()) {
      if (_store.workers[id]?.status == WorkerStatus.needsInput) continue;
      _beacons.remove(id)!.dispose();
    }
    for (final w in needingYou(_store.workers.values)) {
      if (_beacons.containsKey(w.id)) continue;
      final model = host.workerRoot(w.id);
      if (model == null) continue;
      final b = NeedsYouBeacon(host.labels, model);
      b.root.visible = false;
      host.root.add(b.root);
      _beacons[w.id] = b;
    }
    _paintBanner();
  }

  /// Another floor's workers: whoever's asking there has a wait of their own before the first reminder.
  void floorChanged() => _reminders.quiet();

  /// ✕ on the banner: put away until someone else needs you.
  void hide() {
    for (final w in needingYou(_store.workers.values)) {
      _hidden.add(waitKey(w));
    }
    _paintBanner();
  }

  /// How long it has waited ticks on, and the reminder comes round, whether or not a frame is drawn.
  void _second() {
    final asking = needingYou(_store.workers.values);
    if (asking.isNotEmpty) _paintBanner();
    if (_reminders.due(asking, _now()) && host.settings.needsYouSound == NeedsYouSound.remind) host.alarm(true);
  }

  /// Each frame: the beacons over the workers that are drawn, seen from [camPos] with you at [you] (office
  /// space). [calm]: someone asked for less motion.
  void update(double t, vm.Vector3 you, vm.Vector3 camPos, {bool calm = false}) {
    for (final MapEntry(key: id, value: b) in _beacons.entries) {
      final model = host.workerRoot(id);
      final drawn = model != null && _inView(model);
      b.root.visible = drawn;
      b.pin.visible = drawn;
      if (!drawn) continue;
      final at = fromEngine(model.globalTransform.getTranslation());
      // In its seat, the floor is the one its desk stands on; up and about, the one under its feet.
      final floor = host.deskFloor(id) ?? at.y + 0.07;
      final d = math.sqrt(math.pow(at.x - you.x, 2) + math.pow(at.z - you.z, 2));
      // Over its card or bubble (the top of either, roughly: the labels are drawn by Flutter, so their height in
      // the room isn't known here), on the worker's own scale.
      final top = 2.3;
      b.update(at, floor, top, camPos.distanceTo(at), t, beaconNearness(d), calm);
    }
  }

  /// Whether [n] is in the scene and nothing it's inside is hidden.
  static bool _inView(Node n) {
    for (Node? p = n; p != null; p = p.parent) {
      if (!p.visible) return false;
    }
    return true;
  }

  void dispose() {
    _timer?.cancel();
    for (final b in _beacons.values) {
      b.dispose();
    }
    _beacons.clear();
  }
}
