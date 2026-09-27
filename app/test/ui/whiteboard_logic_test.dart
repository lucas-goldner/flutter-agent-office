import 'dart:convert';

import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';
import 'package:agent_office/ui/hud_parts.dart';
import 'package:agent_office/ui/whiteboard_logic.dart';
import 'package:flutter_test/flutter_test.dart';

WbElement el(String id, int version, {double nonce = 1, String? index, bool deleted = false, String text = ''}) => WbElement({
  'id': id,
  'type': 'rectangle',
  'version': version,
  'versionNonce': nonce,
  'index': ?index,
  'isDeleted': deleted,
  'text': text,
});

PeerInfo peer(String id, String name) => PeerInfo.fromJson({'id': id, 'name': name, 'color': '#118ab2'});

void main() {
  test('the hint says who else is drawing', () {
    final peers = {'me': peer('me', 'Ada'), 'b': peer('b', 'Bob'), 'c': peer('c', 'Cy')};
    var (key, parts) = whiteboardHint(othersDrawing(const [], 'me', peers));
    expect(key, '');
    expect((parts[1] as HintAside).text, 'draw together, live');
    expect((parts[2] as HintKey).label, 'Draw');
    final drawing = ['me', 'b', 'c', 'gone'];
    (key, parts) = whiteboardHint(othersDrawing(drawing, 'me', peers));
    expect(key, 'Bob, Cy');
    expect((parts[1] as HintAside).text, '✏️ Bob, Cy drawing');
    expect((parts[2] as HintKey).label, 'Join in');
    expect(othersDrawing(drawing, 'me', peers).map((p) => p.id), ['b', 'c']);
  });

  test('only changes newer than the office go out', () {
    final store = {for (final e in [el('a', 2), el('b', 1)]) e.id: e};
    final json = jsonEncode([el('a', 2).raw, el('b', 2).raw, el('c', 1).raw]);
    expect(newerThanOffice(json, store).map((e) => e.id), ['b', 'c']);
    expect(newerThanOffice('', store), isEmpty);
  });

  test('the board goes to Excalidraw in stacking order, and to the office board without deletions', () {
    final store = {for (final e in [el('x', 1, index: 'a2'), el('y', 1, index: 'a1'), el('z', 1, index: 'a0', deleted: true)]) e.id: e};
    List<String> ids(String json) => [for (final e in jsonDecode(json) as List) (e as Map)['id'] as String];
    expect(ids(boardJson(store)), ['z', 'y', 'x']);
    expect(ids(boardJson(store, liveOnly: true)), ['y', 'x']);
  });

  test('changes go out in batches under the limit, and a giant element stays home', () {
    final big = el('big', 1, text: 'x' * (wbMaxElementBytes + 10));
    final small = [for (var i = 0; i < 5; i++) el('s$i', 1, text: 'y' * 300)];
    final tooBig = <String>[];
    final out = batches([small[0], big, ...small.skip(1)], maxBytes: 1000, tooBig: (e) => tooBig.add(e.id));
    expect(tooBig, ['big']);
    expect(out.expand((b) => b).map((e) => e.id), ['s0', 's1', 's2', 's3', 's4']);
    expect(out.length, greaterThan(1));
    for (final b in out) {
      expect(b.length == 1 || b.fold<int>(0, (n, e) => n + jsonEncode(e.raw).length) <= 1000, isTrue);
    }
  });
}
