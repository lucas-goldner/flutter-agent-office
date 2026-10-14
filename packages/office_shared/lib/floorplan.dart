// A floor's own layout on top of the office everyone shares: the signs hung over its desks, and how
// far its back office is built out (see [Wing] in layout.dart). Saved by the server's floorplan.
// Ported from src/shared/floorplan.ts.

import 'json_util.dart';
import 'layout.dart';

/// A sign hanging from the ceiling over a desk, naming what it's for ("Operations", "Code cleanup").
class DeskLabel {
  const DeskLabel({required this.text, required this.color, required this.by, required this.at});

  factory DeskLabel.fromJson(Map<String, dynamic> j) =>
      DeskLabel(text: asString(j['text']), color: asString(j['color']), by: asString(j['by']), at: asInt(j['at']));

  final String text;

  /// One of [signColors].
  final String color;
  final String by;
  final int at;

  Map<String, dynamic> toJson() => {'text': text, 'color': color, 'by': by, 'at': at};
}

class FloorPlan {
  const FloorPlan({this.wing = 0, this.labels = const {}});

  /// Read off the wire as it is; [cleanPlan] for a plan that can't be trusted.
  factory FloorPlan.fromJson(Map<String, dynamic> j) => FloorPlan(
    wing: asInt(j['wing']),
    labels: {
      for (final e in asMap(j['labels']).entries)
        if (e.value is Map) e.key: DeskLabel.fromJson(asMap(e.value)),
    },
  );

  /// How many rows the back office is built out (0 is just the room), up to [Wing.rows].
  final int wing;

  /// Signs by desk id.
  final Map<String, DeskLabel> labels;

  Map<String, dynamic> toJson() => {
    'wing': wing,
    'labels': {for (final e in labels.entries) e.key: e.value.toJson()},
  };
}

const FloorPlan emptyPlan = FloorPlan();

/// The longest a sign's text may be, in characters.
const int maxLabel = 32;

/// What a sign can be painted: its board, and the ink its letters are in.
const List<({String color, String ink, String name})> signColors = [
  (color: '#2b2d42', ink: '#fffaf3', name: 'Navy'),
  (color: '#ef476f', ink: '#fffaf3', name: 'Pink'),
  (color: '#f78c6b', ink: '#2b2d42', name: 'Orange'),
  (color: '#ffd166', ink: '#2b2d42', name: 'Yellow'),
  (color: '#06d6a0', ink: '#2b2d42', name: 'Green'),
  (color: '#118ab2', ink: '#fffaf3', name: 'Blue'),
  (color: '#9b5de5', ink: '#fffaf3', name: 'Purple'),
];

/// A few to start from, in the label window.
const List<String> labelIdeas = [
  'Operations',
  'Code cleanup',
  'Frontend',
  'Backend',
  'Bug fixes',
  'Docs',
  'Infra',
  'Research',
];

/// Desks that can have a sign: the room's and the back office's, not the bean bags, kiosks or meeting chairs.
final Set<String> _labelable = {
  for (final d in [...desks, ...wingDesks]) d.id,
};

bool canLabel(String deskId) => _labelable.contains(deskId);

final RegExp _controls = RegExp('[\u0000-\u001f\u007f-\u009f  ]+');
final RegExp _spaces = RegExp(r'\s+');

/// A sign's text as it's hung: one line, no control characters, at most [maxLabel] characters.
String cleanLabel(Object? text) {
  if (text is! String) return '';
  final flat = text.replaceAll(_controls, ' ').replaceAll(_spaces, ' ').trim();
  final chars = flat.runes.take(maxLabel);
  return String.fromCharCodes(chars).trim();
}

/// The paint a sign asked for, or the first one when it's none of [signColors].
String signColor(Object? color) =>
    signColors.where((c) => c.color == color).firstOrNull?.color ?? signColors.first.color;

/// The ink for letters on a board painted [color].
String signInk(String color) => signColors.where((c) => c.color == color).firstOrNull?.ink ?? signColors.first.ink;

/// A plan read back from disk (or anywhere else it can't be trusted): what's valid of it.
FloorPlan cleanPlan(Object? raw) {
  final r = raw is Map ? raw : const {};
  final labels = <String, DeskLabel>{};
  final ls = r['labels'];
  if (ls is Map) {
    for (final MapEntry(:key, :value) in ls.entries) {
      if (key is! String || !canLabel(key) || value is! Map) continue;
      final text = cleanLabel(value['text']);
      if (text.isEmpty) continue;
      labels[key] = DeskLabel(
        text: text,
        color: signColor(value['color']),
        by: value['by'] is String ? value['by'] as String : '?',
        at: value['at'] is num ? (value['at'] as num).toInt() : 0,
      );
    }
  }
  return FloorPlan(wing: wingLevel(r['wing']), labels: labels);
}

/// The desks a row of the back office brings: [row] from 1.
List<DeskDef> rowDesks(int row) => [
  for (final d in wingDesks)
    if (d.wing == row) d,
];

/// How many more rows the back office can take.
int roomToGrow(FloorPlan plan) => Wing.rows - plan.wing;
