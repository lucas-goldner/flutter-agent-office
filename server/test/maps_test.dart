import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/clock.dart';
import 'package:agent_office_server/src/jail.dart';
import 'package:agent_office_server/src/maps.dart';
import 'package:agent_office_server/src/worker_handle.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server's side of upstream's tests/maps.test.ts and tests/dungeon.test.ts: the building's map
/// pick and maps of your own, each worker's working time, and the jail.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('maps-'));
  tearDown(() => dir.deleteSync(recursive: true));

  LiveInfo info() => LiveInfo(
    id: 'w1',
    kind: WorkerKind.agent,
    deskId: 'desk-1',
    name: 'Pixel',
    color: '#ef476f',
    status: WorkerStatus.idle,
    createdBy: 'Ada',
    createdAt: 0,
  );

  test('a worker keeps count of how long it has worked, over every stretch', () {
    final w = info();
    clockWork(w, WorkerStatus.working, 1000);
    expect(w.workingSince, 1000);
    // Still working: the stretch keeps going.
    clockWork(w, WorkerStatus.working, 5000);
    expect(w.workingSince, 1000);
    expect(workedMs(w, 7000), 6000);
    clockWork(w, WorkerStatus.done, 11000);
    expect(w.workedMs, 10000);
    expect(w.workingSince, isNull);
    clockWork(w, WorkerStatus.working, 20000);
    clockWork(w, WorkerStatus.needsInput, 25000);
    expect(w.workedMs, 15000);
    // Asleep, it doesn't count.
    clockWork(w, WorkerStatus.offline, 90000);
    expect(workedMs(w, 100000), 15000);
    // On the wire as it is: the stretches that ended, and when the one it's in began.
    w.status = WorkerStatus.working;
    expect(w.view.workedMs, 15000);
    expect(w.view.workingSince, isNotNull);
    expect(workedMsOf(w.view, w.workingSince! + 500), 15500);
    w.status = WorkerStatus.done;
    expect(w.workingSince, isNull);
    expect(w.workedMs, greaterThanOrEqualTo(15000));
  });

  test('the map pick is kept with who picked it, and the office is the default', () {
    final maps = Maps(dir.path, now: () => 42);
    expect(maps.pick(), officeMap);
    expect(maps.state().toJson(), {'pick': 'office', 'custom': []});
    expect(maps.set('no-such-map', 'Ada'), isFalse);
    expect(maps.set('castle', 'Ada'), isTrue);
    expect(maps.pick(), 'castle');
    expect(maps.plan().id, 'castle');
    expect(maps.state().toJson(), {'pick': 'castle', 'custom': [], 'by': 'Ada', 'at': 42});
    // Back after a restart.
    expect(jsonDecode(File(p.join(dir.path, 'map.json')).readAsStringSync()), {
      'pick': 'castle',
      'by': 'Ada',
      'at': 42,
    });
    expect(Maps(dir.path).state().toJson(), {'pick': 'castle', 'custom': [], 'by': 'Ada', 'at': 42});
    // A broken file is the office.
    File(p.join(dir.path, 'map.json')).writeAsStringSync('{');
    expect(Maps(dir.path).pick(), officeMap);
  });

  test('maps of your own are read from the folder, again only when it changed, and say why they won’t load', () {
    final folder = Directory(p.join(dir.path, 'maps'))..createSync();
    void write(String name, String text) => File(p.join(folder.path, name)).writeAsStringSync(text);
    write('barn.json', jsonEncode({'id': 'barn', 'name': 'The barn', 'extends': 'castle'}));
    write('broken.json', '{ nope');
    write('notes.txt', 'not a map');
    final maps = Maps(dir.path);
    expect(maps.folder, folder.path);
    final custom = maps.state().custom;
    expect(custom.map((m) => m.file), ['barn.json', 'broken.json']);
    expect(custom[0].error, isNull);
    expect(custom[0].config?['id'], 'barn');
    expect(custom[1].error, startsWith("it isn't valid JSON ("));
    // Nothing changed: nothing to tell anyone.
    expect(maps.reload(), isFalse);
    expect(maps.set('barn', 'Bob'), isTrue);
    expect(maps.plan().name, 'The barn');

    // Too big, and past the first 24 files.
    write('big.json', jsonEncode({'id': 'big', 'pad': 'x' * (maxMapBytes + 1)}));
    for (var i = 0; i < maxMapFiles; i++) {
      write('z$i.json', jsonEncode({'id': 'z$i', 'extends': 'castle'}));
    }
    expect(maps.reload(), isTrue);
    final all = maps.state().custom;
    expect(all.firstWhere((m) => m.file == 'big.json').error, "it's over 256 KB");
    final extra = all.where((m) => m.error == 'only the first $maxMapFiles maps in the folder are read');
    expect(extra, isNotEmpty);
    expect(all.length, maxMapFiles + extra.length);

    // The picked map going away: back to the office, and nobody named as having picked it.
    File(p.join(folder.path, 'barn.json')).deleteSync();
    expect(maps.reload(), isTrue);
    expect(maps.pick(), officeMap);
    expect(maps.state().by, isNull);
  });

  test('the jail remembers everyone locked up, keeps the latest by name, and survives a restart', () {
    var now = 1000;
    final jail = Jail(dir.path, now: () => now);
    expect(jail.state().toJson(), {'prisoners': [], 'bones': 0});
    jail.add(id: 'w1', name: 'Pixel', color: '#ef476f', workedMs: 60000);
    now = 2000;
    final s = jail.add(id: 'w2', name: 'Byte', color: '#06d6a0');
    expect(s.toJson()['prisoners'], [
      {'id': 'w1', 'name': 'Pixel', 'color': '#ef476f', 'at': 1000, 'workedMs': 60000},
      {'id': 'w2', 'name': 'Byte', 'color': '#06d6a0', 'at': 2000},
    ]);
    // Back after a restart, just as it was.
    expect(Jail(dir.path).state().toJson(), s.toJson());
    // Locked up again: once, as of now.
    now = 3000;
    final again = jail.add(id: 'w1', name: 'Pixel', color: '#ef476f');
    expect(again.prisoners.map((q) => q.id), ['w2', 'w1']);
    // Past the most kept by name, the oldest are only counted: bones on the heap.
    for (var i = 0; i < maxPrisoners; i++) {
      jail.add(id: 'x$i', name: 'X$i', color: '#000000');
    }
    final full = jail.state();
    expect(full.prisoners.length, maxPrisoners);
    expect(full.bones, 2);
    expect(full.prisoners.first.id, 'x0');
    expect(Jail(dir.path).state().toJson(), full.toJson());
    // A broken file is an empty dungeon, not a broken office; what's wrong in it is dropped.
    final bad = Directory.systemTemp.createTempSync('jail-');
    addTearDown(() => bad.deleteSync(recursive: true));
    File(p.join(bad.path, 'jail.json')).writeAsStringSync('{');
    final j2 = Jail(bad.path);
    expect(j2.state().prisoners, isEmpty);
    j2.add(id: 'a', name: 'A', color: '#111111');
    expect(File(p.join(bad.path, 'jail.json')).readAsStringSync(), contains('"A"'));
    File(p.join(bad.path, 'jail.json')).writeAsStringSync(
      jsonEncode({
        'prisoners': [
          {'id': 'ok', 'name': 'N' * 100, 'color': '#fff', 'at': 5, 'workedMs': -3},
          {'id': 1, 'name': 'bad', 'color': '#fff', 'at': 5},
        ],
        'bones': 1.5,
      }),
    );
    final j3 = Jail(bad.path).state();
    expect(j3.prisoners.single.toJson(), {'id': 'ok', 'name': 'N' * 64, 'color': '#fff', 'at': 5});
    expect(j3.bones, 0);
  });
}
