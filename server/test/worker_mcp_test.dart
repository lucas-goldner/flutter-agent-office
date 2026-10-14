// The office's MCP server and office-workers for every worker (upstream #192), and a Claude worker's
// own `gh pr create` making that pull request its own (#274).
@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/hook.dart' show officeCommand;
import 'package:agent_office_server/src/workers.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workers_test.dart' show Fixture, isolatedEnv, ledger, manager, spawned, waitFor;

void main() {
  test("every Claude worker gets the office's MCP server, and office-workers on its PATH", () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], isolatedEnv(f, {'FAKE_AGENT_LOG': f.log}));
    addTearDown(workers.shutdown);

    final bin = p.join(f.data, 'bin');
    final shim = File(p.join(bin, 'office-workers'));
    expect(shim.existsSync(), isTrue);
    expect(shim.statSync().mode & 0x40, isNot(0), reason: 'executable');
    expect(shim.readAsStringSync(), contains('workers "\$@"'));
    // Claude Code's --mcp-config: the office's own executable, run as an MCP server.
    final config = p.join(f.data, 'agent-office-mcp.json');
    final server = ((jsonDecode(File(config).readAsStringSync()) as Map)['mcpServers'] as Map)['agent-office'] as Map;
    final office = officeCommand();
    expect(server['command'], office.first);
    expect(server['args'], [...office.sublist(1), 'workers', 'mcp']);
    // Looking is allowed without asking; hiring and sending home aren't.
    expect((jsonDecode(File(p.join(f.data, 'claude-hooks.json')).readAsStringSync()) as Map)['permissions'], {
      'allow': ['mcp__agent-office__list_workers'],
    });

    final desk = spawned(workers.spawn('desk-2', 'Ada', 'Fix login'));
    final launch = (await waitFor(
      () => f.read().where((r) => r.kind == 'claude' && r.stdin == null && r.workerId == desk.id).toList(),
      (l) => l.length == 1,
    )).first;
    // Before --settings, which ends the list of configs --mcp-config takes.
    final at = launch.args.indexOf('--mcp-config');
    expect(at, greaterThanOrEqualTo(0));
    expect(launch.args[at + 1], config);
    expect(launch.args[at + 2], '--settings');
    expect((launch.path ?? '').split(':').first, bin);
  });

  test('a Claude worker that opens a pull request itself has it as its own', () async {
    final f = Fixture();
    addTearDown(f.close);
    Process.runSync('git', ['init', '-q'], workingDirectory: f.root);
    Process.runSync('git', ['remote', 'add', 'origin', 'git@github.com:acme/app.git'], workingDirectory: f.root);
    final toasts = <String>[];
    final workers = WorkerManager(
      f.root,
      f.data,
      f.claude,
      const [],
      const HookEnv(url: 'http://127.0.0.1:1', token: ''),
      WorkerEvents(
        update: (_) {},
        remove: (_) {},
        data: (_, _, _) {},
        screen: (_, _) {},
        toast: (text, _) => toasts.add(text),
      ),
      ledger(f.data),
      env: isolatedEnv(f, {'FAKE_AGENT_LOG': f.log}),
    );
    addTearDown(workers.shutdown);
    // In the main checkout: the branch it pushes is one the office never made.
    final worker = spawned(workers.spawn('desk-1', 'test', 'fix the login redirect and open a pull request'));
    expect(worker.worktree, isNull);
    final launch = (await waitFor(
      () => f.read().where((r) => r.kind == 'claude' && r.args.contains('--settings')).toList(),
      (l) => l.length == 1,
    )).first;
    void hook(String event, Map<String, Object?> payload) =>
        expect(workers.handleHook(worker.id, launch.hookToken!, event, {'session_id': 'pr', ...payload}), isTrue);
    PrRef? pr() => workers.get(worker.id)?.pr;
    const create = {
      'tool_name': 'Bash',
      'tool_input': {
        'command': 'cd ../wt && git push -u origin fix-login && gh pr create --title "Fix login" --body "Closes #4"',
      },
    };
    hook('SessionStart', {});
    hook('UserPromptSubmit', {'prompt': 'fix the login redirect and open a pull request'});
    // Looking at someone's, naming the command, or opening one in another repository: none of them is its own.
    hook('PostToolUse', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'gh pr view 3 --json url'},
      'tool_response': {'stdout': 'https://github.com/acme/app/pull/3'},
    });
    hook('PostToolUse', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'grep -rn "gh pr create" docs'},
      'tool_response': {'stdout': 'docs/a.md: gh pr create … https://github.com/acme/app/pull/3'},
    });
    hook('PostToolUse', {
      ...create,
      'tool_response': {'stdout': 'https://github.com/other/thing/pull/9\n', 'stderr': ''},
    });
    expect(pr(), isNull);
    hook('PostToolUse', {
      ...create,
      'tool_response': {
        'stdout': 'https://github.com/acme/app/pull/12\n',
        'stderr': 'Creating pull request for fix-login into main in acme/app',
      },
    });
    expect((pr()?.number, pr()?.url), (12, 'https://github.com/acme/app/pull/12'));
    expect(toasts, ['${worker.name} opened PR #12']);
    final saved = jsonDecode(File(p.join(f.data, 'workers.json')).readAsStringSync()) as List;
    expect(
      ((saved.firstWhere((w) => w['id'] == worker.id) as Map)['pr'] as Map)['number'],
      12,
      reason: 'kept across a restart',
    );
    // A follow-up whose branch already had one: gh fails, and says which.
    hook('PostToolUseFailure', {
      ...create,
      'error':
          'Exit code 1\na pull request for branch "fix-more" into branch "main" already exists:\nhttps://github.com/acme/app/pull/14',
    });
    expect(pr()?.number, 14);
    expect(workers.get(worker.id)?.pastPrs, [12], reason: 'the first one is still its own');
    // Said again, it's no news.
    hook('PostToolUseFailure', {...create, 'error': 'Exit code 1\nhttps://github.com/acme/app/pull/14'});
    expect(toasts.length, 2);

    // And someone can say which is whose, or that none is (office-workers pr).
    expect(workers.linkPr(worker.id, const PrRef(number: 20, url: 'https://github.com/acme/app/pull/20')), isNull);
    expect(pr()?.number, 20);
    expect(workers.get(worker.id)?.pastPrs, isEmpty, reason: 'said by someone: only that one');
    expect(workers.linkPr(worker.id, null), isNull);
    expect(pr(), isNull);
    expect(workers.linkPr('nobody', const PrRef(number: 20, url: 'u')), 'No such worker');
  });
}
