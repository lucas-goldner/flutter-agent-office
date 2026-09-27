@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/headless.dart';
import 'package:agent_office_server/src/ptys.dart';
import 'package:test/test.dart';

/// A terminal's output so far, and a way to wait for something to show up in it.
class Output {
  Output(Pty pty) {
    pty.onData(text.write);
    pty.onExit(exited.complete);
  }

  final text = StringBuffer();
  final exited = Completer<PtyExit>();

  Future<void> waitFor(Pattern pattern, {Duration timeout = const Duration(seconds: 15)}) async {
    final end = DateTime.now().add(timeout);
    while (!text.toString().contains(pattern)) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $pattern in: $text');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Running, and not just a zombie waiting for its new parent (init, in a container slow) to reap it.
Future<bool> alive(int pid) async {
  final stat = ((await Process.run('ps', ['-o', 'stat=', '-p', '$pid'])).stdout as String).trim();
  return stat.isNotEmpty && !stat.startsWith('Z');
}

Future<int> parentOf(int pid) async =>
    int.parse(((await Process.run('ps', ['-o', 'ppid=', '-p', '$pid'])).stdout as String).trim());

SpawnOpts bash(String cwd, {String? prelude}) => SpawnOpts(
  file: '/bin/bash',
  args: ['--norc', '--noprofile', '-i'],
  cwd: cwd,
  env: {
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'HOME': cwd,
    'PS1': 'PROMPT> ',
    'AGENT_OFFICE_WORKER_ID': 'w1',
  },
  cols: 80,
  rows: 24,
  prelude: prelude,
);

void main() {
  late String dataDir;
  final hosts = <PtyHost>[];

  PtyHost newHost({void Function()? onLost}) {
    final host = PtyHost(dataDir, onLost ?? () {});
    hosts.add(host);
    return host;
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('agent-office-ptys-').resolveSymbolicLinksSync();
  });

  tearDown(() async {
    for (final h in hosts) {
      await h.stop();
    }
    hosts.clear();
    // Whatever a failed test left running: tell a host still listening to stop, and everything in it.
    final paths = hostPaths(dataDir);
    try {
      final token = (jsonDecode(File(paths.infoPath).readAsStringSync()) as Map)['token'];
      final sock = await Socket.connect(InternetAddress(paths.socketPath, type: InternetAddressType.unix), 0);
      sock.write(frame({'t': 'hello', 'token': token}));
      sock.write(frame({'t': 'stop'}));
      await sock.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      sock.destroy();
    } catch (_) {
      // none left
    }
    Directory(dataDir).deleteSync(recursive: true);
  });

  test('a terminal in the host outlives the office: spawn, type, resize, detach, re-attach, exit', () async {
    final office = newHost();
    expect(await office.connect(), isTrue);
    expect(office.hosted, isTrue);
    expect(File(office.infoPath).statSync().modeString(), 'rw-------');

    final pty = office.spawn(bash(dataDir, prelude: 'RESTORED LINE\r\n'));
    expect(pty.id, isNotNull);
    final out = Output(pty);
    await out.waitFor('PROMPT> ');
    await until(() => pty.pid > 0);
    expect(await parentOf(pty.pid), isNot(pid), reason: 'the host, not this process, owns it');

    pty.write(
      r'echo "hello $AGENT_OFFICE_WORKER_ID from $TERM"'
      '\r',
    );
    await out.waitFor('hello w1 from xterm-256color');
    pty.resize(100, 30);
    pty.write('stty size\r');
    await out.waitFor('30 100');
    pty.write(
      r"printf '\e]0;my title\a\e]9;4;3;\a\e[32mgreen\e[0m\n'"
      '\r',
    );
    await out.waitFor('green');

    // The office restarts: the terminal keeps running in the host.
    final id = pty.id!;
    final pid0 = pty.pid;
    await office.detach();
    expect(await alive(pid0), isTrue);

    final next = newHost();
    expect(await next.connect(), isTrue);
    final adopted = await next.attach(id);
    expect(adopted, isNotNull);
    expect(adopted!.pty.pid, pid0);
    expect((adopted.cols, adopted.rows), (100, 30));
    expect(adopted.title, 'my title');
    expect(adopted.busy, isTrue);
    expect(adopted.snapshot, contains('\x1b[0;32mgreen'));
    // The snapshot replays into a terminal the size the host has.
    final screen = HeadlessTerminal(cols: adopted.cols, rows: adopted.rows)..write(adopted.snapshot);
    final text = [for (var y = 0; y < screen.normal.length; y++) screen.normal.getLine(y)!.translateToString(true)];
    expect(text, contains('RESTORED LINE'));
    expect(text, contains('hello w1 from xterm-256color'));
    final cursor = screen.active.buffer;
    // (A default-styled space at the end of a row is left out, like an empty cell.)
    expect(text[cursor.absoluteCursorY], 'PROMPT>', reason: 'the cursor is back on the prompt');
    expect(cursor.cursorX, 'PROMPT> '.length);
    expect(await next.attach(id), isNull, reason: 'a session is claimed once');

    final again = Output(adopted.pty);
    adopted.pty.write('echo again\r');
    await again.waitFor('again\r\n');

    // Ctrl+C reaches the foreground job, as in a real terminal.
    adopted.pty.write('sleep 30; echo SLEPT\r');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    adopted.pty.write('\x03');
    await again.waitFor(RegExp(r'\^C\r\n.*PROMPT> $'));
    expect(again.text.toString(), isNot(contains('\nSLEPT')));

    adopted.pty.write('exit 7\r');
    final exit = await again.exited.future.timeout(const Duration(seconds: 10));
    expect(exit.exitCode, 7);
    expect(exit.lost, isFalse);
    expect(await alive(pid0), isFalse);
  });

  test('sessions nobody claims are ended; a failed spawn says why', () async {
    final office = newHost();
    expect(await office.connect(), isTrue);
    final a = office.spawn(bash(dataDir));
    final b = office.spawn(bash(dataDir));
    await until(() => a.pid > 0 && b.pid > 0);
    final bad = office.spawn(bash(dataDir).withFile('/no/such/program'));
    final badOut = Output(bad);
    final e = await badOut.exited.future.timeout(const Duration(seconds: 10));
    expect(e.exitCode, -1);
    expect(e.error, contains('No such file'));
    await office.detach();

    final next = newHost();
    expect(await next.connect(), isTrue);
    expect(await next.attach(a.id!), isNotNull);
    next.killUnclaimed();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await alive(b.pid), isFalse);
    expect(await alive(a.pid), isTrue);
  });

  test('when the host dies, the office hears it and its terminals end as lost', () async {
    var lost = 0;
    final office = newHost(onLost: () => lost++);
    expect(await office.connect(), isTrue);
    final pty = office.spawn(bash(dataDir));
    final out = Output(pty);
    await until(() => pty.pid > 0);
    final hostPid = await parentOf(pty.pid);
    Process.killPid(hostPid, ProcessSignal.sigkill);
    final e = await out.exited.future.timeout(const Duration(seconds: 10));
    expect(e.lost, isTrue);
    expect(lost, 1);
    expect(office.hosted, isFalse);
    // Its terminals hang up with it.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await alive(pty.pid), isFalse);
    // From here on terminals run in-process.
    final local = office.spawn(bash(dataDir));
    expect(local.id, isNull);
    final localOut = Output(local);
    expect(await parentOf(local.pid), pid);
    await localOut.waitFor('PROMPT> ');
    local.kill();
    await localOut.exited.future.timeout(const Duration(seconds: 10));
  });

  test('an office that finds a host from another build stops it and starts its own', () async {
    final paths = hostPaths(dataDir);
    File(paths.infoPath).writeAsStringSync(jsonEncode({'token': 'old-token'}));
    // A stand-in for a Node host: protocol 1, stops when told to.
    final old = await ServerSocket.bind(InternetAddress(paths.socketPath, type: InternetAddressType.unix), 0);
    final heard = <String>[];
    old.listen((sock) {
      readMessages(sock, (msg) {
        heard.add(msg['t'] as String);
        if (msg['t'] == 'hello' && msg['token'] == 'old-token') {
          sock.write(
            frame({
              't': 'ready',
              'version': 1,
              'sessions': ['old-session'],
            }),
          );
        }
        if (msg['t'] == 'stop') {
          old.close();
          sock.destroy();
        }
      });
    });

    final office = newHost();
    expect(await office.connect(), isTrue);
    expect(heard, ['hello', 'stop']);
    expect(await office.attach('old-session'), isNull, reason: "the new host doesn't have the old one's sessions");
    final token = (jsonDecode(File(paths.infoPath).readAsStringSync()) as Map)['token'];
    expect(token, isNot('old-token'));
    final pty = office.spawn(bash(dataDir));
    await Output(pty).waitFor('PROMPT> ');
  });

  test('closing for good ends every terminal and the host', () async {
    final office = newHost();
    expect(await office.connect(), isTrue);
    final pty = office.spawn(bash(dataDir));
    final out = Output(pty);
    await out.waitFor('PROMPT> ');
    final hostPid = await parentOf(pty.pid);
    await office.stop();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await alive(pty.pid), isFalse);
    expect(await alive(hostPid), isFalse);
  });
}

extension on SpawnOpts {
  SpawnOpts withFile(String file) =>
      SpawnOpts(file: file, args: args, cwd: cwd, env: env, cols: cols, rows: rows, prelude: prelude);
}
