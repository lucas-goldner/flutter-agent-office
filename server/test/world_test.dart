@TestOn('linux')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/config.dart';
import 'package:agent_office_server/src/server.dart';
import 'package:office_shared/shared.dart' show cars, wingDesks;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A client of the office over its WebSocket, remembering everything it was sent.
class Visitor {
  Visitor._(this.ws) {
    ws.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      seen.add(m);
      _msgs.add(m);
    });
  }

  static Future<Visitor> connect(int port, String cookie, String query) async => Visitor._(
    await WebSocket.connect(
      'ws://127.0.0.1:$port/ws?$query',
      headers: {'cookie': cookie, 'origin': 'http://127.0.0.1:$port'},
    ),
  );

  final WebSocket ws;
  final seen = <Map<String, dynamic>>[];
  final _msgs = StreamController<Map<String, dynamic>>.broadcast();

  /// The first message (already here or still to come) that passes [test]; seen ones are used up.
  Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic> m) test, [int seconds = 20]) {
    for (final m in seen) {
      if (test(m)) {
        seen.remove(m);
        return Future.value(m);
      }
    }
    return _msgs.stream
        .firstWhere(test)
        .then((m) {
          seen.remove(m);
          return m;
        })
        .timeout(Duration(seconds: seconds));
  }

  /// A toast whose text contains [text].
  Future<Map<String, dynamic>> toast(String text) => next((m) => m['t'] == 'toast' && '${m['text']}'.contains(text));

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
  Future<void> close() => ws.close();
}

/// The building's world state end to end (upstream #181 #183 #184 #152 #203 #220 #182): the map and
/// its seats, the jail, signs and the back office, the cars, darts and axes, the dog's breed and coat,
/// and the 2D view's people.
void main() {
  late Directory root;
  late String project;
  late Office office;
  late int port;
  late String cookie;
  final client = HttpClient();

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('agent-office-world-');
    project = p.join(root.path, 'project');
    Directory(p.join(project, '.agent-office', 'maps')).createSync(recursive: true);
    File(
      p.join(project, '.agent-office', 'maps', 'barn.json'),
    ).writeAsStringSync(jsonEncode({'id': 'barn', 'name': 'The barn', 'icon': '🐄', 'extends': 'castle'}));
    final web = Directory(p.join(root.path, 'web'))..createSync();
    File(p.join(web.path, 'index.html')).writeAsStringSync('<!doctype html><title>office</title>');
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = free.port;
    await free.close();
    final cfg = loadConfig([project, '--port', '$port', '--password', 'let-me-in-please']);
    office = await startServer(cfg, publicDir: web.path);
    final req = await client.post('127.0.0.1', port, '/api/login');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'password': 'let-me-in-please'}));
    final res = await req.close();
    await res.drain<void>();
    cookie = res.headers['set-cookie']!.single.split(';').first;
  });

  tearDownAll(() async {
    await office.shutdown();
    client.close(force: true);
    root.deleteSync(recursive: true);
  });

  test(
    'signed out, /lite comes back to /lite after signing in; the 2D view is in the office but nowhere in it',
    () async {
      final req = await client.get('127.0.0.1', port, '/lite');
      req.followRedirects = false;
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 302);
      expect(res.headers.value('location'), '/login?next=/lite');

      final phone = await Visitor.connect(port, cookie, 'name=Phone&lite=1');
      addTearDown(phone.close);
      final welcome = await phone.next((m) => m['t'] == 'welcome');
      final me = (welcome['peers'] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['id'] == welcome['you']);
      expect(me['lite'], isTrue);
      final desk = await Visitor.connect(port, cookie, 'name=Desk');
      addTearDown(desk.close);
      final hello = await desk.next((m) => m['t'] == 'welcome');
      final mine = (hello['peers'] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['id'] == hello['you']);
      expect(mine.containsKey('lite'), isFalse);
    },
  );

  test('the map: picked for everyone, seats checked on it and never shared, and a worker sent home kept', () async {
    final ada = await Visitor.connect(port, cookie, 'name=Ada');
    final bob = await Visitor.connect(port, cookie, 'name=Bob');
    addTearDown(ada.close);
    addTearDown(bob.close);
    final welcome = await ada.next((m) => m['t'] == 'welcome');
    await bob.next((m) => m['t'] == 'welcome');
    expect(welcome['map'], containsPair('pick', 'office'));
    expect(
      (welcome['map']['custom'] as List).single,
      allOf(containsPair('file', 'barn.json'), isNot(contains('error'))),
    );
    expect(welcome['plan'], {'wing': 0, 'labels': <String, dynamic>{}});
    expect((welcome['cars'] as List).length, cars.length);
    expect(welcome['jail'], {'prisoners': [], 'bones': 0});
    expect(welcome['dog'], contains('breed'));
    final floor = (welcome['floors'] as List).cast<Map<String, dynamic>>().single;
    expect(floor['wing'], 0);

    // A seat on the office, taken: nobody else gets it.
    ada.send({'t': 'sit', 'seat': 'couch:0'});
    await bob.next((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['seat'] == 'couch:0');
    bob.send({'t': 'sit', 'seat': 'couch:0'});
    expect(await bob.next((m) => m['t'] == 'sit.refused'), {'t': 'sit.refused', 'seat': 'couch:0', 'by': 'Ada'});
    // The throne isn't anywhere in the office.
    bob.send({'t': 'sit', 'seat': 'throne:0'});
    bob.send({'t': 'ping', 'at': 1});
    await bob.next((m) => m['t'] == 'pong');
    expect(ada.seen.where((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['seat'] == 'throne:0'), isEmpty);

    // No such map: just Bob hears so.
    bob.send({'t': 'map.set', 'map': 'atlantis'});
    await bob.toast('no map by that name');
    // The castle, for everyone: seats forgotten, and a toast.
    bob.send({'t': 'map.set', 'map': 'castle'});
    final news = await ada.next((m) => m['t'] == 'map');
    expect(news['state'], allOf(containsPair('pick', 'castle'), containsPair('by', 'Bob')));
    await ada.toast("Bob changed the building's map to 🏰 Castle");
    expect(
      jsonDecode(File(p.join(project, '.agent-office', 'map.json')).readAsStringSync()),
      containsPair('pick', 'castle'),
    );
    // The couch is gone, the throne is there.
    bob.send({'t': 'sit', 'seat': 'throne:0'});
    await ada.next((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['seat'] == 'throne:0');
    ada.send({'t': 'sit', 'seat': 'throne:0'});
    expect(await ada.next((m) => m['t'] == 'sit.refused'), containsPair('by', 'Bob'));

    // Sent out by the Hand, and sent home on the castle: it's locked up.
    ada.send({'t': 'worker.spawn', 'deskId': 'desk-1', 'kind': 'shell', 'via': 'herald'});
    final hired = await ada.next((m) => m['t'] == 'worker.update' && (m['worker'] as Map)['deskId'] == 'desk-1', 90);
    final worker = hired['worker'] as Map<String, dynamic>;
    expect(worker['via'], 'herald');
    ada.send({'t': 'worker.kill', 'workerId': worker['id']});
    final gone = await ada.next((m) => m['t'] == 'worker.remove', 90);
    expect(gone['workerId'], worker['id']);
    expect(gone['jail'], containsPair('bones', 0));
    expect(
      (gone['jail']['prisoners'] as List).single,
      allOf(containsPair('id', worker['id']), containsPair('name', worker['name'])),
    );
    expect(File(p.join(project, '.agent-office', 'jail.json')).readAsStringSync(), contains(worker['id'] as String));

    // A map of your own, picked; then it breaks, and everyone's back in the office, told why.
    ada.send({'t': 'map.set', 'map': 'barn'});
    await bob.toast("Ada changed the building's map to 🐄 The barn");
    final barn = File(p.join(project, '.agent-office', 'maps', 'barn.json'));
    barn.writeAsStringSync('{ broken');
    // The folder's stamp is size and mtime: make sure it reads as changed.
    barn.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    ada.send({'t': 'map.set'});
    final broke = await bob.next((m) => m['t'] == 'map' && (m['state'] as Map)['pick'] == 'office');
    expect((broke['state']['custom'] as List).single, containsPair('error', startsWith("it isn't valid JSON")));
    await bob.toast('the map "barn" won\'t load');
    // Back to the office for whoever's next.
    bob.send({'t': 'map.set', 'map': 'office'});
    await ada.next(
      (m) => m['t'] == 'map' && (m['state'] as Map)['pick'] == 'office' && (m['state'] as Map)['by'] == 'Bob',
    );
  });

  test('signs over desks and the back office, for the floor and the elevator', () async {
    final ada = await Visitor.connect(port, cookie, 'name=Ada');
    final bob = await Visitor.connect(port, cookie, 'name=Bob');
    addTearDown(ada.close);
    addTearDown(bob.close);
    await ada.next((m) => m['t'] == 'welcome');
    await bob.next((m) => m['t'] == 'welcome');

    ada.send({'t': 'desk.label', 'deskId': 'beanbag-1', 'text': 'Ops'});
    await ada.toast('Only a desk can have a sign');
    ada.send({'t': 'desk.label', 'deskId': 'desk-2', 'text': ' Code  cleanup ', 'color': '#06d6a0'});
    final plan = await bob.next((m) => m['t'] == 'plan');
    expect(plan['plan']['labels']['desk-2'], allOf(containsPair('text', 'Code cleanup'), containsPair('by', 'Ada')));
    await bob.toast('🪧 Ada hung a sign over Desk 2: “Code cleanup”');
    ada.send({'t': 'desk.label', 'deskId': 'desk-2', 'text': ''});
    await bob.toast('🪧 Ada took the “Code cleanup” sign down from Desk 2');

    // Not built yet: nobody can be hired back there.
    final back = wingDesks.first;
    ada.send({'t': 'worker.spawn', 'deskId': back.id, 'kind': 'shell'});
    await ada.toast("isn't built yet");
    ada.send({'t': 'floor.shrink'});
    await ada.toast('There is no back office to wall up');
    ada.send({'t': 'floor.expand'});
    await bob.next((m) => m['t'] == 'plan' && (m['plan'] as Map)['wing'] == 1);
    await bob.toast('🔨 Ada knocked out the back wall');
    final floors = await bob.next((m) => m['t'] == 'floors' && ((m['floors'] as List).single as Map)['wing'] == 1);
    expect(floors, isNotNull);
    ada.send({'t': 'floor.shrink'});
    await bob.next((m) => m['t'] == 'plan' && (m['plan'] as Map)['wing'] == 0);
    await bob.toast('🧱 Ada walled the back office back up');
  });

  test('the cars: get in, drive, honk and get out, for everyone on the floor', () async {
    final ada = await Visitor.connect(port, cookie, 'name=Ada');
    final bob = await Visitor.connect(port, cookie, 'name=Bob');
    addTearDown(ada.close);
    addTearDown(bob.close);
    final adaId = (await ada.next((m) => m['t'] == 'welcome'))['you'];
    await bob.next((m) => m['t'] == 'welcome');

    ada.send({'t': 'car.enter', 'car': 1, 'seat': 'driver'});
    final mine = await ada.next((m) => m['t'] == 'cars' && m['answer'] == true);
    expect((mine['cars'] as List)[1], containsPair('driver', adaId));
    expect(((await bob.next((m) => m['t'] == 'cars'))['cars'] as List)[1], containsPair('driver', adaId));
    // Bob doesn't get the wheel, and hears who has it.
    bob.send({'t': 'car.enter', 'car': 1, 'seat': 'driver'});
    final no = await bob.next((m) => m['t'] == 'cars' && m['answer'] == true);
    expect((no['cars'] as List)[1], containsPair('driver', adaId));
    // Only the driver moves it, and only on the pavement.
    bob.send({'t': 'car.drive', 'car': 1, 'x': 0, 'z': 18, 'rotY': 1, 'speed': 5, 'steer': 0});
    ada.send({'t': 'car.drive', 'car': 1, 'x': -60, 'z': 18, 'rotY': 1, 'speed': 5, 'steer': 0});
    ada.send({'t': 'car.drive', 'car': 1, 'x': 0, 'z': 18, 'rotY': 1, 'speed': 999, 'steer': 0});
    expect(await bob.next((m) => m['t'] == 'car.move'), {
      't': 'car.move',
      'car': 1,
      'x': 0,
      'z': 18,
      'rotY': 1,
      'speed': 20,
      'steer': 0,
    });
    ada.send({'t': 'car.honk'});
    expect(await bob.next((m) => m['t'] == 'car.honk'), {'t': 'car.honk', 'car': 1});
    // Up to the roof: out of the car, parked where she left it.
    ada.send({'t': 'floor.go', 'floor': '@roof'});
    final parkedUp = await bob.next((m) => m['t'] == 'cars' && ((m['cars'] as List)[1] as Map)['driver'] == null);
    expect((parkedUp['cars'] as List)[1], allOf(containsPair('x', 0), containsPair('z', 18), containsPair('speed', 0)));
  });

  test('darts and axes: only at the line on the roof, and no quicker than anyone throws', () async {
    final ada = await Visitor.connect(port, cookie, 'name=Ada&floor=@roof');
    final bob = await Visitor.connect(port, cookie, 'name=Bob&floor=@roof');
    addTearDown(ada.close);
    addTearDown(bob.close);
    final adaId = (await ada.next((m) => m['t'] == 'welcome'))['you'];
    await bob.next((m) => m['t'] == 'welcome');

    // Not at the line yet: nothing goes.
    ada.send({'t': 'toss', 'game': 'darts', 'u': 0, 'v': 0, 'n': 1, 'stick': true});
    ada.send({'t': 'act', 'throwing': 'darts'});
    expect(await bob.next((m) => m['t'] == 'peer.act' && m.containsKey('throwing')), {
      't': 'peer.act',
      'id': adaId,
      'throwing': 'darts',
    });
    ada.send({'t': 'toss', 'game': 'axe', 'u': 0, 'v': 0, 'n': 1}); // the other game
    ada.send({'t': 'toss', 'game': 'darts', 'u': 9, 'v': 0, 'n': 1}); // way off
    ada.send({'t': 'toss', 'game': 'darts', 'u': 0.1, 'v': -0.2, 'n': 2, 'stick': true});
    ada.send({'t': 'toss', 'game': 'darts', 'u': 0.1, 'v': -0.2, 'n': 3, 'stick': true}); // too quick
    final toss = await bob.next((m) => m['t'] == 'toss');
    expect(toss, {'t': 'toss', 'id': adaId, 'game': 'darts', 'u': 0.1, 'v': -0.2, 'stick': true, 'n': 2});
    ada.send({'t': 'act', 'throwing': null});
    expect(await bob.next((m) => m['t'] == 'peer.act' && m.containsKey('throwing')), {
      't': 'peer.act',
      'id': adaId,
      'throwing': null,
    });
    expect(bob.seen.where((m) => m['t'] == 'toss'), isEmpty);
  });

  test("the dog's breed and coat, for the floor, kept", () async {
    final ada = await Visitor.connect(port, cookie, 'name=Ada');
    addTearDown(ada.close);
    await ada.next((m) => m['t'] == 'welcome');
    ada.send({'t': 'dog.breed', 'breed': 'pomeranian'});
    await ada.next((m) => m['t'] == 'dog' && (m['dog'] as Map)['breed'] == 'pomeranian');
    await ada.toast('a Pomeranian');
    ada.send({'t': 'dog.breed', 'breed': 'wolf'});
    ada.send({'t': 'dog.coat', 'coat': 6});
    await ada.next((m) => m['t'] == 'dog' && (m['dog'] as Map)['coat'] == 6);
    await ada.toast('a white coat');
    final saved = jsonDecode(File(p.join(project, '.agent-office', 'dog.json')).readAsStringSync());
    expect(saved, allOf(containsPair('breed', 'pomeranian'), containsPair('coat', 6)));
  });
}
