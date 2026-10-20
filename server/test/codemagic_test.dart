import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/codemagic.dart';
import 'package:agent_office_server/src/codemagic_cmd.dart';
import 'package:agent_office_server/src/queue_cmd.dart' show QueueRequest, QueueResponse;
import 'package:office_shared/codemagic.dart';
import 'package:test/test.dart';

/// A stand-in for Codemagic's API: one app with two workflows, and builds that finish when told.
class FakeCodemagic {
  late HttpServer _server;
  final calls = <(String, String, Object?)>[];
  final status = <String, String>{};
  var next = 0;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty ? null : jsonDecode(text);
      calls.add((req.method, req.uri.path, body));
      Object? out;
      var code = 200;
      final path = req.uri.path;
      if (req.headers.value('x-auth-token') != 'cm-token') {
        code = 401;
        out = {'status_code': 401, 'detail': 'Invalid token', 'errors': []};
      } else if (path == '/api/v3/user/teams') {
        out = {
          'data': [
            {'id': 'team01', 'name': 'Acme', 'icon_url': null},
          ],
          'page_size': 50,
          'current_page': 1,
          'total_pages': 1,
        };
      } else if (path == '/api/v3/teams/team01/apps') {
        out = {
          'data': [
            {'id': 'app000001', 'name': 'acme-app', 'archived': false},
          ],
          'page_size': 50,
          'current_page': 1,
          'total_pages': 1,
        };
      } else if (path == '/api/v3/user/apps') {
        out = {
          'data': [
            {'id': 'app000003', 'name': 'Pushup-Bro', 'icon_url': null, 'last_build_id': null, 'archived': false},
            {'id': 'app000002', 'name': 'old-app', 'icon_url': null, 'last_build_id': null, 'archived': true},
          ],
          'page_size': 50,
          'current_page': 1,
          'total_pages': 1,
        };
      } else if (path == '/api/v3/apps/app000001/workflows') {
        out = {
          'data': [
            {'id': 'ios-dev', 'source': 'yaml', 'name': 'iOS dev'},
            {'id': 'android-dev', 'source': 'yaml', 'name': 'Android dev'},
          ],
        };
      } else if (path == '/api/v3/apps/app000001/builds' && req.method == 'POST') {
        final id = 'build${(++next).toString().padLeft(4, '0')}';
        status[id] = 'queued';
        code = 202;
        out = {
          'data': {'id': id},
        };
      } else if (path.startsWith('/api/v3/builds/')) {
        final id = path.split('/').last;
        if (!status.containsKey(id)) {
          code = 404;
          out = {'status_code': 404, 'detail': 'Not found', 'errors': []};
        } else {
          out = {
            'data': {
              'id': id,
              'status': status[id],
              'index': 41 + next,
              'artifacts': status[id] == 'finished'
                  ? [
                      {
                        'name': 'Runner.ipa',
                        'type': 'ipa',
                        'size_in_bytes': 1234,
                        'short_lived_download_url': 'https://cm.example/dl/$id/Runner.ipa',
                        'version_code': null,
                        'version_name': null,
                      },
                    ]
                  : [],
            },
          };
        }
      } else {
        code = 404;
        out = {'status_code': 404, 'detail': 'No route', 'errors': []};
      }
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(out));
      await req.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late FakeCodemagic fake;
  late Directory dir;
  setUp(() async {
    fake = FakeCodemagic();
    await fake.start();
    dir = Directory.systemTemp.createTempSync('codemagic-');
  });
  tearDown(() async {
    await fake.close();
    dir.deleteSync(recursive: true);
  });

  test('a floor picks its app, starts a workflow by name on a branch, and follows it to the end', () async {
    final cm = FloorCodemagic(dir.path, CodemagicApi('cm-token', base: fake.base), now: () => 1000);
    expect(cm.state().token, isTrue);
    expect(
      [for (final a in await cm.api!.apps()) a.label],
      ['Acme · acme-app', 'Pushup-Bro'],
      reason: "the teams' apps first, then your own; archived ones left out",
    );
    expect(await cm.setApp('app000001'), isNull);
    expect(cm.state().appName, 'Acme · acme-app');
    expect([for (final w in cm.state().workflows) w.label], ['iOS dev', 'Android dev']);

    final b = await cm.start('ios dev', 'feature/qr-blank', by: 'Bolt', variables: {'QA': '1'});
    expect((b.id, b.workflow, b.branch, b.by), ('build0001', 'iOS dev', 'feature/qr-blank', 'Bolt'));
    expect(b.link, 'https://codemagic.io/app/app000001/build/build0001');
    expect(fake.calls.last.$3, {
      'workflow_id': 'ios-dev',
      'branch': 'feature/qr-blank',
      'environment': {
        'variables': {'QA': '1'},
      },
    });
    expect(cm.state().running.single.id, 'build0001');

    // Still going: nothing ended. Then it finishes.
    fake.status['build0001'] = 'building';
    var r = await cm.poll();
    expect(r.changed, isTrue);
    expect(r.ended, isEmpty);
    fake.status['build0001'] = 'finished';
    r = await cm.poll();
    expect(r.ended.single.status, CodemagicStatus.finished);
    expect(r.ended.single.artifacts.single.name, 'Runner.ipa');
    expect(cm.state().running, isEmpty);

    // Its status, with a download link; kept across a restart.
    final s = await cm.status('build0001');
    expect(s.downloads.single.url, 'https://cm.example/dl/build0001/Runner.ipa');
    final again = FloorCodemagic(dir.path, CodemagicApi('cm-token', base: fake.base));
    expect(again.state().builds.single.status, CodemagicStatus.finished);
    expect(again.state().appId, 'app000001');
  });

  test(
    "what goes wrong, in words: no token, no app, no such workflow, a bad branch, a token Codemagic won't take",
    () async {
      final none = FloorCodemagic(dir.path, null);
      expect(none.state().token, isFalse);
      await expectLater(
        none.start('iOS dev', 'main', by: 'x'),
        throwsA(isA<CodemagicError>().having((e) => e.message, 'm', contains('Codemagic app'))),
      );

      final cm = FloorCodemagic(dir.path, CodemagicApi('cm-token', base: fake.base));
      expect(await cm.setApp('app000001'), isNull);
      await expectLater(
        cm.start('web', 'main', by: 'x'),
        throwsA(isA<CodemagicError>().having((e) => e.message, 'm', contains('iOS dev, Android dev'))),
      );
      await expectLater(
        cm.start('iOS dev', '../etc', by: 'x'),
        throwsA(isA<CodemagicError>().having((e) => e.message, 'm', contains('branch'))),
      );

      final wrong = FloorCodemagic(dir.path, CodemagicApi('nope', base: fake.base));
      expect(await wrong.setApp('app000001'), contains('CODEMAGIC_TOKEN'));
    },
  );

  test('agent-office codemagic: start on this branch, follow it to the end with its download link', () async {
    final env = {
      'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:1',
      'AGENT_OFFICE_WORKER_ID': 'w1',
      'AGENT_OFFICE_HOOK_TOKEN': 't',
    };
    final sent = <QueueRequest>[];
    final states = ['building', 'finished'];
    Future<QueueResponse> send(QueueRequest r) async {
      sent.add(r);
      if (r.method == 'POST') {
        return (
          status: 200,
          body: {
            'build': {
              'id': 'b1',
              'workflow': 'iOS dev',
              'branch': 'feature/x',
              'status': 'queued',
              'link': 'https://codemagic.io/app/a/build/b1',
            },
          },
        );
      }
      final s = states.removeAt(0);
      return (
        status: 200,
        body: {
          'build': {
            'id': 'b1',
            'workflow': 'iOS dev',
            'branch': 'feature/x',
            'status': s,
            'index': 42,
            'link': 'https://codemagic.io/app/a/build/b1',
          },
          if (s == 'finished')
            'downloads': [
              {'name': 'Runner.ipa', 'url': 'https://dl/Runner.ipa'},
            ],
        },
      );
    }

    final out = <String>[];
    final code = await runCodemagicCommand(
      ['build', 'iOS dev', '--wait'],
      env: env,
      send: send,
      currentBranch: () => 'feature/x',
      pollEvery: Duration.zero,
      out: out.add,
    );
    expect(code, 0);
    expect(jsonDecode(sent.first.body!), {'workflow': 'iOS dev', 'branch': 'feature/x'});
    expect(sent.last.url.queryParameters, {'worker': 'w1', 'build': 'b1'});
    expect(out.last, contains('📦 Runner.ipa: https://dl/Runner.ipa'));
    expect(out.last, startsWith('🟢 iOS dev #42 on feature/x: finished'));

    expect(await runCodemagicCommand(['build'], env: env, send: send, err: (_) {}), 2);
    expect(parseCodemagicArgs(['status', '#42']), isA<CodemagicStatusCmd>().having((c) => c.build, 'build', '42'));
  });
}
