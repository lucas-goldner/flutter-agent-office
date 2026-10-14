// The building's map and whoever its floor has kept, as the store follows them (state/slices/map.ts and
// jail.ts upstream).
import 'package:agent_office/state/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart';

Map<String, dynamic> peer(String id, {String? seat}) => {
  'id': id,
  'name': id,
  'color': '#ff8a5b',
  'look': {'skin': 0, 'hair': 0, 'style': 0},
  'x': 0,
  'y': 0,
  'z': 0,
  'rotY': 0,
  'moving': false,
  'voice': false,
  'muted': false,
  'sharing': false,
  'seat': ?seat,
  'floor': 'f1',
};

void main() {
  test("the building's map, and the plan of it: where everything is on it", () {
    final store = Store();
    expect(store.plan().id, officeMap);
    var maps = 0;
    store.topic(Topic.map).addListener(() => maps++);
    store.apply(
      ServerMsg.parse({
        't': 'map',
        'state': {'pick': 'castle', 'custom': [], 'by': 'Ada', 'at': 1},
      }),
    );
    expect(maps, 1);
    expect(store.plan().id, 'castle');
    expect(store.plan().throne, isNotNull);
    expect(store.map.by, 'Ada');
    // A pick nobody can load is the office.
    store.apply(
      ServerMsg.parse({
        't': 'map',
        'state': {'pick': 'nowhere', 'custom': []},
      }),
    );
    expect(store.plan().id, officeMap);
  });

  test('onto another map, nobody is on a seat of the last one any more', () {
    final store = Store();
    store.apply(ServerMsg.parse({'t': 'peer.join', 'peer': peer('a', seat: 'couch:0')}));
    store.apply(ServerMsg.parse({'t': 'peer.join', 'peer': peer('b')}));
    var peers = 0;
    store.topic(Topic.peers).addListener(() => peers++);
    store.apply(
      ServerMsg.parse({
        't': 'map',
        'state': {'pick': 'castle', 'custom': []},
      }),
    );
    expect(store.peers['a']!.seat, isNull);
    expect(peers, 1);
    // The same map again: seats stay.
    store.apply(ServerMsg.parse({'t': 'peer.join', 'peer': peer('a', seat: 'throne:0')}));
    store.apply(
      ServerMsg.parse({
        't': 'map',
        'state': {'pick': 'castle', 'custom': [], 'by': 'Bo'},
      }),
    );
    expect(store.peers['a']!.seat, 'throne:0');
  });

  test('a worker sent home on a map that keeps it is in the jail the remove brings', () {
    final store = Store();
    var jailed = 0;
    store.topic(Topic.jail).addListener(() => jailed++);
    store.apply(
      ServerMsg.parse({
        't': 'worker.remove',
        'workerId': 'w1',
        'jail': {
          'prisoners': [
            {'id': 'w1', 'name': 'Pixel', 'color': '#ff8a5b', 'at': 1000, 'workedMs': 60000},
          ],
          'bones': 3,
        },
      }),
    );
    expect(jailed, 1);
    expect(store.jail.prisoners.single.name, 'Pixel');
    expect(store.jail.prisoners.single.workedMs, 60000);
    expect(store.jail.bones, 3);
    // A remove that keeps nobody leaves the jail as it was.
    store.apply(ServerMsg.parse({'t': 'worker.remove', 'workerId': 'w2'}));
    expect(jailed, 1);
    expect(store.jail.prisoners, hasLength(1));
  });
}
