// Port of tests/office-queue.test.ts: `agent-office queue`, upstream's bin/office-queue.js.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/queue_cmd.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const env = {
  'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:4455',
  'AGENT_OFFICE_WORKER_ID': 'w1 &x',
  'AGENT_OFFICE_HOOK_TOKEN': 'tok',
};
const QueueOffice office = (url: 'http://127.0.0.1:4455', worker: 'w1', token: 'tok');

Matcher usageError(Pattern message) =>
    throwsA(isA<QueueUsageError>().having((e) => e.message, 'message', matches(message)));

/// What [runQueueCommand] printed and sent.
typedef Ran = ({int code, List<QueueRequest> sent, String out, String err});

Future<Ran> run(
  List<String> argv, {
  Map<String, String> environment = env,
  String? stdin,
  int status = 200,
  Object? body,
}) async {
  final sent = <QueueRequest>[];
  final out = <String>[], err = <String>[];
  final code = await runQueueCommand(
    argv,
    env: environment,
    input: Stream.value(utf8.encode(stdin ?? '')),
    inputIsTerminal: false,
    send: (req) async {
      sent.add(req);
      return (status: status, body: body ?? const {});
    },
    out: out.add,
    err: err.add,
  );
  return (code: code, sent: sent, out: out.join('\n'), err: err.join('\n'));
}

void main() {
  test('parses list, add and remove, with their options', () {
    expect(parseQueueArgs([]), const QueueHelp());
    expect(parseQueueArgs(['--help']), const QueueHelp());
    expect(parseQueueArgs(['add', '--help']), const QueueHelp());
    expect(parseQueueArgs(['list']), const QueueList());
    expect(parseQueueArgs(['ls']), const QueueList());
    expect(parseQueueArgs(['remove', 'abc123']), const QueueRemove('abc123'));
    expect(parseQueueArgs(['rm', 'abc123']), const QueueRemove('abc123'));
    expect(parseQueueArgs(['add', '--title', 'Fix login']), const QueueAdd(title: 'Fix login'));
    expect(
      parseQueueArgs(['add', '--title=Fix login', '--issue', '12']),
      const QueueAdd(title: 'Fix login', issue: 12),
    );
    expect(
      parseQueueArgs(['add', '--issue=#7', '--title', ' Fix login ', '--prompt', 'Do it']),
      const QueueAdd(title: 'Fix login', issue: 7, prompt: 'Do it'),
    );
    // A prompt that looks like an option is still the prompt.
    expect(
      parseQueueArgs(['add', '--title', 'T', '--prompt', '- fix the list']),
      const QueueAdd(title: 'T', prompt: '- fix the list'),
    );
  });

  test('says what is wrong with a bad command line', () {
    final bad = <(List<String>, String)>[
      (['frobnicate'], 'Unknown command: frobnicate'),
      (['list', 'extra'], 'list takes no arguments'),
      (['remove'], 'remove takes one task id'),
      (['remove', 'a', 'b'], 'remove takes one task id'),
      (['add'], '--title'),
      (['add', '--title'], '--title needs a value'),
      (['add', '--title', '  '], 'Give the task a --title'),
      (['add', '--title', 'T', '--issue', 'twelve'], '--issue takes an issue number'),
      (['add', '--title', 'T', '--issue', '0'], '--issue takes an issue number'),
      (['add', '--title', 'T', '--model', 'x'], 'Unknown option for add: --model'),
      (['add', 'Fix', 'login'], 'Unexpected argument: Fix'),
    ];
    for (final (argv, message) in bad) {
      expect(() => parseQueueArgs(argv), usageError(message), reason: argv.join(' '));
    }
  });

  test('needs the office address, its worker id and its token from the environment', () {
    final o = queueOfficeEnv({...env, 'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:4455/'});
    expect(o, (url: 'http://127.0.0.1:4455', worker: 'w1 &x', token: 'tok'));
    expect(
      () => queueOfficeEnv({}),
      throwsA(
        isA<QueueError>().having(
          (e) => e.message,
          'message',
          matches(
            RegExp(
              r"AGENT_OFFICE_HOOK_URL, AGENT_OFFICE_WORKER_ID, AGENT_OFFICE_HOOK_TOKEN aren't set.*inside Agent Office",
            ),
          ),
        ),
      ),
    );
    expect(
      () => queueOfficeEnv({...env, 'AGENT_OFFICE_HOOK_TOKEN': ''}),
      throwsA(isA<QueueError>().having((e) => e.message, 'message', startsWith("AGENT_OFFICE_HOOK_TOKEN isn't set"))),
    );
  });

  test('builds the /office/queue requests', () {
    const auth = {'authorization': 'Bearer tok'};
    final list = buildQueueRequest(const QueueList(), (url: office.url, worker: 'w1 &x', token: 'tok'));
    expect(list.method, 'GET');
    expect('${list.url}', 'http://127.0.0.1:4455/office/queue?worker=w1+%26x');
    expect(list.headers, auth);
    final remove = buildQueueRequest(const QueueRemove('abc/123'), office);
    expect(remove.method, 'DELETE');
    expect('${remove.url}', 'http://127.0.0.1:4455/office/queue?worker=w1&task=abc%2F123');
    final add = buildQueueRequest(
      const QueueAdd(title: 'Fix login', issue: 12),
      office,
      'Fix the redirect in src/login.ts.\r\nThen open a PR.\n',
    );
    expect(add.method, 'POST');
    expect('${add.url}', 'http://127.0.0.1:4455/office/queue?worker=w1');
    expect(add.headers, {...auth, 'content-type': 'application/json'});
    expect(jsonDecode(add.body!), {
      'title': 'Fix login',
      'prompt': 'Fix the redirect in src/login.ts.\nThen open a PR.',
      'issue': 12,
    });
    // --prompt wins over stdin; with no issue there's no "issue" key.
    final flagged = buildQueueRequest(const QueueAdd(title: 'T', prompt: 'from the flag'), office, 'from stdin');
    expect(jsonDecode(flagged.body!), {'title': 'T', 'prompt': 'from the flag'});
    expect(() => buildQueueRequest(const QueueAdd(title: 'T'), office, '  \n'), usageError('needs a prompt'));
  });

  test('lists the queue readably: id, status, title, worker and PR', () {
    expect(formatQueue({'maxWorkers': 2, 'tasks': []}), 'The queue is empty · up to 2 at a time.');
    final text = formatQueue({
      'maxWorkers': 2,
      'tasks': [
        {
          'id': 'aaa111',
          'title': 'Fix login',
          'status': 'running',
          'issue': 12,
          'worker': 'Pixel',
          'branch': 'office/pixel-1a2b',
        },
        {'id': 'bbb222', 'title': 'Dark mode', 'status': 'queued'},
        {
          'id': 'ccc333',
          'title': 'Rename the dog',
          'status': 'done',
          'outcome': 'done',
          'worker': 'Byte',
          'pr': {'number': 9, 'url': 'https://github.com/o/r/pull/9', 'state': 'OPEN', 'title': 'x'},
        },
        {'id': 'ddd444', 'title': 'Broken', 'status': 'done', 'outcome': 'failed', 'error': 'no desk'},
      ],
    });
    expect(
      text,
      [
        '4 tasks · up to 2 at a time',
        'aaa111  running        Fix login (issue #12) · worker Pixel on office/pixel-1a2b',
        'bbb222  queued         Dark mode',
        'ccc333  done           Rename the dog · worker Byte · PR #9 open https://github.com/o/r/pull/9',
        'ddd444  done (failed)  Broken · error: no desk',
      ].join('\n'),
    );
  });

  test('add sends the prompt from stdin and prints the new task id', () async {
    final r = await run(
      ['add', '--title', 'Fix login', '--issue', '12'],
      stdin: 'Fix it.\n',
      body: {
        'ok': true,
        'task': {'id': 'abc123', 'title': 'Fix login', 'status': 'queued'},
      },
    );
    expect(r.code, 0);
    expect(r.out, 'abc123');
    expect(r.err, contains('Queued “Fix login” (queued, issue #12)'));
    expect(r.sent.length, 1);
    expect(r.sent[0].method, 'POST');
    expect(jsonDecode(r.sent[0].body!), {'title': 'Fix login', 'prompt': 'Fix it.', 'issue': 12});
  });

  test('clear errors when the environment is missing or the office says no', () async {
    final noEnv = await run(['list'], environment: const {});
    expect(noEnv.code, 1);
    expect(noEnv.sent, isEmpty);
    expect(
      noEnv.err,
      startsWith(
        "agent-office queue: AGENT_OFFICE_HOOK_URL, AGENT_OFFICE_WORKER_ID, AGENT_OFFICE_HOOK_TOKEN aren't set",
      ),
    );

    final desk = await run(
      ['list'],
      status: 403,
      body: {'error': 'Only the agents standing by the boards can use the queue'},
    );
    expect(desk.code, 1);
    expect(
      desk.err,
      'agent-office queue: The office said no (403): Only the agents standing by the boards can use the queue.',
    );

    final stale = await run(['list'], status: 401, body: {'error': 'Send your own AGENT_OFFICE_WORKER_ID'});
    expect(stale.err, contains("didn't accept this agent's token (401)"));

    final running = await run(
      ['remove', 'abc123'],
      status: 400,
      body: {'error': 'Pixel is on it — send the worker home to stop it'},
    );
    expect(
      running.err,
      'agent-office queue: The office said no (400): Pixel is on it — send the worker home to stop it.',
    );

    final noPrompt = await run(['add', '--title', 'T'], stdin: '');
    expect(noPrompt.code, 2);
    expect(noPrompt.sent, isEmpty);
    expect(noPrompt.err, matches(RegExp(r'needs a prompt[\s\S]*Usage:')));

    final usage = await run(['add', 'oops']);
    expect(usage.code, 2);
    expect(usage.err, matches(RegExp(r'Unexpected argument: oops[\s\S]*Usage:')));
  });

  test('list and remove print what the office sent back', () async {
    final list = await run(
      ['list'],
      body: {
        'maxWorkers': 1,
        'tasks': [
          {'id': 'abc123', 'title': 'Fix login', 'status': 'queued'},
        ],
      },
    );
    expect(list.code, 0);
    expect(list.sent[0].method, 'GET');
    expect(list.out, '1 task · up to 1 at a time\nabc123  queued  Fix login');
    final removed = await run(['remove', 'abc123'], body: {'maxWorkers': 1, 'tasks': []});
    expect(removed.code, 0);
    expect(removed.sent[0].method, 'DELETE');
    expect(removed.out, 'Took abc123 off the queue.');
  });

  test("runs as a command: a heredoc prompt goes over HTTP with the agent's own token", () async {
    final seen = <Map<String, Object?>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final auth = req.headers.value('authorization');
      seen.add({'method': req.method, 'url': '${req.uri}', 'auth': auth, 'body': body});
      final ok = auth == 'Bearer tok';
      req.response
        ..statusCode = ok ? 200 : 403
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(
            ok
                ? {
                    'ok': true,
                    'task': {'id': 'f00d', 'title': 'Fix login', 'status': 'queued'},
                  }
                : {'error': 'Only the agents standing by the boards can use the queue'},
          ),
        );
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}';
    final entry = p.join(Directory.current.path, 'bin', 'agent_office.dart');
    Future<({int code, String stdout, String stderr})> cli(Map<String, String> environment, String input) async {
      final proc = await Process.start(
        Platform.resolvedExecutable,
        ['run', entry, 'queue', 'add', '--title', 'Fix login'],
        environment: {
          'PATH': Platform.environment['PATH'] ?? '',
          'HOME': Platform.environment['HOME'] ?? '',
          ...environment,
        },
        includeParentEnvironment: false,
      );
      proc.stdin.write(input);
      await proc.stdin.close();
      final out = utf8.decoder.bind(proc.stdout).join();
      final err = utf8.decoder.bind(proc.stderr).join();
      return (code: await proc.exitCode, stdout: await out, stderr: await err);
    }

    final ok = await cli(
      {...env, 'AGENT_OFFICE_HOOK_URL': url, 'AGENT_OFFICE_WORKER_ID': 'w1'},
      r"Don't expand $HOME or `this`."
      '\n',
    );
    expect(ok.code, 0, reason: ok.stderr);
    expect(ok.stdout, 'f00d\n');
    expect(seen[0], {
      'method': 'POST',
      'url': '/office/queue?worker=w1',
      'auth': 'Bearer tok',
      'body': jsonEncode({'title': 'Fix login', 'prompt': r"Don't expand $HOME or `this`."}),
    });

    final desk = await cli({...env, 'AGENT_OFFICE_HOOK_URL': url, 'AGENT_OFFICE_HOOK_TOKEN': 'desk-token'}, 'x');
    expect(desk.code, 1);
    expect(desk.stdout, '');
    expect(desk.stderr, contains('The office said no (403): Only the agents standing by the boards'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
