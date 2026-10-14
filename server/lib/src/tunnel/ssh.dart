import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'office.dart';

// The SSH half of `agent-office tunnel office@<address>`: localhost:<port> here to the office's
// port on its machine, the one thing an invited key may forward to. Everything else the client
// does goes through that one forward. A tunnel that drops (the laptop slept, the Wi-Fi changed)
// is opened again. It runs the system's `ssh`. Ported from src/server/tunnel/ssh.ts.

/// How often to look whether the office answers through a tunnel that's opening.
const _lookMs = 300;
const _retryMs = 2000;
const _maxRetryMs = 30000;

/// The ssh arguments that forward `localhost:<localPort>` to the office's port on its machine.
List<String> sshArgs(String target, int localPort, int officePort, [List<String> extra = const []]) => [
  '-N',
  '-o', 'ExitOnForwardFailure=yes',
  // Notices within a minute that the other end is gone, so the tunnel can be opened again.
  '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=3',
  '-L', '$localPort:localhost:$officePort',
  ...extra,
  target,
];

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

class SshTunnel {
  /// [dropped]: it was open and isn't any more; it's being opened again. [back]: open again after dropping.
  SshTunnel(this._args, this._office, {required this.dropped, required this.back});

  final List<String> _args;

  /// The office at the local end of the tunnel.
  final TunnelOffice _office;
  final void Function() dropped;
  final void Function() back;
  Process? _child;
  Future<int>? _exit;
  bool _stopped = false;

  /// Opens the tunnel and keeps it open: why it couldn't be opened, or '' once the office answers
  /// through it. ssh asks for a passphrase, or whether to trust the server, in the terminal.
  Future<String> open() async {
    final err = await _once();
    if (err.isEmpty) unawaited(_keep());
    return err;
  }

  void stop() {
    _stopped = true;
    _child?.kill();
  }

  /// One ssh: '' once the office answers through it, or why it never did.
  Future<String> _once() async {
    Process child;
    try {
      child = await Process.start('ssh', _args, mode: ProcessStartMode.inheritStdio);
    } on ProcessException catch (e) {
      return e.errorCode == 2 ? "ssh isn't installed on this computer" : "couldn't run ssh: ${e.message}";
    }
    _child = child;
    final exit = child.exitCode;
    _exit = exit;
    var over = false;
    final result = Completer<String>();
    void finish(String err) {
      if (over) return;
      over = true;
      result.complete(err);
    }

    unawaited(exit.then((code) => finish("ssh couldn't open the tunnel${code != 0 ? ' (it exited with $code)' : ''}")));
    unawaited(() async {
      while (!over && !await _office.up()) {
        await _sleep(_lookMs);
      }
      finish('');
    }());
    return result.future;
  }

  /// Waits for the tunnel to drop, then opens it again, for as long as it takes.
  Future<void> _keep() async {
    for (var wait = _retryMs; !_stopped;) {
      await _exit;
      if (_stopped) return;
      dropped();
      for (;;) {
        await _sleep(wait);
        if (_stopped) return;
        if ((await _once()).isEmpty) break;
        wait = min(wait * 2, _maxRetryMs);
      }
      if (_stopped) return;
      wait = _retryMs;
      back();
    }
  }
}
