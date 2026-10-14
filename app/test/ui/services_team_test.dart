// The Services and Invite panels on an office on a Tailscale network, deployed by another script, or
// reached through an SSH tunnel (#164, #175, #176, #273).

import 'package:agent_office/ui/commands.dart';
import 'package:agent_office/ui/services.dart';
import 'package:agent_office/ui/team.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  test('tailnet links, the deploy script, and agent-office tunnel', () {
    expect(serviceUrl(5173, tailnet: 'office.tail1.ts.net'), 'https://office.tail1.ts.net:5173');
    expect(serviceUrl(5173, secure: true), 'https://localhost:5173');
    expect(onTailnet('office.tail1.ts.net', 'office.tail1.ts.net'), isTrue);
    expect(onTailnet('office.tail1.ts.net', 'localhost'), isFalse, reason: 'opened another way');
    expect(onTailnet(null, 'localhost'), isFalse);
    expect(deployScript(null), 'deploy/aws.sh');
    expect(deployScript('deploy/azure.sh --name two'), 'deploy/azure.sh --name two');
    expect(autoTunnel('http://localhost:4600'), 'agent-office tunnel');
    expect(autoTunnel('https://office.example.com'), 'agent-office tunnel https://office.example.com');
    final local = ServicesState.fromJson({'items': [], 'port': 4600});
    expect(officeElsewhere(local, 'localhost'), isFalse);
    expect(officeElsewhere(local, '127.0.0.1'), isFalse);
    expect(officeElsewhere(local, 'office.example.com'), isTrue);
    expect(
      officeElsewhere(ServicesState.fromJson({'items': [], 'port': 4600, 'ssh': 'office@1.2.3.4'}), 'localhost'),
      isTrue,
    );
    final msg = tailnetMessage(TeamState.fromJson({'port': 4600, 'members': [], 'tailnet': 'o.tail1.ts.net'}), 'app');
    expect(
      msg,
      startsWith("You're invited to the app Agent Office: https://o.tail1.ts.net\n\nIt's on our Tailscale network."),
    );
  });

  testWidgets('the Services board says how to open them all at once, with its deploy script', (tester) async {
    final office = Office()..welcome();
    office.store.apply(
      ServerMsg.parse({
        't': 'services',
        'state': {
          'items': [
            {'port': 5173, 'pid': 1, 'workerId': 'w1', 'command': 'vite', 'since': 0},
          ],
          'port': 4600,
          'ssh': 'office@203.0.113.7',
          'deploy': 'deploy/azure.sh',
        },
      }),
    );
    await office.pump(tester, const SizedBox());
    openServices(office.scope());
    await tester.pump();
    expect(find.byKey(const ValueKey('svc-auto')), findsOneWidget);
    expect(find.textContaining('agent-office tunnel'), findsWidgets);
    expect(find.textContaining('deploy/azure.sh service <port>', findRichText: true), findsOneWidget);
  });

  testWidgets('on the tailnet, the Invite panel says how to let someone onto the network', (tester) async {
    final office = Office()..welcome();
    office.store.apply(
      ServerMsg.parse({
        't': 'team',
        'state': {
          'port': 4600,
          'members': [
            {'name': 'bo', 'keys': 2},
          ],
          'tailnet': 'agent-office.tail1234.ts.net',
        },
      }),
    );
    await office.pump(tester, const SizedBox());
    openTeam(office.scope());
    await tester.pump();
    expect(find.text('Everyone on your Tailscale network opens'), findsOneWidget);
    expect(find.textContaining('https://agent-office.tail1234.ts.net'), findsWidgets);
    expect(find.textContaining('Share this one machine', findRichText: true), findsOneWidget);
    expect(find.text('Invite someone by their GitHub username'), findsNothing);
    expect(find.text('bo'), findsOneWidget, reason: 'invited by key before the tailnet');
  });

  testWidgets('an SSH address with its own port (Railway) leaves out the allow-their-IP note', (tester) async {
    final office = Office()..welcome();
    office.store.apply(
      ServerMsg.parse({
        't': 'team',
        'state': {
          'port': 4600,
          'members': [],
          'ssh': 'ssh://office@tcp.railway.app:12345',
          'deploy': 'deploy/railway.sh',
        },
      }),
    );
    await office.pump(tester, const SizedBox());
    openTeam(office.scope());
    await tester.pump();
    expect(find.textContaining('ssh://office@tcp.railway.app:12345'), findsWidgets);
    expect(find.textContaining('SSH only answers IP addresses', findRichText: true), findsNothing);
  });
}
