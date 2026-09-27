import 'dart:io';

import 'package:agent_office_server/src/relay.dart';
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
