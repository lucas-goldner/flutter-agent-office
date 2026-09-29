@TestOn('linux')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/config.dart';
import 'package:agent_office_server/src/server.dart';
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

  static Future<Visitor> connect(int port, String cookie, String name) async => Visitor._(
    await WebSocket.connect(
      'ws://127.0.0.1:$port/ws?name=$name',
      headers: {'cookie': cookie, 'origin': 'http://127.0.0.1:$port'},
    ),
  );

  final WebSocket ws;
  final seen = <Map<String, dynamic>>[];
  final _msgs = StreamController<Map<String, dynamic>>.broadcast();

  /// The first message (already here or still to come) that passes [test]; seen ones are used up.
  Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic> m) test) {
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
        .timeout(const Duration(seconds: 20));
  }

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
  Future<void> close() => ws.close();
}

void main() {
  late Directory root;
  late Office office;
  late int port;
  late String cookie;
  final client = HttpClient();

  Future<(int, Object?, HttpClientResponse)> json(String method, String path, {String? cookie, Object? body}) async {
    final req = await client.open(method, '127.0.0.1', port, path);
    if (cookie != null) req.headers.set('cookie', cookie);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text), res);
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('agent-office-extras-');
    final project = p.join(root.path, 'project');
    Directory(p.join(project, '.agent-office')).createSync(recursive: true);
    File(p.join(project, 'README.md')).writeAsStringSync('# The project\n');
    final other = p.join(root.path, 'other');
    Directory(other).createSync();
    File(p.join(project, '.agent-office', 'floors.json')).writeAsStringSync(
      jsonEncode([
        {'id': 'other', 'name': 'other', 'dir': other, 'palette': 1, 'addedBy': 'Sam', 'addedAt': 1},
      ]),
    );
    final web = Directory(p.join(root.path, 'web'))..createSync();
    File(p.join(web.path, 'index.html')).writeAsStringSync('<!doctype html><title>office</title>');
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = free.port;
    await free.close();
    final cfg = loadConfig([project, '--port', '$port', '--password', 'let-me-in-please']);
    expect(cfg.host, '127.0.0.1');
    office = await startServer(cfg, publicDir: web.path);
    final (status, _, res) = await json('POST', '/api/login', body: {'password': 'let-me-in-please'});
    expect(status, 200);
    cookie = res.headers['set-cookie']!.single.split(';').first;
  });

  tearDownAll(() async {
    await office.shutdown();
    client.close(force: true);
    root.deleteSync(recursive: true);
  });

  test('a sign-in link from the terminal signs one browser in, once', () async {
    final link = office.signInLink();
    expect(link, startsWith('/login#key='));
    final key = link.substring('/login#key='.length);
    final (ok, _, res) = await json('POST', '/api/link', body: {'key': key});
    expect(ok, 200);
    expect(res.headers['set-cookie'], isNotEmpty);
    final (again, body, _) = await json('POST', '/api/link', body: {'key': key});
    expect(again, 410);
    expect((body as Map)['error'], contains('already used'));
  });

  test('the bookshelf lists and reads the floor\'s Markdown', () async {
    final (status, list, _) = await json('GET', '/api/docs?floor=project', cookie: cookie);
    expect(status, 200);
    expect((list as Map)['files'], [containsPair('path', 'README.md')]);
    final (_, doc, _) = await json('GET', '/api/docs/file?floor=project&path=README.md', cookie: cookie);
    expect(doc, {'path': 'README.md', 'text': '# The project\n'});
    expect((await json('GET', '/api/docs/file?floor=project&path=../x.md', cookie: cookie)).$1, 415);
  });

  test('emotes, cards, golf, the ball, the arcade and the roof reach the others', () async {
    final ada = await Visitor.connect(port, cookie, 'Ada');
    final bob = await Visitor.connect(port, cookie, 'Bob');
    addTearDown(ada.close);
    addTearDown(bob.close);
    final welcome = await ada.next((m) => m['t'] == 'welcome');
    final adaId = welcome['you'] as String;
    expect(welcome['floor'], 'project');
    expect(welcome['theme'], containsPair('pick', 'auto'));
    expect(welcome['projectsDir'], containsPair('custom', false));
    expect(welcome['ball'], <String, dynamic>{});
    expect(welcome['cabinet'], {'player': null, 'scores': [], 'frame': null});
    expect((welcome['floors'] as List).firstWhere((f) => f['id'] == 'project'), containsPair('local', true));
    await bob.next((m) => m['t'] == 'welcome');

    ada.send({'t': 'emote', 'emote': 'wave'});
    expect(await bob.next((m) => m['t'] == 'peer.emote'), {'t': 'peer.emote', 'id': adaId, 'emote': 'wave'});

    ada.send({'t': 'carry', 'issue': 12, 'title': 'Fix it'});
    final carrying = await bob.next((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['id'] == adaId);
    expect((carrying['peer'] as Map)['carrying'], {'issue': 12, 'title': 'Fix it'});

    ada.send({'t': 'act', 'golf': true});
    expect(await bob.next((m) => m['t'] == 'peer.act'), {'t': 'peer.act', 'id': adaId, 'golf': true});
    ada.send({'t': 'golf', 'yaw': 0.1, 'loft': 0.5, 'power': 0.8});
    expect(await bob.next((m) => m['t'] == 'golf'), {'t': 'golf', 'id': adaId, 'yaw': 0.1, 'loft': 0.5, 'power': 0.8});

    ada.send({'t': 'ball.take'});
    expect(await bob.next((m) => m['t'] == 'ball'), {
      't': 'ball',
      'ball': {'holder': adaId},
    });
    bob.send({'t': 'ball.take'});
    expect(await bob.next((m) => m['t'] == 'ball'), {
      't': 'ball',
      'ball': {'holder': adaId},
    }, reason: 'Ada has it');

    ada.send({'t': 'cabinet.play'});
    final cab = await bob.next((m) => m['t'] == 'cabinet');
    expect((cab['state'] as Map)['player'], containsPair('name', 'Ada'));
    bob.send({'t': 'cabinet.play'});
    await bob.next((m) => m['t'] == 'toast' && '${m['text']}'.contains('Ada is on the arcade'));

    ada.send({'t': 'theme.set', 'pick': 'christmas'});
    expect(await bob.next((m) => m['t'] == 'theme'), {'t': 'theme', 'state': containsPair('active', 'christmas')});

    // Up to the roof: the ball and the arcade stay downstairs, and drinks are served up there.
    ada.send({'t': 'act', 'drink': 'beer'});
    ada.send({'t': 'floor.go', 'floor': '@roof'});
    final up = await ada.next((m) => m['t'] == 'floor.enter');
    expect(up['floor'], '@roof');
    expect(await bob.next((m) => m['t'] == 'ball'), {'t': 'ball', 'ball': <String, dynamic>{}});
    await bob.next((m) => m['t'] == 'cabinet' && (m['state'] as Map)['player'] == null);
    final moved = await bob.next((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['floor'] == '@roof');
    expect((moved['peer'] as Map).containsKey('carrying'), isFalse);
    ada.send({'t': 'act', 'drink': 'beer'});
    expect(await bob.next((m) => m['t'] == 'peer.act' && m.containsKey('drink')), {
      't': 'peer.act',
      'id': adaId,
      'drink': 'beer',
    });
    ada.send({'t': 'horn'});
    expect(await ada.next((m) => m['t'] == 'horn'), {'t': 'horn', 'by': 'Ada'});

    // Back down, on the balcony.
    ada.send({
      't': 'floor.go',
      'floor': 'other',
      'at': {'x': 3, 'y': 0, 'z': 500, 'rotY': 1},
    });
    await ada.next((m) => m['t'] == 'floor.enter' && m['floor'] == 'other');
    final down = await bob.next((m) => m['t'] == 'peer.update' && (m['peer'] as Map)['floor'] == 'other');
    expect(down['peer'], allOf(containsPair('x', 3), containsPair('z', 60), containsPair('rotY', 1)));
    expect((down['peer'] as Map).containsKey('drink'), isFalse);

    // Taking a floor off: whoever's on it rides to the next one.
    bob.send({'t': 'floor.projectsDir', 'dir': 'relative'});
    await bob.next((m) => m['t'] == 'toast' && m['text'] == 'Use a full path, like ~/Workspace');
    bob.send({'t': 'floor.remove', 'floor': 'other'});
    final floors = await ada.next((m) => m['t'] == 'floors');
    expect([for (final f in floors['floors'] as List) f['id']], ['project']);
    expect((await ada.next((m) => m['t'] == 'floor.enter'))['floor'], 'project');
    await ada.next((m) => m['t'] == 'toast' && '${m['text']}'.contains('took other off the building'));
  });
}
