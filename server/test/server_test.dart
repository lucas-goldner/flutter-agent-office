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

/// The office end to end: started on a free port in a temp project, signed in over HTTP, and a
/// shell worker hired, typed into and sent home over the WebSocket, as the browser does it.
void main() {
  late Directory root;
  late String project;
  late Office office;
  late int port;
  final client = HttpClient();

  Future<HttpClientResponse> request(String method, String path, {String? cookie, Object? body}) async {
    final req = await client.open(method, '127.0.0.1', port, path);
    req.followRedirects = false;
    if (cookie != null) req.headers.set('cookie', cookie);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    return req.close();
  }

  Future<(int, Object?)> json(String method, String path, {String? cookie, Object? body}) async {
    final res = await request(method, path, cookie: cookie, body: body);
    final text = await utf8.decoder.bind(res).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  void expectJson((int, Object?) got, int status, Object? body) {
    expect(got.$1, status);
    expect(got.$2, body);
  }

  /// PTY hosts of this office still running, by the data folder on their command line.
  List<int> ptyHosts() {
    final out = <int>[];
    for (final d in Directory('/proc').listSync().whereType<Directory>()) {
      final pid = int.tryParse(p.basename(d.path));
      if (pid == null) continue;
      try {
        final cmd = File(p.join(d.path, 'cmdline')).readAsStringSync();
        if (cmd.contains('__ptyhost') && cmd.contains(root.path)) out.add(pid);
      } catch (_) {
        // gone meanwhile
      }
    }
    return out;
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('agent-office-server-');
    project = p.join(root.path, 'project');
    Directory(project).createSync();
    final web = Directory(p.join(root.path, 'web'))..createSync();
    File(p.join(web.path, 'index.html')).writeAsStringSync('<!doctype html><title>office</title>');
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = free.port;
    await free.close();
    final cfg = loadConfig([project, '--port', '$port', '--host', '127.0.0.1', '--password', 'let-me-in-please']);
    office = await startServer(cfg, publicDir: web.path);
  });

  tearDownAll(() async {
    client.close(force: true);
    root.deleteSync(recursive: true);
  });

  test('HTTP: sign-in, the session cookie, and what needs one', () async {
    expect((await json('GET', '/api/health')).$1, 200);
    expectJson(await json('GET', '/api/login'), 200, {'accounts': false, 'shared': true});
    expectJson(await json('POST', '/api/login', body: {'password': 'nope'}), 401, {'error': 'Wrong password'});
    expect((await json('GET', '/api/whoami')).$1, 401);

    final redirect = await request('GET', '/');
    await redirect.drain<void>();
    expect(redirect.statusCode, 302);
    expect(redirect.headers.value('location'), '/login');
    final login = await request('GET', '/login');
    expect(await utf8.decoder.bind(login).join(), contains('<title>office</title>'));
    expect(login.headers.contentType?.mimeType, 'text/html');

    final ok = await request('POST', '/api/login', body: {'password': 'let-me-in-please'});
    await ok.drain<void>();
    expect(ok.statusCode, 200);
    final cookie = ok.headers['set-cookie']!.single.split(';').first;
    expect(cookie, startsWith('ao_session_$port='));
    expectJson(await json('GET', '/api/whoami', cookie: cookie), 200, {
      'ok': true,
      'me': {'admin': true},
    });
    expectJson(await json('GET', '/api/search?q=x', cookie: cookie), 200, {
      'q': 'x',
      'chat': [],
      'terminals': [],
      'more': false,
    });
    expect((await json('GET', '/api/gh/pull?number=abc', cookie: cookie)).$1, 400);
  });

  test('the hook endpoint only takes known workers', () async {
    final hooks = HttpClient();
    addTearDown(hooks.close);
    Future<int> post(String path) async {
      final req = await hooks.post('127.0.0.1', office.hookPort, path);
      req.write('{}');
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    expect(await post('/hooks/claude?worker=nobody&event=Stop'), 401);
    expect(await post('/hooks/elsewhere'), 404);
  });

  test('WebSocket: welcome, a shell worker typed into, and sent home', () async {
    final ok = await request('POST', '/api/login', body: {'password': 'let-me-in-please'});
    await ok.drain<void>();
    final cookie = ok.headers['set-cookie']!.single.split(';').first;

    // Another site can't open the office's socket with a visitor's cookie.
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:$port/ws', headers: {'cookie': cookie, 'origin': 'http://evil.example'}),
      throwsA(isA<WebSocketException>()),
    );

    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws?name=Ada',
      headers: {'cookie': cookie, 'origin': 'http://127.0.0.1:$port'},
    );
    final msgs = StreamController<Map<String, dynamic>>.broadcast();
    final seen = <Map<String, dynamic>>[];
    ws.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      seen.add(m);
      msgs.add(m);
    });
    Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic> m) test) {
      for (final m in seen) {
        if (test(m)) return Future.value(m);
      }
      return msgs.stream.firstWhere(test).timeout(const Duration(seconds: 90));
    }

    void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));

    final welcome = await next((m) => m['t'] == 'welcome');
    expect(welcome['floor'], 'project');
    expect((welcome['peers'] as List).single, containsPair('name', 'Ada'));
    expect(welcome.keys, containsAll(['you', 'floors', 'version', 'me', 'sky', 'workers', 'jukebox', 'whiteboard']));

    send({'t': 'worker.spawn', 'deskId': 'desk-1', 'kind': 'shell'});
    final update = await next((m) => m['t'] == 'worker.update' && (m['worker'] as Map)['deskId'] == 'desk-1');
    final worker = update['worker'] as Map<String, dynamic>;
    expect(worker['kind'], 'shell');
    final id = worker['id'] as String;
    expect(await next((m) => m['t'] == 'toast'), containsPair('text', 'Ada opened a shell at a desk'));

    send({'t': 'worker.attach', 'workerId': id});
    final snapshot = await next((m) => m['t'] == 'term.snapshot');
    expect(snapshot, containsPair('workerId', id));

    // Typed until the shell is up to answer: it may still be starting.
    var output = '';
    final sub = msgs.stream.where((m) => m['t'] == 'term.data' && m['workerId'] == id).listen((m) {
      output += m['data'] as String;
    });
    final echoed = RegExp(r'[\r\n]hi\r?\n');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!echoed.hasMatch(output) && DateTime.now().isBefore(deadline)) {
      send({'t': 'term.input', 'workerId': id, 'data': 'echo hi\r'});
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await sub.cancel();
    expect(output, matches(echoed));

    send({'t': 'ping', 'at': 42});
    final pong = await next((m) => m['t'] == 'pong');
    expect(pong['at'], 42, reason: 'whole numbers go out as the Node server sent them');

    send({'t': 'worker.kill', 'workerId': id});
    expect(await next((m) => m['t'] == 'worker.remove'), {'t': 'worker.remove', 'workerId': id});
    await ws.close();

    expect(ptyHosts(), isNotEmpty, reason: 'the terminals ran in the PTY host');
    await office.shutdown();
    final gone = DateTime.now().add(const Duration(seconds: 10));
    while (ptyHosts().isNotEmpty && DateTime.now().isBefore(gone)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(ptyHosts(), isEmpty, reason: 'closing the office (not a restart) stops the PTY host');
  });
}
