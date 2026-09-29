import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/config.dart';
import 'package:agent_office_server/src/secrets.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('ao-config-'));
  tearDown(() => home.deleteSync(recursive: true));

  Map<String, dynamic> stored() =>
      jsonDecode(File(p.join(home.path, '.agent-office', 'config.json')).readAsStringSync()) as Map<String, dynamic>;

  test('flags', () {
    final cfg = loadConfig([
      '--home', home.path, '-p', '4700', '-H', '127.0.0.1', '--password', 'hunter22', //
      '--agent-args', '-m "big one"', '--turn', 'turn:us%40r:p%3Ass@turn.example.com:3478',
      '--budget', r'$20', '--budget-pause', '--weather', ' Snow ', '--city', ' Berlin ', '--trust-proxy',
    ]);
    expect(cfg.dir, home.path);
    expect(cfg.projectsDir, home.path);
    expect(cfg.project, isNull);
    expect(cfg.port, 4700);
    expect(cfg.host, '127.0.0.1');
    expect(cfg.password, 'hunter22');
    expect(cfg.passwordGenerated, isFalse);
    expect(toHex(cfg.verifier), toHex(scryptSync('hunter22', cfg.salt)));
    expect(cfg.agentArgs, ['-m', 'big one']);
    expect(cfg.iceServers.last.toJson(), {
      'urls': 'turn:turn.example.com:3478',
      'username': 'us@r',
      'credential': 'p:ss',
    });
    expect(cfg.iceServers.first.toJson()['urls'], ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302']);
    expect(cfg.budget, 20);
    expect(cfg.budgetPause, isTrue);
    expect(cfg.weather, Weather.snow);
    expect(cfg.city, 'Berlin');
    expect(cfg.trustProxy, isTrue);
    expect(cfg.tls, isNull);
    // A password given on the command line is never stored.
    expect(stored().keys.toSet(), {'secret', 'salt'});
  });

  test('a generated password is kept until claimed, then only its hash', () {
    final cfg = loadConfig(['--home', home.path]);
    expect(cfg.passwordGenerated, isTrue);
    final pw = cfg.password!;
    expect(pw, hasLength(12));
    expect(stored()['verifier'], toHex(scryptSync(pw, cfg.salt)));
    expect(stored()['password'], pw);
    expect(loadConfig(['--home', home.path]).password, pw);
    cfg.markClaimed();
    expect(cfg.claimed, isTrue);
    expect(cfg.password, isNull);
    expect(stored().containsKey('password'), isFalse);
    final again = loadConfig(['--home', home.path]);
    expect(again.claimed, isTrue);
    expect(again.password, isNull);
    expect(toHex(again.verifier), toHex(cfg.verifier));
    expect(() => loadConfig(['--home', home.path, '--reset-password']), throwsA(isA<ConfigExit>()));
    expect(stored().keys.toSet(), {'secret', 'salt'});
  });

  test('bad flags exit 2, --help exits 0', () {
    int code(List<String> args) {
      try {
        loadConfig(['--home', home.path, ...args]);
        return -1;
      } on ConfigExit catch (e) {
        return e.code;
      }
    }

    expect(code(['--help']), 0);
    expect(code(['--nope']), 2);
    expect(code(['--port']), 2);
    expect(code(['--port', '--host']), 2);
    expect(code(['--port', 'abc']), 2);
    expect(code(['--port', '70000']), 2);
    expect(code(['--budget', '0']), 2);
    expect(code(['--weather', 'hail']), 2);
    expect(code(['--tls-cert', 'x.pem']), 2);
    expect(code([p.join(home.path, 'missing')]), 2);
  });

  test('--self-signed makes a certificate once', () async {
    if (Process.runSync('which', ['openssl']).exitCode != 0) return;
    final cfg = loadConfig(['--home', home.path, '--self-signed']);
    await ensureSelfSigned(cfg);
    expect(cfg.tls!.cert, startsWith('-----BEGIN CERTIFICATE-----'));
    expect(cfg.tls!.key, contains('PRIVATE KEY'));
    final again = loadConfig(['--home', home.path, '--self-signed']);
    await ensureSelfSigned(again);
    expect(again.tls!.cert, cfg.tls!.cert);
    // Dart's TLS stack takes it.
    SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cfg.tls!.cert))
      ..usePrivateKeyBytes(utf8.encode(cfg.tls!.key));
  });

  // Port of tests/config.test.ts (#88) and --max-workers (#92).
  int exitCode(List<String> args) {
    try {
      loadConfig(['--home', home.path, '--password', 'x', ...args]);
      return -1;
    } on ConfigExit catch (e) {
      return e.code;
    }
  }

  test('--agent-args takes flags as its value, as the help shows', () {
    expect(loadConfig(['--home', home.path, '--password', 'x', '--agent-args', '--model opus']).agentArgs, [
      '--model',
      'opus',
    ]);
    // ...and the flag after it is parsed as a flag again.
    expect(
      loadConfig(['--home', home.path, '--password', 'x', '--agent-args', '--model opus', '--port', '4999']).port,
      4999,
    );
  });

  test('--agent-args with nothing after it still needs a value; other flags treat a leading -- as missing', () {
    expect(exitCode(['--agent-args']), 2);
    expect(exitCode(['--agent', '--agent-args', 'x']), 2);
  });

  test('--max-workers is a whole number from 1 to 500', () {
    expect(loadConfig(['--home', home.path, '--password', 'x']).maxWorkers, isNull);
    expect(loadConfig(['--home', home.path, '--password', 'x', '--max-workers', '6']).maxWorkers, 6);
    for (final bad in ['0', '2.5', 'six', '501']) {
      expect(exitCode(['--max-workers', bad]), 2, reason: bad);
    }
  });

  test('splitArgs', () {
    expect(splitArgs(''), isEmpty);
    expect(splitArgs(''' a 'b c' "d e" f'''), ['a', 'b c', 'd e', 'f']);
  });

  test('the office listens on loopback unless --host says otherwise', () {
    expect(loadConfig(['--home', home.path, '--password', 'hunter22']).host, '127.0.0.1');
    expect(loadConfig(['--home', home.path, '--password', 'hunter22', '--host', '0.0.0.0']).host, '0.0.0.0');
  });

  test('--no-open leaves the browser alone', () {
    expect(loadConfig(['--home', home.path, '--password', 'hunter22']).open, isTrue);
    expect(loadConfig(['--home', home.path, '--password', 'hunter22', '--no-open']).open, isFalse);
  });

  test('--projects picks the projects folder, the default stays where it was', () {
    final cfg = loadConfig(['--home', home.path, '--password', 'hunter22', '--projects', p.join(home.path, 'ws')]);
    expect(cfg.projects, p.join(home.path, 'ws'));
    expect(cfg.projectsDir, home.path);
  });
}
