// The whiteboard's bookkeeping that needs no browser: who's drawing, what the hint at the board
// says, and how your changes go out in batches (see whiteboard.dart for the window itself).

import 'dart:convert';

import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';
import 'hud_parts.dart';
import 'modal.dart' show clip;

/// How often your changes, and your mouse, go out while you draw (ms).
const int wbSendMs = 50;

/// Keeps each message well under the office socket's 2 MB limit.
const int wbBatchBytes = 900000;

/// Everyone else who has the whiteboard open (`drawing`: client ids), as the office knows them.
List<PeerInfo> othersDrawing(List<String> drawing, String you, Map<String, PeerInfo> peers) => [
  for (final id in drawing)
    if (id != you && peers[id] != null) peers[id]!,
];

/// The hint at the board: who's drawing on it, and E to join in. The key changes when the hint does.
(String, List<HintPart>) whiteboardHint(List<PeerInfo> others) {
  final names = others.map((p) => p.name).join(', ');
  return (
    names,
    [
      const HintTitle('📝 Whiteboard'),
      HintAside(names.isNotEmpty ? '✏️ ${clip(names, 40)} drawing' : 'draw together, live'),
      HintKey('E', names.isNotEmpty ? 'Join in' : 'Draw'),
    ],
  );
}

/// The live elements of the board in stacking order, as JSON, for Excalidraw.
String boardJson(Map<String, WbElement> board, {bool liveOnly = false}) {
  final els = board.values.where((e) => !liveOnly || !e.isDeleted).toList()..sort(byIndex);
  return jsonEncode([for (final e in els) e.raw]);
}

/// Your changes as `wb.update` batches: each under [maxBytes] of JSON. An element bigger than
/// [wbMaxElementBytes] would be refused by the office (or drop the connection), so it's left out
/// and handed to [tooBig] instead: it stays on your screen only.
List<List<WbElement>> batches(List<WbElement> out, {int maxBytes = wbBatchBytes, void Function(WbElement el)? tooBig}) {
  final result = <List<WbElement>>[];
  var batch = <WbElement>[];
  var size = 0;
  for (final el in out) {
    final n = jsonEncode(el.raw).length;
    if (n > wbMaxElementBytes) {
      tooBig?.call(el);
      continue;
    }
    if (batch.isNotEmpty && size + n > maxBytes) {
      result.add(batch);
      batch = [];
      size = 0;
    }
    batch.add(el);
    size += n;
  }
  if (batch.isNotEmpty) result.add(batch);
  return result;
}

/// Changed elements Excalidraw handed over (JSON) that are newer than what the office has: the ones to send.
List<WbElement> newerThanOffice(String json, Map<String, WbElement> board) {
  if (json.isEmpty) return const [];
  final list = jsonDecode(json);
  if (list is! List) return const [];
  return [
    for (final raw in list)
      if (raw is Map<String, dynamic>)
        if (WbElement(raw) case final el when newer(el, board[el.id])) el,
  ];
}
