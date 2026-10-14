import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/accounts.dart';
import 'package:agent_office_server/src/auth.dart';
import 'package:agent_office_server/src/relay.dart';
import 'package:agent_office_server/src/secrets.dart';
import 'package:agent_office_server/src/services.dart';
import 'package:agent_office_server/src/tunnel/forwarder.dart';
import 'package:agent_office_server/src/tunnel/office.dart';
import 'package:agent_office_server/src/tunnel/ssh.dart';
import 'package:agent_office_server/src/tunnel/tunnel.dart';
import 'package:agent_office_server/src/tunnel/wire.dart';
import 'package:office_shared/shared.dart';
import 'package:relic/relic.dart';
import 'package:test/test.dart';

// `agent-office tunnel` against the office's own tunnel handling (relay.dart's answerTunneled, as
// the office's handler runs it): it signs in, asks for the workers' servers, and what arrives on a
// port it opened reaches that worker's server. Ported from tests/tunnel.test.ts.

/// A port nothing listens on.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

typedef Got = ({int status, String body});

Future<Got> get(int port, String path, {Map<String, String> headers = const {}}) async {
  final client = HttpClient();
  try {
    final req = await client.get('127.0.0.1', port, path);
    req.headers.set('host', 'localhost:$port');
    headers.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close();
    return (status: res.statusCode, body: await utf8.decoder.bind(res).join());
  } finally {
    client.close(force: true);
  }
}

class Setup {
  late HttpServer worker;
  late int port;
  late RelicServer officeServer;
  late TunnelOffice office;
  late Forwarder forwarder;
  late ForwardEvents said;
  late Directory dir;
  final seen = <HttpHeaders>[];
  final running = <int>{};
  final events = <String>[];
  int get officePort => officeServer.port;

  Future<void> start() async {
    worker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    worker.listen((req) async {
      seen.add(req.headers);
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add('echo:$m'));
        return;
      }
      req.response.headers.add('set-cookie', 'theirs=2');
      req.response.write('worker ${req.method} ${req.uri}');
      await req.response.close();
    });
    port = await freePort();
    final svc = ServiceInfo(
      port: worker.port,
      host: '127.0.0.1',
      pid: 1,
      command: 'vite',
      workerId: 'w1',
      title: 'Vite App',
      since: 0,
    );
    running.add(port);

    dir = Directory.systemTemp.createTempSync('ao-tunnel-');
    final salt = randomBytes(16);
    final accounts = Accounts(dir.path);
    final auth = Auth(scryptSync('hunter2', salt, 32), salt, 'secret', accounts);
    ServiceLookup? lookup(int p) =>
        p != port ? null : (running.contains(port) ? ServiceLookupFound(svc) : ServiceLookupGone());
    Response json(int status, Object body, [Map<String, String> extra = const {}]) => Response(
      status,
      headers: Headers.build((h) => extra.forEach((k, v) => h[k] = [v])),
      body: Body.fromString(jsonEncode(body), mimeType: MimeType.json),
    );
    Future<Response> login(Request req) async {
      final body = jsonDecode(await req.readAsString()) as Map;
      if (!await auth.checkPassword(body['password'] as String? ?? '')) return json(401, {'error': 'Wrong password'});
      return json(200, {'ok': true}, {'set-cookie': auth.cookie(req.headers, auth.issue(), false)});
    }

    officeServer = RelicServer(() => IOAdapter.bind(InternetAddress.loopbackIPv4, port: 0));
    await officeServer.mountAndStart((req) async {
      final tunneled = await answerTunneled(
        req,
        officePort: officeServer.port,
        lookup: lookup,
        signedIn: (r) => auth.fromAnyCookie(r.headers),
        login: login,
        loginOptions: () => (accounts: accounts.any, shared: accounts.sharedPassword),
      );
      if (tunneled != null) return tunneled;
      final path = req.url.path;
      if (path == '/api/health') return json(200, {'ok': true});
      if (path == '/api/login' && req.method == Method.get) {
        return json(200, {'accounts': accounts.any, 'shared': accounts.sharedPassword});
      }
      if (path == '/api/login' && req.method == Method.post) return login(req);
      if (auth.fromRequest(req.headers) == null) return json(401, {'error': 'Not logged in'});
      if (path == forwardsPath) {
        return json(
          200,
          ForwardList(
            port: officeServer.port,
            items: [
              if (running.contains(port))
                Forward(port: port, title: 'Vite App', command: 'vite', worker: 'Byte', floor: 'acme'),
            ],
          ).toJson(),
        );
      }
      return json(404, {'error': 'Not found'});
    });

    office = TunnelOffice(Uri.parse('http://127.0.0.1:$officePort'));
    said = ForwardEvents(
      opened: (f) => events.add('opened ${f.port}'),
      closed: (f) => events.add('closed ${f.port}'),
      busy: (f, why) => events.add('busy ${f.port} ${why.name}'),
    );
    // No lingering: a port closes the moment its server is off the list.
    forwarder = Forwarder(office, said, linger: 0);
  }

  Future<void> close() async {
    await forwarder.close();
    office.close();
    await officeServer.close(force: true);
    await worker.close(force: true);
    dir.deleteSync(recursive: true);
  }
}

Future<Setup> setup() async {
  final t = Setup();
  await t.start();
  addTearDown(t.close);
  return t;
}

Matcher refused() => throwsA(isA<SocketException>());

void main() {
  test("it signs in with the office password and is told the workers' servers", () async {
    final t = await setup();
    expect(await t.office.up(), isTrue);
    expect(await t.office.loginOptions(), (accounts: false, shared: true));
    expect(await t.office.forwards(), ForwardsRefused.signedOut);
    expect(await t.office.signIn('', 'wrong'), 'Wrong password');
    expect(await t.office.signIn('', 'hunter2'), '');
    final list = await t.office.forwards() as ForwardList;
    expect(list.toJson(), {
      'port': t.officePort,
      'items': [
        {'port': t.port, 'title': 'Vite App', 'command': 'vite', 'worker': 'Byte', 'floor': 'acme'},
      ],
    });
  });

  test(
    "a worker's server opens on the same port here, for anything on this computer, and closes when it stops",
    () async {
      final t = await setup();
      await t.office.signIn('', 'hunter2');
      final list = await t.office.forwards() as ForwardList;
      await t.forwarder.sync(list.items);
      expect(t.events, ['opened ${t.port}']);
      expect(t.forwarder.ports(), [t.port]);

      // No cookie of the office's, as curl would ask: the client's own session signs it in.
      final page = await get(t.port, '/hello?x=1', headers: {'cookie': 'mine=1'});
      expect(page, (status: 200, body: 'worker GET /hello?x=1'));
      final headers = t.seen.last;
      expect(headers.value('host'), 'localhost:${t.port}');
      // The worker's server never sees the office's session, or how the request got to it.
      expect(headers.value('cookie'), 'mine=1');
      expect(headers.value(serviceHeader), isNull);

      // Many at once, over the connections the client keeps open to the office.
      final many = await Future.wait([for (var i = 0; i < 60; i++) get(t.port, '/n/$i')]);
      expect(many.map((r) => r.body), [for (var i = 0; i < 60; i++) 'worker GET /n/$i']);

      // WebSockets (hot reload) go through too.
      final ws = await WebSocket.connect('ws://localhost:${t.port}/hmr');
      ws.add('ping');
      expect(await ws.first.timeout(const Duration(seconds: 10)), 'echo:ping');
      await ws.close();

      // A page somewhere else that points a name of its own at the port gets nothing.
      expect((await get(t.port, '/', headers: {'host': 'evil.example:${t.port}'})).status, 421);

      t.running.clear();
      final after = await t.office.forwards() as ForwardList;
      await t.forwarder.sync(after.items);
      expect(t.events, ['opened ${t.port}', 'closed ${t.port}']);
      await expectLater(get(t.port, '/'), refused());
    },
  );

  test("a request the client sends never gets the office's own pages", () async {
    final t = await setup();
    Forward item(int port) => Forward(port: port, title: 'x', command: 'x');
    await t.office.signIn('', 'hunter2');
    // A port no worker serves (the office forgot it, or never knew it), and the office's own.
    final stale = await freePort();
    await t.forwarder.sync([item(t.port), item(stale)]);
    for (final p in ['/', '/api/services', '/api/health']) {
      final r = await get(stale, p);
      expect(r.status, 503, reason: p);
      expect(r.body, contains('Not running'));
    }
    // Nor does a worker's page that says the office relayed its request already.
    expect((await get(stale, '/api/services', headers: {'x-agent-office-relay': '1'})).status, 503);
    expect(
      (await get(t.port, '/api/services', headers: {'x-agent-office-relay': '1'})).body,
      'worker GET /api/services',
    );

    Future<Got> direct(Map<String, String> headers) => get(
      t.officePort,
      '/api/health',
      headers: {'host': '127.0.0.1:${t.officePort}', 'cookie': t.office.cookie(), ...headers},
    );
    expect((await direct({})).status, 200);
    expect((await direct({serviceHeader: '${t.officePort}'})).status, 503);
    expect((await direct({serviceHeader: 'nope'})).status, 503);

    // Signed out (the password changed): the office asks who's there instead of relaying.
    t.office.token = 'not-a-session';
    final before = t.seen.length;
    final r = await get(t.port, '/hello');
    expect(r.status, 401);
    expect(r.body, contains('Sign in to the office'));
    expect(t.seen.length, before);
  });

  test("a port something on this computer already has is left alone, and opens once it's free", () async {
    final t = await setup();
    final mine = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mine.listen(
      (req) => req.response
        ..write('mine')
        ..close(),
    );
    addTearDown(() => mine.close(force: true));
    await t.office.signIn('', 'hunter2');
    final port = mine.port;
    final items = [Forward(port: port, title: 'Next', command: 'next dev')];
    await t.forwarder.sync(items);
    await t.forwarder.sync(items);
    expect(t.events, ['busy $port taken']);
    expect((await get(port, '/')).body, 'mine');

    await mine.close(force: true);
    await t.forwarder.sync(items);
    expect(t.events, ['busy $port taken', 'opened $port']);
  });

  test("a server that's off the list for a moment keeps its port, and the office answers for it meanwhile", () async {
    final t = await setup();
    final forwarder = Forwarder(t.office, t.said);
    addTearDown(forwarder.close);
    final items = [Forward(port: t.port, title: 'Vite App', command: 'vite')];
    await t.office.signIn('', 'hunter2');
    await forwarder.sync(items, 0);
    // Restarting, or the office missed it for one look: still open, with the office's page for it.
    t.running.clear();
    await forwarder.sync([], 1000);
    await forwarder.sync([], 9000);
    expect(t.events, ['opened ${t.port}']);
    expect((await get(t.port, '/')).status, 503);
    // Back within a few seconds: it never closed, and a later gap starts counting again.
    t.running.add(t.port);
    await forwarder.sync(items, 10000);
    expect((await get(t.port, '/')).body, 'worker GET /');
    await forwarder.sync([], 15000);
    await forwarder.sync([], 24000);
    expect(t.events, ['opened ${t.port}']);
    // Gone for good.
    await forwarder.sync([], 25000);
    expect(t.events, ['opened ${t.port}', 'closed ${t.port}']);
    await expectLater(get(t.port, '/'), refused());
  });

  test("the office's own port on this computer is never one of the ports it opens", () async {
    final t = await setup();
    final events = <String>[];
    final forwarder = Forwarder(
      t.office,
      ForwardEvents(
        opened: (f) => events.add('opened ${f.port}'),
        closed: (_) {},
        busy: (f, _) => events.add('busy ${f.port}'),
      ),
      skip: {t.officePort},
    );
    addTearDown(forwarder.close);
    await forwarder.sync([Forward(port: t.officePort, title: 'x', command: 'x')]);
    expect(events, isEmpty);
  });

  test('where the office is: an SSH address, or an address a browser opens', () {
    expect(officeUrl('office@203.0.113.7'), isNull);
    expect(officeUrl('ssh://office@host:2222'), isNull);
    expect(officeUrl('office-box'), isNull);
    expect(officeUrl('http://localhost:4600')?.origin, 'http://localhost:4600');
    expect(officeUrl('https://office.example.com/')?.origin, 'https://office.example.com');

    expect(TunnelOffice(Uri.parse('http://localhost:4600')).local, isTrue);
    expect(TunnelOffice(Uri.parse('http://[::1]:4600')).local, isTrue);
    expect(TunnelOffice(Uri.parse('https://office.example.com')).local, isFalse);
    expect(TunnelOffice(Uri.parse('https://office.example.com')).host, 'office.example.com');
    expect(TunnelOffice(Uri.parse('https://office.example.com:8443')).host, 'office.example.com:8443');
  });

  test('the command line', () {
    const env = <String, String>{};
    expect(parseTunnelArgs(['--help'], env), isNull);
    final none = parseTunnelArgs([], env)!;
    expect(
      (none.where, none.port, none.officePort, none.credentials, none.open, none.insecure),
      ('', null, 4600, (name: null, password: null), true, false),
    );
    expect(none.ssh, isEmpty);
    final o = parseTunnelArgs(
      [
        'office@203.0.113.7',
        '-p',
        '4700',
        '--office-port',
        '4601',
        '--no-open',
        '--name',
        'cody',
        '--',
        '-i',
        'key',
        '-p',
        '2222',
      ],
      {'AGENT_OFFICE_PASSWORD': 'pw'},
    )!;
    expect(
      (o.where, o.port, o.officePort, o.credentials, o.open, o.insecure),
      ('office@203.0.113.7', 4700, 4601, (name: 'cody', password: 'pw'), false, false),
    );
    expect(o.ssh, ['-i', 'key', '-p', '2222']);
    expect(
      () => parseTunnelArgs(['a@b', 'c@d'], env),
      throwsA(predicate((e) => '$e'.contains('one office at a time'))),
    );
    expect(() => parseTunnelArgs(['--port', 'x'], env), throwsA(predicate((e) => '$e'.contains('port number'))));
    expect(() => parseTunnelArgs(['--wat'], env), throwsA(predicate((e) => '$e'.contains('unknown option'))));

    // The one forward an invited key may open: this computer's port to the office's own.
    expect(sshArgs('office@203.0.113.7', 4700, 4600, ['-i', 'key']).sublist(7), [
      '-L',
      '4700:localhost:4600',
      '-i',
      'key',
      'office@203.0.113.7',
    ]);
  });
}
