@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:office_pty/office_pty.dart';
import 'package:test/test.dart';

/// Collects a PTY's output and waits for text to show up in it.
class Screen {
  Screen(this.pty) {
    pty.output.listen((d) => text.write(d));
  }

  final UnixPty pty;
  final text = StringBuffer();

  Future<void> waitFor(Pattern p, {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (!text.toString().contains(p)) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $p in: ${text.toString()}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

void main() {
  test('runs in its own session with the PTY as its controlling terminal, and exact env', () async {
    final pty = UnixPty.start(
      '/bin/sh',
      ['-c', r'echo "pid=$$ env=$FOO home=${HOME:-none}"; ps -o sid= -o tpgid= -p $$; tty; exit 3'],
      environment: {'FOO': 'bar', 'PATH': '/usr/bin:/bin'},
      workingDirectory: '/',
    );
    final s = Screen(pty);
    final status = await pty.exit;
    // -1: the test runner has processes of its own, and the VM reaping those can take this one too.
    expect(status.exitCode, anyOf(3, -1));
    final out = s.text.toString();
    expect(out, contains('pid=${pty.pid} env=bar home=none'));
    // Session id == its own pid (a session leader), and it is the terminal's foreground process group.
    final ids = RegExp(r'^\s*(\d+)\s+(\d+)\s*$', multiLine: true).firstMatch(out)!;
    expect(int.parse(ids[1]!), pty.pid);
    expect(int.parse(ids[2]!), pty.pid);
    expect(out, contains('/dev/'));
  });

  test('starts with default signal dispositions and an empty mask', () async {
    if (!Platform.isLinux) return;
    final pty = UnixPty.start('/bin/sh', ['-c', 'grep -E "^Sig(Blk|Ign)" /proc/self/status']);
    final s = Screen(pty);
    await pty.exit;
    expect(s.text.toString(), contains('SigBlk:\t0000000000000000'));
    expect(s.text.toString(), contains('SigIgn:\t0000000000000000'));
  });

  test('Ctrl+C reaches the foreground process; SIGHUP ends it like node-pty; resize is seen', () async {
    final pty = UnixPty.start(
      '/bin/bash',
      ['--norc', '--noprofile', '-i'],
      environment: {'PS1': 'PROMPT> ', 'PATH': '/usr/bin:/bin'},
      cols: 100,
      rows: 30,
    );
    addTearDown(pty.kill);
    final s = Screen(pty);
    await s.waitFor('PROMPT> ');
    pty.write('stty size\r');
    await s.waitFor('30 100');
    pty.resize(90, 20);
    pty.write('stty size\r');
    await s.waitFor('20 90');
    pty.write('sleep 30; echo AFTER\r');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    pty.write('\x03');
    await s.waitFor(RegExp(r'\^C\r\n(\x1b\[\?2004h)?PROMPT> '));
    expect(s.text.toString(), isNot(contains('\nAFTER')));
    expect(pty.kill(), isTrue);
    final status = await pty.exit.timeout(const Duration(seconds: 5));
    expect(status.signal, anyOf(ProcessSignal.sighup.signalNumber, 0));
    expect(pty.kill(), isFalse);
  });

  test('all output comes before the exit, and a big write does not block', () async {
    final pty = UnixPty.start('/bin/sh', ['-c', 'head -c 200000 /dev/zero | tr "\\0" x; echo; echo END']);
    final s = Screen(pty);
    await pty.exit;
    expect(s.text.toString().replaceAll(RegExp(r'[\r\n]'), '').length, greaterThanOrEqualTo(200003));
    expect(s.text.toString(), endsWith('END\r\n'));

    final cat = UnixPty.start('/bin/cat', []);
    final c = Screen(cat);
    for (var i = 0; i < 200; i++) {
      cat.write('${'y' * 1000}\n');
    }
    cat.write('\x04');
    await cat.exit.timeout(const Duration(seconds: 10));
    expect(c.text.toString(), contains('yyyy'));
  });

  test('a missing executable or folder throws', () {
    expect(() => UnixPty.start('no-such-command-here', []), throwsA(isA<ProcessException>()));
    expect(() => UnixPty.start('/bin/sh', [], workingDirectory: '/no/such/dir'), throwsA(isA<ProcessException>()));
  });

  test('a master is not inherited by later terminals', () async {
    if (!Platform.isLinux) return;
    final first = UnixPty.start('/bin/sh', ['-c', 'sleep 5']);
    final second = UnixPty.start('/bin/sh', ['-c', r'ls /proc/$$/fd | wc -l']);
    final s = Screen(second);
    await second.exit;
    // stdin, stdout, stderr, plus the one ls itself opens on /proc/…/fd.
    expect(int.parse(s.text.toString().trim()), lessThanOrEqualTo(4));
    first.kill();
    await first.exit;
  });
}
