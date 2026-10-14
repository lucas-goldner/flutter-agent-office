// A floor's own layout. Port of src/server/floorplan.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart'
    show DeskLabel, FloorPlan, Wing, canLabel, cleanLabel, cleanPlan, deskById, rowDesks, signColor;
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// What hanging (or taking down) a sign did: the sign now, and the one that was there.
typedef Relabel = ({DeskLabel? label, DeskLabel? old});

/// A floor's own layout: the signs over its desks, and how far its back office is built out. Saved in
/// .agent-office/floorplan.json.
class FloorPlanStore {
  FloorPlanStore(String dataDir, {int Function()? now})
    : _file = p.join(dataDir, 'floorplan.json'),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _plan = _load();
  }

  final String _file;
  final int Function() _now;
  late FloorPlan _plan;

  FloorPlan state() => FloorPlan(wing: _plan.wing, labels: Map.unmodifiable(_plan.labels));

  int get wing => _plan.wing;

  /// Hangs a sign over a desk, or takes it down (no text). What it did, for the toast, or why it couldn't.
  ({Relabel? done, String? error}) label(String deskId, Object? text, Object? color, String by) {
    if (!canLabel(deskId)) return (done: null, error: 'Only a desk can have a sign over it');
    final clean = cleanLabel(text);
    final labels = Map.of(_plan.labels);
    final old = labels[deskId];
    if (clean.isEmpty) {
      if (old == null) return (done: (label: null, old: null), error: null);
      labels.remove(deskId);
      _set(FloorPlan(wing: _plan.wing, labels: labels));
      return (done: (label: null, old: old), error: null);
    }
    final label = DeskLabel(text: clean, color: signColor(color), by: by, at: _now());
    labels[deskId] = label;
    _set(FloorPlan(wing: _plan.wing, labels: labels));
    return (done: (label: label, old: old), error: null);
  }

  /// Knocks the back office out another row: the ids of the desks that came with it, or why not.
  ({List<String>? desks, String? error}) expand() {
    if (_plan.wing >= Wing.rows) return (desks: null, error: "The back office can't go back any further");
    _set(FloorPlan(wing: _plan.wing + 1, labels: _plan.labels));
    return (desks: [for (final d in rowDesks(_plan.wing)) d.id], error: null);
  }

  /// Walls up the back office's last row, unless someone's working there ([taken]). What went, or why not.
  ({List<String>? desks, String? error}) shrink(bool Function(String deskId) taken) {
    if (_plan.wing <= 0) return (desks: null, error: 'There is no back office to wall up');
    final row = rowDesks(_plan.wing);
    final busy = row.where((d) => taken(d.id)).firstOrNull;
    if (busy != null) {
      return (
        desks: null,
        error: "Someone's at ${deskById[busy.id]?.label ?? 'a desk'} back there: send them home first",
      );
    }
    _set(FloorPlan(wing: _plan.wing - 1, labels: _plan.labels));
    return (desks: [for (final d in row) d.id], error: null);
  }

  void _set(FloorPlan plan) {
    _plan = plan;
    _save();
  }

  FloorPlan _load() {
    final f = File(_file);
    if (!f.existsSync()) return cleanPlan(null);
    try {
      return cleanPlan(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      // a broken file just means the office as it comes
      return cleanPlan(null);
    }
  }

  void _save() {
    try {
      writePrivateFile(_file, jsonPretty(_plan.toJson()));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}
