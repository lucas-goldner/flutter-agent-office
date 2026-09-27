import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/relay.dart';
import 'package:office_shared/shared.dart';
import 'package:relic/relic.dart';
import 'package:test/test.dart';

// The relay end to end: a worker's server (plain dart:io, with a WebSocket), reached through a
// relic server that relays every request to it the way the office does on a service tunnel.
void main() {
  late HttpServer upstream;
  late RelicServer office;
  late ServiceInfo svc;
  final seen = <HttpHeaders>[];

  setUpAll(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      seen.add(req.headers);
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add('echo:$m'));
        return;
      }
      final body = await utf8.decoder.bind(req).join();
      req.response.statusCode = req.uri.path == '/missing' ? 404 : 200;
      req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.response.headers.add('set-cookie', 'dev=1; Path=/');
      req.response.write(jsonEncode({'method': req.method, 'path': req.uri.toString(), 'body': body}));
      await req.response.close();
    });
    svc = ServiceInfo(port: upstream.port, host: '127.0.0.1', pid: 1, command: 'vite', workerId: 'w', since: 0);
    office = RelicServer(() => IOAdapter.bind(InternetAddress.loopbackIPv4, port: 0));
    await office.mountAndStart((req) {
      if (req.url.path == '/down') {
        return relayRequest(
          req,
          ServiceInfo(port: 1, host: '127.0.0.1', pid: 1, command: 'vite <dev>', workerId: 'w', since: 0),
        );
      }
      if (req.headers['upgrade']?.any((v) => v.toLowerCase() == 'websocket') ?? false) {
        return relayUpgrade(req, svc);
      }
      return relayRequest(req, svc);
    });
  });
  tearDownAll(() async {
    await office.close(force: true);
    await upstream.close(force: true);
  });

  test('requests go through with their body, and answers come back', () async {
    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.post('127.0.0.1', office.port, '/api/x?q=1%202');
    req.headers.set('cookie', 'ao_session_4600=secret; theme=dark');
    req.headers.contentType = ContentType.json;
    req.write('{"hi":true}');
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'application/json');
    expect(res.headers['set-cookie'], ['dev=1; Path=/']);
    expect(jsonDecode(text), {'method': 'POST', 'path': '/api/x?q=1%202', 'body': '{"hi":true}'});
    final h = seen.last;
    expect(h.value('x-agent-office-relay'), '1');
    expect(h.value('cookie'), 'theme=dark', reason: "the office's own session never leaves it");

    final missing = await (await client.get('127.0.0.1', office.port, '/missing')).close();
    await missing.drain<void>();
    expect(missing.statusCode, 404);
  });

  test("a server that doesn't answer gets the office's page", () async {
    final client = HttpClient();
    addTearDown(client.close);
    final res = await (await client.get('127.0.0.1', office.port, '/down')).close();
    final text = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 502);
    expect(text, contains('Not answering'));
    expect(text, contains('vite &#60;dev&#62;'));
  });

  test('WebSockets are spliced through', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${office.port}/hmr', headers: {'cookie': 'ao_session=x; a=b'});
    ws.add('ping');
    expect(await ws.first, 'echo:ping');
    await ws.close();
    expect(seen.last.value('x-agent-office-relay'), '1');
    expect(seen.last.value('cookie'), 'a=b');
  });
}
