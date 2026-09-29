import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/building.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

({String root, String dataDir, List<FloorDef> defs}) office() {
  final root = Directory.systemTemp.createTempSync('agent-office-building-').resolveSymbolicLinksSync();
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  final dataDir = p.join(root, '.agent-office');
  Directory(dataDir).createSync();
  FloorDef floor(String id, int palette) {
    final dir = p.join(root, 'acme', id);
    Directory(dir).createSync(recursive: true);
    return FloorDef(id: id, name: id, repo: 'acme/$id', dir: dir, palette: palette, addedBy: 'Sam', addedAt: 1);
  }

  final defs = [floor('api', 0), floor('web', 1), floor('docs', 2)];
  File(p.join(dataDir, 'floors.json')).writeAsStringSync(jsonEncode([for (final d in defs) d.toJson()]));
  return (root: root, dataDir: dataDir, defs: defs);
}

List<String> saved(String dataDir) => [
  for (final d in jsonDecode(File(p.join(dataDir, 'floors.json')).readAsStringSync()) as List)
    (d as Map)['id'] as String,
];

List<String> ids(Building b) => [for (final d in b.list()) d.id];

void main() {
  test('a floor comes off the building and stays off, with its checkout left where it was', () {
    final (:root, :dataDir, :defs) = office();
    final building = Building(dataDir, root);

    final r = building.remove('web');
    expect(r.floor?.dir, defs[1].dir);
    expect(ids(building), ['api', 'docs']);
    expect(saved(dataDir), ['api', 'docs']);
    expect(Directory(defs[1].dir).existsSync(), isTrue, reason: 'the checkout stays on disk');
    // After a restart it's still gone.
    expect(ids(Building(dataDir, root)), ['api', 'docs']);
  });

  test("floors that aren't there can't be taken off", () {
    final (:root, :dataDir, defs: _) = office();
    final building = Building(dataDir, root);
    expect(building.remove('nope').error, 'No such floor');
    expect(saved(dataDir), ['api', 'web', 'docs']);
  });

  test('the floor the office was started in comes off too, stays off after a restart, and moves back in when its '
      'repository is added again', () async {
    final (:root, :dataDir, :defs) = office();
    Process.runSync('git', ['init', '-q', defs[0].dir]);
    Process.runSync('git', ['-C', defs[0].dir, 'remote', 'add', 'origin', 'https://github.com/acme/api.git']);
    final building = Building(dataDir, root);
    building.ensureLocal(defs[0].dir, 'the office');
    expect(building.isLocal('api'), isTrue);
    expect(building.isLocal('web'), isFalse);

    final r = building.remove('api', 'Sam');
    expect(r.floor?.id, 'api');
    expect(building.isLocal('api'), isFalse);
    expect(saved(dataDir), ['web', 'docs']);
    expect(Directory(defs[0].dir).existsSync(), isTrue);

    // The next start doesn't put it back.
    final again = Building(dataDir, root);
    expect(again.ensureLocal(defs[0].dir, 'the office'), isNull);
    expect(ids(again), ['web', 'docs']);
    expect(saved(dataDir), ['web', 'docs']);

    // Adding acme/api again uses the checkout it always was (no clone, no GitHub needed).
    final started = <String>[];
    final back = await again.add('https://github.com/acme/api', 'Sam', (d) => started.add(d.dir));
    expect(back.error, isNull);
    expect(back.floor!.dir, defs[0].dir);
    expect(started, [defs[0].dir]);
    expect(again.isLocal(back.floor!.id), isTrue);
    expect(saved(dataDir), ['web', 'docs', 'api']);
    expect(File(p.join(dataDir, 'local-floor.json')).existsSync(), isFalse);

    // ...and it's a floor again at the next start.
    final third = Building(dataDir, root);
    expect(third.ensureLocal(defs[0].dir, 'the office')?.id, 'api');
    expect(ids(third), ['web', 'docs', 'api']);
  });

  test('the projects folder can be picked, is kept, and must be a full path outside every project', () {
    final (:root, :dataDir, :defs) = office();
    final building = Building(dataDir, root);
    expect(building.projectsDir, root);
    expect(building.projectsDirState().custom, isFalse);
    expect(building.setProjectsDir('relative/path', 'Sam'), 'Use a full path, like ~/Workspace');
    expect(building.setProjectsDir(p.join(defs[0].dir, 'nested'), 'Sam'), contains("inside api's checkout"));
    final ws = p.join(root, 'workspace', 'new');
    expect(building.setProjectsDir(ws, 'Sam'), isNull);
    expect(building.projectsDir, ws);
    final state = building.projectsDirState();
    expect(state.custom, isTrue);
    expect(state.by, 'Sam');
    expect(Building(dataDir, root).projectsDir, ws, reason: 'kept in projects-folder.json');
    // '' goes back to the default.
    expect(building.setProjectsDir('', 'Sam'), isNull);
    expect(building.projectsDirState().custom, isFalse);
    expect(Building(dataDir, root).projectsDir, root);
  });
}
