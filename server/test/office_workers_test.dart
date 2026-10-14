// Port of tests/office-workers.test.ts (upstream #192, #274): the `office-workers` command and MCP
// server (workers_cmd.dart), and how the office reads their requests (office_workers.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/leave_on_merge.dart' show notLeaving;
import 'package:agent_office_server/src/office_workers.dart';
import 'package:agent_office_server/src/worker_pr.dart' show ownPr;
import 'package:agent_office_server/src/workers_cmd.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

const env = {
  'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:4455/',
  'AGENT_OFFICE_WORKER_ID': 'w1',
  'AGENT_OFFICE_HOOK_TOKEN': 'tok',
};
const WorkersOffice office = (url: 'http://127.0.0.1:4455', worker: 'w1', token: 'tok');

WorkerInfo worker(String id, [Map<String, Object?> more = const {}]) => WorkerInfo.fromJson({
  'id': id,
  'kind': 'agent',
  'deskId': 'desk-1',
  'name': id[0].toUpperCase() + id.substring(1),
  'color': '#fff',
  'status': 'done',
  'acked': false,
  'createdBy': 'Ada',
  'createdAt': 0,
  'cols': 80,
  'rows': 24,
  'viewers': <String>[],
  'worktree': {'path': '.agent-office/worktrees/$id', 'branch': 'office/$id', 'base': 'abc'},
  ...more,
});

GhPull pull(int number, String state, String head, [String? oid]) => GhPull.fromJson({
  'number': number,
  'title': 'PR $number',
  'state': state,
  'isDraft': false,
  'url': 'https://github.com/acme/app/pull/$number',
  'author': '',
  'labels': <String>[],
  'reviewDecision': '',
  'headRefName': head,
  'headRefOid': ?oid,
  'baseRefName': 'main',
  'createdAt': '',
  'updatedAt': '',
  'additions': 0,
  'deletions': 0,
  'checks': 'none',
  'body': '',
  'closes': <int>[],
});

PullsView viewOf(List<GhPull> pulls) => (pulls: pulls, tasks: const [], pullsOf: null);

WorkersSend reply(int status, Object? body, [List<WorkersRequest>? calls]) => (req) async {
  calls?.add(req);
  return (status: status, body: body);
};

void main() {
  test('parses list, hire, home, tell, pr and mcp', () {
    expect(parseWorkersArgs(['pr', '12']), {'cmd': 'pr', 'pr': '12', 'json': false});
    expect(parseWorkersArgs(['pr', 'https://github.com/acme/app/pull/12', '--worker', 'Mochi', '--json']), {
      'cmd': 'pr',
      'pr': 'https://github.com/acme/app/pull/12',
      'worker': 'Mochi',
      'json': true,
    });
    expect(parseWorkersArgs(['link-pr', '--none', '--worker=b0b']), {
      'cmd': 'pr',
      'unlink': true,
      'worker': 'b0b',
      'json': false,
    });
    expect(parseWorkersArgs([]), {'cmd': 'help'});
    expect(parseWorkersArgs(['home', '--help']), {'cmd': 'help'});
    expect(parseWorkersArgs(['mcp']), {'cmd': 'mcp'});
    expect(parseWorkersArgs(['list']), {'cmd': 'list', 'json': false});
    expect(parseWorkersArgs(['ls', '--json']), {'cmd': 'list', 'json': true});
    expect(parseWorkersArgs(['home', 'Mochi', 'b0b']), {
      'cmd': 'home',
      'workers': ['Mochi', 'b0b'],
      'merged': false,
      'json': false,
    });
    expect(parseWorkersArgs(['home', '--merged', '--cleanup=keep']), {
      'cmd': 'home',
      'workers': <String>[],
      'merged': true,
      'cleanup': 'keep',
      'json': false,
    });
    expect(parseWorkersArgs(['send-home', '--merged']), {
      'cmd': 'home',
      'workers': <String>[],
      'merged': true,
      'json': false,
    });
    expect(parseWorkersArgs(['tell', 'Mochi', '--prompt', '- rebase on main']), {
      'cmd': 'tell',
      'worker': 'Mochi',
      'prompt': '- rebase on main',
    });
    expect(
      parseWorkersArgs([
        'hire',
        '--provider',
        'codex',
        '--effort=high',
        '--issue',
        '#12',
        '--no-worktree',
        '--desk',
        'desk-4',
      ]),
      {
        'cmd': 'hire',
        'json': false,
        'provider': 'codex',
        'effort': 'high',
        'issue': 12,
        'worktree': false,
        'desk': 'desk-4',
      },
    );
  });

  test('says what is wrong with a bad command line', () {
    final bad = <(List<String>, String)>[
      (['frobnicate'], 'Unknown command: frobnicate'),
      (['list', 'x'], 'list takes no arguments'),
      (['home'], 'Say who goes home'),
      (['home', 'Mochi', '--merged'], 'not both'),
      (['home', '--merged', '--cleanup', 'nuke'], '--cleanup is one of auto, keep, worktree, all'),
      (['home', '-f', 'Mochi'], 'Unknown option: -f'),
      (['tell'], 'tell takes one worker'),
      (['pr'], 'pr takes one pull request'),
      (['pr', '12', '13'], 'pr takes one pull request'),
      (['pr', '12', '--none'], 'pr takes one pull request'),
      (['tell', 'a', 'b'], 'tell takes one worker'),
      (['hire', 'do it'], 'Unexpected argument: do it'),
      (['hire', '--effort', 'huge'], '--effort is one of'),
      (['hire', '--issue', 'twelve'], '--issue takes an issue number'),
      (['hire', '--model'], '--model needs a value'),
      (['mcp', 'x'], 'mcp takes no arguments'),
    ];
    for (final (argv, why) in bad) {
      expect(
        () => parseWorkersArgs(argv),
        throwsA(isA<WorkersUsageError>().having((e) => e.message, 'message', contains(why))),
        reason: argv.join(' '),
      );
    }
  });

  test('builds requests for each call, with the worker and its token', () {
    final list = buildWorkersRequest('list', office);
    expect(list.method, 'GET');
    expect('${list.url}', 'http://127.0.0.1:4455/office/workers?worker=w1');
    expect(list.headers['authorization'], 'Bearer tok');
    final home = buildWorkersRequest('home', office, {'merged': true});
    expect('${home.url}', 'http://127.0.0.1:4455/office/workers/home?worker=w1');
    expect(home.method, 'POST');
    expect(home.body, '{"merged":true}');
    expect(home.timeout > list.timeout, isTrue, reason: 'sending home waits on git');
    expect('${buildWorkersRequest('tell', office, {}).url}', 'http://127.0.0.1:4455/office/workers/tell?worker=w1');
    expect(
      '${buildWorkersRequest('pr', office, {'pr': '12'}).url}',
      'http://127.0.0.1:4455/office/workers/pr?worker=w1',
    );
    expect('${buildWorkersRequest('hire', office, {}).url}', 'http://127.0.0.1:4455/office/workers?worker=w1');
  });

  test('lists workers and how sending them home went, a line each', () {
    final text = formatWorkers({
      'floor': {'name': 'app', 'repo': 'acme/app'},
      'leaveOnMerge': false,
      'freeDesk': 'desk-3',
      'workers': [
        {
          'id': 'w1',
          'name': 'Mochi',
          'you': true,
          'kind': 'agent',
          'provider': 'claude',
          'status': 'working',
          'desk': 'Desk 1',
          'task': 'Fixing login',
          'merged': false,
        },
        {
          'id': 'w2',
          'name': 'Bolt',
          'kind': 'agent',
          'provider': 'codex',
          'status': 'done',
          'desk': 'Desk 2',
          'worktree': {'branch': 'office/bolt-1'},
          'pr': {'number': 7, 'state': 'merged', 'title': 'Fix it'},
          'merged': true,
        },
        {
          'id': 'w3',
          'name': 'Zed',
          'kind': 'agent',
          'status': 'idle',
          'desk': 'Desk 3',
          'pr': {'number': 8, 'state': 'merged'},
          'merged': true,
          'staying': 'Ada has its terminal open',
        },
      ],
    });
    expect(text.split('\n')[0], '3 workers on app (acme/app) · go home once merged is off');
    expect(text, contains('\nw1  Mochi (you, claude) · working · Desk 1 · Fixing login\n'));
    expect(
      text,
      contains(
        '\nw2  Bolt (codex) · done · Desk 2 · branch office/bolt-1 · PR #7 merged “Fix it” · landed: free to go home\n',
      ),
    );
    expect(text, contains('landed, staying: Ada has its terminal open'));

    expect(formatHome({'results': []}, true), "Nobody's pull request has merged: nobody to send home.");
    expect(
      formatHome({
        'results': [
          {'worker': 'Zed', 'skipped': "PR #8 merged, but it's still working"},
          {'worker': 'Bolt', 'went': true, 'note': "Deleted Bolt's worktree and branch office/bolt-1"},
          {'worker': 'Nope', 'error': 'No worker here is called Nope'},
        ],
      }, false),
      "– Zed stayed: PR #8 merged, but it's still working\n✓ Bolt went home — Deleted Bolt's worktree and branch office/bolt-1\n✗ Nope: No worker here is called Nope",
    );
  });

  test('the command reads a prompt from stdin, reports refusals and exits non-zero on a failed send-home', () async {
    final calls = <WorkersRequest>[];
    Future<({int code, String out, String err})> run(List<String> argv, WorkersSend send, [String input = '']) async {
      final out = <String>[], err = <String>[];
      final code = await runWorkersCommand(
        argv,
        env: env,
        send: send,
        input: Stream.value(utf8.encode(input)),
        inputIsTerminal: false,
        out: out.add,
        err: err.add,
      );
      return (code: code, out: out.join('\n'), err: err.join('\n'));
    }

    final hired = await run(
      ['hire', '--model', 'haiku'],
      reply(200, {
        'ok': true,
        'worker': {
          'id': 'n1',
          'name': 'Nova',
          'desk': 'Desk 4',
          'worktree': {'branch': 'office/nova-1'},
        },
      }, calls),
      'Fix the flaky test\r\n',
    );
    expect(hired, (code: 0, out: 'n1', err: 'Hired Nova at Desk 4 on branch office/nova-1.'));
    expect(jsonDecode(calls[0].body!), {'model': 'haiku', 'prompt': 'Fix the flaky test'});

    final home = await run(
      ['home', 'Bolt', 'Nope'],
      reply(200, {
        'results': [
          {'worker': 'Bolt', 'went': true},
          {'worker': 'Nope', 'error': 'No worker here is called Nope'},
        ],
      }, calls),
    );
    expect(home.code, 1);
    expect(jsonDecode(calls[1].body!), {
      'workers': ['Bolt', 'Nope'],
    });

    final linked = await run(
      ['pr', '#7', '--worker', 'Bolt'],
      reply(200, {
        'ok': true,
        'worker': {
          'id': 'w2',
          'name': 'Bolt',
          'pr': {'number': 7, 'state': 'merged', 'title': 'Fix it'},
          'merged': true,
        },
      }, calls),
    );
    expect(linked, (code: 0, out: 'Bolt: PR #7 merged “Fix it” · landed: free to go home', err: ''));
    expect(jsonDecode(calls[2].body!), {'pr': '#7', 'worker': 'Bolt'});
    expect('${calls[2].url}', endsWith('/office/workers/pr?worker=w1'));
    expect(
      formatLinked({
        'worker': {'name': 'Bolt'},
      }),
      'Bolt has no pull request now.',
    );
    // What the office says is what's shown: there's no such worker, or it's too old to know this call.
    expect(
      (await run(['pr', '7', '--worker', 'Nope'], reply(404, {'error': 'No worker here is called Nope'}))).err,
      'office-workers: No worker here is called Nope',
    );
    expect(
      (await run(['pr', '7'], reply(405, {'error': 'GET /office/workers, or POST'}))).err,
      contains('older Agent Office than this command'),
    );

    final refused = await run(['list'], reply(401, {'error': 'bad token'}));
    expect(refused.code, 1);
    expect(refused.err, contains("didn't accept this worker's token (401): bad token"));

    final errs = <String>[];
    final noEnv = await runWorkersCommand(['list'], env: const {}, err: errs.add, out: (_) {});
    expect(noEnv, 1);
    expect(errs.join(), contains("AGENT_OFFICE_HOOK_URL, AGENT_OFFICE_WORKER_ID, AGENT_OFFICE_HOOK_TOKEN aren't set"));
  });

  test('answers MCP: the handshake, its tools, and a call', () async {
    final WorkersIo io = (
      env: env,
      send: reply(200, {
        'results': [
          {'worker': 'Bolt', 'went': true, 'note': 'Deleted it'},
        ],
      }),
    );
    Map res(Map<String, Object?>? r) => r!['result'] as Map;
    final init = await handleMcp({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 't', 'version': '1'},
      },
    }, io);
    expect(res(init)['protocolVersion'], '2025-06-18');
    expect(res(init)['capabilities'], {
      'tools': {'listChanged': false},
    });
    final old = await handleMcp({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'initialize',
      'params': {'protocolVersion': '1999-01-01'},
    }, io);
    expect(res(old)['protocolVersion'], '2025-11-25');
    expect(await handleMcp({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, io), isNull);
    final tools = await handleMcp({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}, io);
    expect(
      [for (final t in res(tools)['tools'] as List) t['name']],
      ['list_workers', 'hire_worker', 'send_home', 'tell_worker', 'link_pr'],
    );
    final WorkersIo linking = (
      env: env,
      send: (req) async => (
        status: 200,
        body: {
          'ok': true,
          'worker': {
            'name': 'Bolt',
            'pr': {'number': (jsonDecode(req.body!) as Map)['pr'], 'state': 'open'},
            'merged': false,
          },
        },
      ),
    );
    final linked = await handleMcp({
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'tools/call',
      'params': {
        'name': 'link_pr',
        'arguments': {'worker': 'Bolt', 'pr': 7},
      },
    }, linking);
    expect(res(linked), {
      'content': [
        {'type': 'text', 'text': 'Bolt: PR #7 open'},
      ],
    });
    final call = await handleMcp({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {
        'name': 'send_home',
        'arguments': {'merged': true},
      },
    }, io);
    expect(res(call), {
      'content': [
        {'type': 'text', 'text': '✓ Bolt went home — Deleted it'},
      ],
    });
    // Nobody it named went: the call failed, as far as the model is concerned.
    final WorkersIo nobody = (
      env: env,
      send: reply(200, {
        'results': [
          {'worker': 'Zed', 'error': 'No worker here is called Zed'},
        ],
      }),
    );
    final missed = await handleMcp({
      'jsonrpc': '2.0',
      'id': 8,
      'method': 'tools/call',
      'params': {
        'name': 'send_home',
        'arguments': {
          'workers': ['Zed'],
        },
      },
    }, nobody);
    expect(res(missed)['isError'], isTrue);
    // A failed call is the tool's error, for the model to read; an unknown tool or method is the protocol's.
    final failed = await handleMcp(
      {
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {'name': 'list_workers'},
      },
      (env: const <String, String>{}, send: io.send),
    );
    expect(res(failed)['isError'], isTrue);
    expect(((res(failed)['content'] as List).first as Map)['text'], contains('only works inside Agent Office'));
    final unknown = await handleMcp({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'tools/call',
      'params': {'name': 'fire_everyone'},
    }, io);
    expect((unknown!['error'] as Map)['code'], -32602);
    final method = await handleMcp({'jsonrpc': '2.0', 'id': 7, 'method': 'resources/list'}, io);
    expect((method!['error'] as Map)['code'], -32601);
    for (final t in mcpTools) {
      expect((t['inputSchema'] as Map)['type'], 'object', reason: '${t['name']}');
    }
  });

  test('office-workers mcp serves a client over stdio, as the worker, through the real HTTP client', () async {
    final seen = <({String url, String? auth, String body})>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add((url: '${req.uri}', auth: req.headers.value('authorization'), body: body));
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'floor': {'name': 'app'},
          'you': 'w1',
          'workers': [
            {'id': 'w2', 'name': 'Bolt', 'merged': true},
          ],
        }),
      );
      await req.response.close();
    });
    final input = StreamController<List<int>>();
    final replies = StreamController<String>();
    final lines = StreamIterator(replies.stream);
    final done = runWorkersCommand(
      ['mcp'],
      env: {
        'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:${server.port}',
        'AGENT_OFFICE_WORKER_ID': 'w1',
        'AGENT_OFFICE_HOOK_TOKEN': 'sekrit',
      },
      input: input.stream,
      out: replies.add,
      err: (_) {},
    );
    Future<Map> ask(Map msg) async {
      input.add(utf8.encode('${jsonEncode(msg)}\n'));
      expect(await lines.moveNext(), isTrue);
      return jsonDecode(lines.current) as Map;
    }

    final init = await ask({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-11-25'},
    });
    expect(((init['result'] as Map)['serverInfo'] as Map)['name'], 'agent-office');
    input.add(utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n'));
    final listed = await ask({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': 'list_workers', 'arguments': <String, Object?>{}},
    });
    final text = (((listed['result'] as Map)['content'] as List).first as Map)['text'] as String;
    expect(((jsonDecode(text) as Map)['workers'] as List).first['name'], 'Bolt');
    expect(seen, [(url: '/office/workers?worker=w1', auth: 'Bearer sekrit', body: '')]);
    expect((await ask({'jsonrpc': '2.0', 'id': 3, 'method': 'ping'}))['result'], isNotNull);
    await input.close();
    expect(await done, 0);
  });

  test("a worker's row says where its pull request stands, and whether it would go home by itself", () {
    final head = 'a' * 40;
    final view = viewOf([pull(7, 'MERGED', 'office/bolt', head), pull(8, 'OPEN', 'office/zed')]);
    final bolt = workerRow(
      worker('bolt', {
        'task': {'name': 'Login fix', 'summary': 'Fixed the redirect'},
      }),
      view,
      'mochi',
    );
    expect(bolt, {
      'id': 'bolt',
      'name': 'Bolt',
      'kind': 'agent',
      'desk': deskById['desk-1']!.label,
      'status': 'done',
      'task': 'Login fix: Fixed the redirect',
      'hiredBy': 'Ada',
      'hiredAt': '1970-01-01T00:00:00.000Z',
      'worktree': {'path': '.agent-office/worktrees/bolt', 'branch': 'office/bolt'},
      'pr': {'number': 7, 'state': 'merged', 'title': 'PR 7', 'url': 'https://github.com/acme/app/pull/7'},
      'merged': true,
    });
    expect(workerRow(worker('zed'), view)['merged'], false);
    expect((workerRow(worker('zed'), view)['pr'] as Map)['state'], 'open');
    final watched = workerRow(worker('bolt', {'status': 'working'}), view);
    expect(watched['staying'], 'still working');
    expect(workerRow(worker('mochi'), view, 'mochi')['you'], true);
    expect(workerRow(worker('pat', {'deskId': 'station-pulls'}), view)['board'], 'PR agent');
    expect(
      notLeaving(
        worker('bolt', {
          'viewers': ['Ada', 'Grace'],
        }),
      ),
      'Ada, Grace have its terminal open',
    );
    expect(notLeaving(worker('bolt')), isNull);
    // Its folder was deleted outside the office.
    final lost = workerRow(
      worker('rex', {
        'lost': {'branch': 'here'},
      }),
      view,
    );
    expect((lost['worktree'] as Map)['deleted'], true);
  });

  test('a worker in the main checkout has the pull request it opened itself', () {
    final view = viewOf([pull(7, 'MERGED', 'fix-login', 'a' * 40), pull(8, 'OPEN', 'fix-logout')]);
    Map<String, Object?> pixel([Map<String, Object?> more = const {}]) => {
      ...worker('pixel').toJson()..remove('worktree'),
      ...more,
    };
    // Its branch is one the office never made: with nothing saying whose #7 is, it has no pull request.
    expect(workerRow(WorkerInfo.fromJson(pixel()), view)['pr'], isNull);
    expect(workerRow(WorkerInfo.fromJson(pixel()), view)['merged'], false);
    final mine = workerRow(
      WorkerInfo.fromJson(
        pixel({
          'pr': {'number': 7, 'url': 'https://github.com/acme/app/pull/7'},
        }),
      ),
      view,
    );
    expect(mine['pr'], {'number': 7, 'state': 'merged', 'title': 'PR 7', 'url': 'https://github.com/acme/app/pull/7'});
    expect(mine['merged'], true);
    final eight = workerRow(
      WorkerInfo.fromJson(
        pixel({
          'pr': {'number': 8, 'url': 'https://github.com/acme/app/pull/8'},
        }),
      ),
      view,
    );
    expect((eight['pr'] as Map)['state'], 'open');
    // One it opened earlier is still open: the later one merging isn't all its work landing.
    final both = workerRow(
      WorkerInfo.fromJson(
        pixel({
          'pr': {'number': 7, 'url': 'https://github.com/acme/app/pull/7'},
          'pastPrs': [8],
        }),
      ),
      view,
    );
    expect([(both['pr'] as Map)['number'], (both['pr'] as Map)['state'], both['merged']], [8, 'open', false]);

    // What `gh pr create` printed, alone or at the end of a longer line; the one its branch already had counts too.
    const url = 'https://github.com/acme/app/pull/12';
    expect(ownPr('gh pr create --title "Fix it" --body "Closes #4"', '$url\n'), (
      repo: 'acme/app',
      number: 12,
      url: url,
    ));
    expect(
      ownPr(
        'cd ../wt && git push -u origin fix-it 2>&1 | tail -1; gh pr create --fill',
        'remote: https://github.com/acme/app/pull/new/fix-it\n$url',
      ),
      (repo: 'acme/app', number: 12, url: url),
    );
    expect(
      ownPr(
        'gh  pr  create --fill',
        'a pull request for branch "fix-it" into branch "main" already exists:\n$url',
      )?.number,
      12,
    );
    // Not opening one: looking at one, naming the command, or nothing printed.
    expect(ownPr('gh pr view 12 --json url', url), isNull);
    expect(ownPr('grep -rn "gh pr create" docs', 'docs/a.md: gh pr create … $url'), isNull);
    expect(
      ownPr('gh pr create --fill', 'pull request create failed: GraphQL: No commits between main and fix-it'),
      isNull,
    );
    expect(ownPr(null, url), isNull);
  });

  test('reads a request to say which pull request is whose', () {
    PrRequest? ok(Object? body) => readPrRequest(body).ask;
    String? why(Object? body) => readPrRequest(body).error;
    expect(ok({'pr': 12}), (worker: null, pr: 12, repo: null));
    expect(ok({'pr': ' #12 ', 'worker': ' Bolt '}), (worker: 'Bolt', pr: 12, repo: null));
    expect(ok({'pr': 'https://github.com/acme/app/pull/12/files', 'worker': 'Bolt'}), (
      worker: 'Bolt',
      pr: 12,
      repo: 'acme/app',
    ));
    expect(ok({'unlink': true, 'worker': 'Bolt'}), (worker: 'Bolt', pr: null, repo: null));
    expect(ok({'unlink': true}), (worker: null, pr: null, repo: null));
    expect(why({}), contains('Say which pull request'));
    expect(why({'pr': 0}), contains('Say which pull request'));
    expect(why({'pr': 'https://github.com/acme/app/issues/12'}), contains('Say which pull request'));
    expect(why({'pr': 12, 'unlink': true}), contains('not both'));
    expect(why({'pr': 12, 'worker': 7}), contains('worker is a worker name or id'));
  });

  test('finds a worker by id or name, and says who there is when it cannot', () {
    final list = [
      worker('bolt'),
      worker('mochi', {'name': 'Mochi 🐚', 'kind': 'shell'}),
      worker('x1', {'name': 'Twin'}),
      worker('x2', {'name': 'Twin'}),
    ];
    expect(findWorker(list, 'bolt').worker?.id, 'bolt');
    expect(findWorker(list, ' BOLT ').worker?.id, 'bolt');
    expect(findWorker(list, 'mochi').worker?.id, 'mochi');
    expect(findWorker(list, 'Twin').error, contains('More than one worker is called Twin: use an id (x1, x2)'));
    expect(
      findWorker(list, 'Nope').error,
      contains("No worker here is called Nope (there's Bolt, Mochi 🐚, Twin, Twin)"),
    );
    expect(findWorker([], 'Nope').error, contains('nobody is at a desk'));
  });

  test('reads send-home and hire requests', () {
    (List<String>, bool, WorktreeCleanup?) home(Object? body) {
      final a = readHomeRequest(body).ask!;
      return (a.workers, a.merged, a.cleanup);
    }

    final some = home({
      'workers': ['Bolt', ' Bolt ', 'Zed'],
    });
    expect(
      [some.$1, some.$2, some.$3],
      [
        ['Bolt', 'Zed'],
        false,
        null,
      ],
    );
    final one = home({'worker': 'Bolt', 'cleanup': 'auto'});
    expect(
      [one.$1, one.$2, one.$3],
      [
        ['Bolt'],
        false,
        null,
      ],
    );
    final merged = home({'merged': true, 'cleanup': 'worktree'});
    expect([merged.$1, merged.$2, merged.$3], [<String>[], true, WorktreeCleanup.worktree]);
    expect(readHomeRequest({}).error, contains('Say who'));
    expect(
      readHomeRequest({
        'workers': ['a'],
        'merged': true,
      }).error,
      contains('not both'),
    );
    expect(readHomeRequest({'workers': 'Bolt'}).error, contains('list'));
    expect(readHomeRequest({'merged': true, 'cleanup': 'nuke'}).error, contains('cleanup is one of'));

    const providers = [AgentProvider.claude, AgentProvider.codex];
    expect(
      readHireRequest({
        'prompt': ' Fix it\r\n',
        'provider': 'codex',
        'effort': 'high',
        'worktree': false,
        'desk': 'desk-3',
        'issue': 4,
      }, providers).ask,
      (
        prompt: 'Fix it',
        provider: AgentProvider.codex,
        model: null,
        effort: AgentEffort.high,
        worktree: false,
        desk: 'desk-3',
        issue: 4,
      ),
    );
    expect(readHireRequest({}, providers).error, contains('prompt'));
    expect(
      readHireRequest({'prompt': 'x', 'provider': 'grok'}, providers).error,
      contains('provider is one of claude, codex'),
    );
    expect(readHireRequest({'prompt': 'x', 'desk': 'station-queue'}, providers).error, contains('desk'));
    expect(readHireRequest({'prompt': 'x', 'issue': 0}, providers).error, contains('issue'));
  });

  test("Codex is told to pass the office's variables on to the MCP server", () {
    final args = codexMcpArgs(['/opt/app/agent-office', 'workers', 'mcp']);
    expect([for (var i = 0; i < args.length; i += 2) args[i]], ['-c', '-c', '-c']);
    expect(
      [for (var i = 1; i < args.length; i += 2) args[i]],
      [
        'mcp_servers.agent-office.command="/opt/app/agent-office"',
        'mcp_servers.agent-office.args=["workers","mcp"]',
        'mcp_servers.agent-office.env_vars=["AGENT_OFFICE_HOOK_URL","AGENT_OFFICE_WORKER_ID","AGENT_OFFICE_HOOK_TOKEN"]',
      ],
    );
  });
}
