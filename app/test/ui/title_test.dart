import 'package:office_shared/protocol.dart';
import 'package:agent_office/ui/commands.dart';
import 'package:agent_office/ui/title.dart';
import 'package:flutter_test/flutter_test.dart';

FloorInfo floor(String id, String name, int waiting) =>
    FloorInfo.fromJson({'id': id, 'name': name, 'dir': '/w/$id', 'waiting': waiting});
WorkerInfo worker(String status, {bool acked = false}) =>
    WorkerInfo.fromJson({'id': status, 'status': status, 'acked': acked});

void main() {
  test('the tab title counts who is waiting, here and on other floors', () {
    final floors = [floor('a', 'app', 5), floor('b', 'api', 2)];
    expect(officeTitle(floors: const [], workers: const []), 'Agent Office');
    expect(
      officeTitle(project: 'app', floors: floors, floor: 'a', workers: [worker('working')]),
      '(2) app · Agent Office',
    );
    expect(
      officeTitle(
        project: 'app',
        floors: floors,
        floor: 'a',
        workers: [worker('needs_input'), worker('done'), worker('done', acked: true)],
      ),
      '(4) app · Agent Office',
    );
    expect(waitingElsewhere(floors, 'b'), 5);
  });

  test('the project line', () {
    final p = ProjectInfo.fromJson({'name': 'app', 'dir': '/w/app', 'branch': 'main', 'defaultProvider': 'claude'});
    expect(
      projectMeta(project: null, floors: const [], defaultProvider: ''),
      '🛗 No floors yet — add a project in the elevator',
    );
    expect(
      projectMeta(project: null, floors: [floor('a', 'app', 0)], defaultProvider: ''),
      '🛗 Take the elevator to a floor',
    );
    expect(
      projectMeta(
        project: p,
        floors: [floor('a', 'app', 0), floor('b', 'api', 0)],
        floor: 'b',
        defaultProvider: 'Claude Code',
      ),
      '🛗 floor 2 of 2 · ⎇ main · /w/app · default: Claude Code',
    );
    expect(projectTooltip(1), '1 worker on other floors waiting on someone — click to ride the elevator');
    expect(projectTooltip(0), 'The elevator: ride to another project');
  });

  test('noticing more workers waiting on another floor', () {
    final watch = FloorWaitWatch();
    expect(watch.update([floor('a', 'app', 1), floor('b', 'api', 0)], 'a'), isEmpty);
    expect(watch.update([floor('a', 'app', 3), floor('b', 'api', 1)], 'a').map((f) => f.name), ['api']);
    expect(watch.update([floor('a', 'app', 3), floor('b', 'api', 1)], 'a'), isEmpty);
    expect(watch.update([floor('a', 'app', 3), floor('b', 'api', 0), floor('c', 'web', 4)], 'a'), isEmpty);
  });

  test('invite and tunnel commands', () {
    final t = TeamState.fromJson({'ssh': 'office@1.2.3.4', 'port': 4600, 'fingerprint': 'SHA256:abc', 'members': []});
    expect(
      tunnelCommand(t, Os.mac),
      'ssh -o ExitOnForwardFailure=yes -o PermitLocalCommand=yes -o LocalCommand="open http://localhost:4600" -L 4600:localhost:4600 office@1.2.3.4',
    );
    final msg = inviteMessage(t, Os.linux, 'app');
    expect(msg, startsWith("You're invited to the app Agent Office. Run this in a terminal (Linux):\n\nssh "));
    expect(msg, contains('xdg-open http://localhost:4600 >/dev/null 2>&1 &'));
    expect(msg, endsWith('Only say yes if it shows SHA256:abc'));
    final noFp = inviteMessage(TeamState.fromJson({'ssh': 'o@h', 'port': 1, 'members': []}), Os.windows, null);
    expect(noFp, startsWith("You're invited to the our Agent Office"));
    expect(noFp, endsWith("keep that terminal open while you're in."));
    final s = ServicesState.fromJson({'items': [], 'port': 4600});
    expect(
      serviceTunnel(s, 5173, Os.windows),
      'ssh -N -o ExitOnForwardFailure=yes -o PermitLocalCommand=yes -o LocalCommand="start http://localhost:5173" -L 5173:localhost:4600 you@your-server',
    );
  });

  test('invite links and expiry', () {
    final v = AccountInvite.fromJson({
      'id': 'i',
      'token': 'tok',
      'role': 'member',
      'createdBy': 'a',
      'createdAt': 0,
      'expiresAt': 0,
    });
    expect(inviteLink(v, 'https://office.example'), 'https://office.example/join#tok');
    expect(expiresIn(3 * 86400000, 0), 'expires in 3 days');
    expect(expiresIn(86400000, 0), 'expires in 1 day');
    expect(expiresIn(3600000, 0), 'expires today');
  });
}
