import 'dart:io';

import 'package:agent_office_server/src/relay.dart';
import 'package:agent_office_server/src/services.dart';
import 'package:agent_office_server/src/webhook.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('tunneledPort', () {
    Map<String, List<String>> h(String host, {bool relayed = false}) => {
      'host': [host],
      if (relayed) 'x-agent-office-relay': ['1'],
    };

    test('a loopback Host on another port is a service tunnel', () {
      expect(tunneledPort(h('localhost:5173'), 4600), 5173);
      expect(tunneledPort(h('127.0.0.1:3000'), 4600), 3000);
      expect(tunneledPort(h('[::1]:8080'), 4600), 8080);
      expect(tunneledPort(h('app.localhost:5173'), 4600), 5173);
      expect(tunneledPort(h('LOCALHOST:5173'), 4600), 5173);
    });

    test("the office's own port, other hosts and relayed requests are not", () {
      expect(tunneledPort(h('localhost:4600'), 4600), isNull);
      expect(tunneledPort(h('localhost'), 4600), isNull);
      expect(tunneledPort(h('office.example.com:5173'), 4600), isNull);
      expect(tunneledPort(h('localhost:5173', relayed: true), 4600), isNull);
      expect(tunneledPort({}, 4600), isNull);
    });
  });

  group('tailnet and the tunnel client', () {
    const tailnet = 'agent-office.tail1234.ts.net';
    Map<String, List<String>> h(String host, [Map<String, String> extra = const {}]) => {
      'host': [host],
      for (final e in extra.entries) e.key: [e.value],
    };

    test("on the tailnet, <office>.ts.net:<port> is that worker's server, and the office's own name isn't", () {
      expect(tunneledPort(h('$tailnet:5173'), 4600, tailnet), 5173);
      expect(tunneledPort(h('AGENT-OFFICE.tail1234.ts.net:5173'), 4600, tailnet), 5173);
      expect(tunneledPort(h(tailnet), 4600, tailnet), isNull);
      // Another machine's name, or no tailnet at all.
      expect(tunneledPort(h('other.tail1234.ts.net:5173'), 4600, tailnet), isNull);
      expect(tunneledPort(h('$tailnet:5173'), 4600), isNull);
      // Something the office relayed already never loops back.
      expect(tunneledPort(h('$tailnet:5173', {'x-agent-office-relay': '1'}), 4600, tailnet), isNull);
    });

    test("the tunnel client names the port in a header, and never gets the office's own pages for it", () {
      final svc = ServiceInfo(port: 5173, host: '127.0.0.1', pid: 1, command: 'vite', workerId: 'w', since: 0);
      ServiceLookup? lookup(int port) =>
          port == 5173 ? ServiceLookupFound(svc) : (port == 3000 ? ServiceLookupGone() : null);
      Object? view(Tunneled? t) => t == null
          ? null
          : (
              t.port,
              switch (t.svc) {
                ServiceLookupFound(:final info) => info.port,
                ServiceLookupGone() => 'gone',
              },
            );
      Object? named(String port, [String host = 'office.example.com', Map<String, String> extra = const {}]) =>
          view(tunneledService(h(host, {'x-agent-office-service': port, ...extra}), 4600, null, lookup));
      // Whatever address the office was reached at, the header says which server.
      expect(named('5173'), (5173, 5173));
      expect(named('5173', 'localhost:4600'), (5173, 5173));
      expect(named('5173', 'localhost:3000'), (5173, 5173));
      expect(named('3000'), (3000, 'gone'));
      // A port no worker serves, the office's own, or no port at all: stopped, not the office.
      expect(named('8080'), (8080, 'gone'));
      expect(named('4600', 'localhost:4600'), (4600, 'gone'));
      expect(named('nope'), (0, 'gone'));
      expect(named('99999999'), (0, 'gone'));
      // A worker's page can't get to the office by saying the office relayed it already.
      expect(named('5173', 'office.example.com', {'x-agent-office-relay': '1'}), (5173, 5173));
      expect(named('8080', 'localhost:4600', {'x-agent-office-relay': '1'}), (8080, 'gone'));

      // Without the header it goes by the Host, as a service tunnel does, and the office's own pages are its own.
      Object? hosted(String host) => view(tunneledService(h(host), 4600, null, lookup));
      expect(hosted('localhost:5173'), (5173, 5173));
      expect(hosted('localhost:3000'), (3000, 'gone'));
      expect(hosted('localhost:8080'), isNull);
      expect(hosted('localhost:4600'), isNull);
      expect(hosted('office.example.com'), isNull);
    });
  });

  group('pages', () {
    test('the sign-in page asks for what works, and is locked down', () async {
      final r = signInPage(5173, accounts: true, shared: true);
      expect(r.statusCode, 401);
      expect(r.headers['x-frame-options'], ['DENY']);
      expect(r.headers['cache-control'], ['no-store']);
      final html = await r.readAsString();
      expect(html, contains('port 5173'));
      expect(html, contains('Your name (optional)'));
      expect(html, contains('"/__agent-office/login"'));
      final pwOnly = await signInPage(5173, accounts: false, shared: true).readAsString();
      expect(pwOnly, isNot(contains('id="name"')));
      expect(pwOnly, contains('the office password'));
    });

    test('the stopped page is a 503', () {
      expect(stoppedPage(5173).statusCode, 503);
    });
  });

  test('webhookKind', () {
    expect(webhookKind(Uri.parse('https://hooks.slack.com/services/T/B/x')), WebhookKind.slack);
    expect(webhookKind(Uri.parse('https://discord.com/api/webhooks/1/abc')), WebhookKind.discord);
    expect(webhookKind(Uri.parse('https://ptb.discordapp.com/api/webhooks/1/abc')), WebhookKind.discord);
    expect(webhookKind(Uri.parse('https://discord.com/other')), WebhookKind.other);
    expect(webhookKind(Uri.parse('https://example.com/hook')), WebhookKind.other);
  });

  test('webhook settings: validation, hint, and the file', () {
    final dir = Directory.systemTemp.createTempSync('ao-webhook-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final states = <NotifyState>[];
    final w = Webhook(dir.path, ([id]) => 'office', states.add);
    expect(w.set('not a link', 'Ada'), "That isn't a link. Paste the webhook URL from Slack or Discord.");
    expect(w.set('ftp://x.com/a', 'Ada'), 'The webhook has to be an http(s) link');
    expect(w.set('https://hooks.slack.com/services/T0/B0/secretXYZ', 'Ada'), isNull);
    final s = w.state().webhook!;
    expect(s.kind, WebhookKind.slack);
    expect(s.hint, 'hooks.slack.com/…tXYZ');
    expect(states, hasLength(1));
    final again = Webhook(dir.path, ([id]) => 'office', (_) {});
    expect(again.state().webhook?.by, 'Ada');
    expect(w.set('', 'Ada'), isNull);
    expect(Webhook(dir.path, ([id]) => 'office', (_) {}).state().webhook, isNull);
  });
}
