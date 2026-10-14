import 'dart:async';

import 'package:agent_office_server/src/tailnet.dart';
import 'package:agent_office_server/src/team.dart';
import 'package:test/test.dart';

void main() {
  test('teammates tunnel to office@host, or ssh://office@host:port off port 22', () {
    expect(sshAddress('203.0.113.7'), 'office@203.0.113.7');
    expect(sshAddress('203.0.113.7:22'), 'office@203.0.113.7');
    expect(sshAddress('roundhouse.proxy.rlwy.net:41234'), 'ssh://office@roundhouse.proxy.rlwy.net:41234');
    expect(sshAddress('office.example.com'), 'office@office.example.com');
  });

  test('on a tailnet without the invite helper, the panel says how to share the machine there', () async {
    final s = await Team(null, 4600, tailnet: 'agent-office.tail1234.ts.net', deploy: 'deploy/azure.sh').state();
    expect(s.toJson(), {
      'port': 4600,
      'deploy': 'deploy/azure.sh',
      'members': <Object>[],
      'tailnet': 'agent-office.tail1234.ts.net',
    });
    final none = await Team(null, 4600).state();
    expect(none.unavailable, contains('deploy/provision.sh'));
  });

  test("the tailnet serves exactly the workers' ports, one change at a time", () async {
    final calls = <List<String>>[];
    final gate = <Completer<String>>[];
    final t = Tailnet(
      'agent-office.tail1234.ts.net',
      run: (args) {
        calls.add(args);
        final c = Completer<String>();
        gate.add(c);
        return c.future;
      },
    );
    t.sync([5173, 3000, 5173]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [
      ['sync', '3000', '5173'],
    ]);
    // Changes while the helper runs wait for it, and only the latest goes.
    t.sync([3000]);
    t.sync([8080]);
    gate.removeAt(0).complete('');
    await Future<void>.delayed(Duration.zero);
    expect(calls.last, ['sync', '8080']);
    gate.removeAt(0).complete('');
    await t.idle;
    // The same again: nothing to do.
    t.sync([8080]);
    await t.idle;
    expect(calls, hasLength(2));
    // A failure is tried again on the next change.
    t.sync([]);
    await Future<void>.delayed(Duration.zero);
    gate.removeAt(0).complete('no tailscale');
    await t.idle;
    t.sync([]);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last, ['sync']);
    gate.removeAt(0).complete('');
    await t.idle;

    // Off a tailnet it never runs.
    final off = Tailnet(null, run: (a) async => throw StateError('ran'));
    off.sync([1]);
    await off.idle;
  });
}
