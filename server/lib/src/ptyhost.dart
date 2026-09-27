// The workers' terminal host: owns every worker's PTY so a restarting office doesn't take Claude
// down with it. The office starts it detached (see ptys.dart) and talks to it over a Unix socket
// that only its own token opens. It keeps a headless copy of each screen, so the next office gets
// the scrollback back, and ends everything once no office has come back for a while.
//
//   agent-office __ptyhost <socket> <info.json>

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_pty/office_pty.dart';
import 'package:path/path.dart' as p;

import 'headless.dart';
import 'ptys.dart';

/// How long terminals keep running with no office connected before the host gives up on it.
const orphanTimeout = Duration(minutes: 30);

/// A host nobody connects to at all has nothing to do.
const unclaimedTimeout = Duration(seconds: 30);

class _Session {
  _Session(this.id, this.proc, this.term, this.cols, this.rows);

  final String id;
  final UnixPty proc;
  final HeadlessTerminal term;
  int cols;
  int rows;
  bool busy = false;
  String title = '';

  /// The connected office knows this one: its output goes there.
  bool attached = true;
  int? exitCode;
}

/// Runs the host until it has nothing left to do, then exits the process. `args`: the socket to
/// listen on and the JSON file holding the token.
Future<void> runPtyHost(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: agent-office $ptyHostCommand <socket> <info.json>');
    exit(2);
  }
  final log = _openLog(p.join(p.dirname(args[1]), 'pty-host.log'));
  // One bad message must never take down every worker's terminal.
  await runZonedGuarded(() => _PtyHost(args[0], args[1], log).run(), (err, stack) {
    try {
      log?.writeStringSync('pty host: $err\n$stack\n');
    } catch (_) {
      // nowhere to say it
    }
  });
}

RandomAccessFile? _openLog(String path) {
  try {
    final f = File(path).openSync(mode: FileMode.write);
    chmodSync(path, 0x180); // 0600
    return f;
  } catch (_) {
    return null;
  }
}

class _PtyHost {
  _PtyHost(this.socketPath, this.infoPath, this.log);

  final String socketPath;
  final String infoPath;
  final RandomAccessFile? log;
  late final String token;
  final sessions = <String, _Session>{};
  Socket? office;
  ServerSocket? server;
  bool stopping = false;
  Timer? idleTimer;

  Future<void> run() async {
    token = (jsonDecode(File(infoPath).readAsStringSync()) as Map)['token'] as String;
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    // Another host already answering on this socket serves this office; leave it be.
    try {
      final probe = await Socket.connect(address, 0).timeout(const Duration(seconds: 3));
      probe.destroy();
      exit(0);
    } catch (_) {
      // nobody there
    }
    try {
      File(socketPath).deleteSync(); // left behind by a host that died
    } catch (_) {
      // none
    }
    final server = this.server = await ServerSocket.bind(address, 0);
    // Owner-only; the token keeps anyone else out regardless.
    chmodSync(socketPath, 0x180);
    server.listen(_onConnection, onError: (Object _) {});
    idleTimer = Timer(unclaimedTimeout, () {
      if (office == null && _live() == 0) exit(0);
    });
  }

  void send(Map<String, dynamic> msg) {
    final to = office;
    if (to == null) return;
    try {
      to.write(frame(msg));
    } catch (_) {
      // closing
    }
  }

  int _live() => sessions.values.where((s) => s.exitCode == null).length;

  void _drop(_Session s) {
    sessions.remove(s.id);
    s.term.dispose();
  }

  /// No office connected: wait for one to come back, but not forever.
  void _orphaned() {
    idleTimer?.cancel();
    if (_live() == 0) exit(0);
    idleTimer = Timer(orphanTimeout, _stopAll);
  }

  void _stopAll() {
    stopping = true;
    server?.close();
    var n = 0;
    for (final s in sessions.values) {
      if (s.exitCode != null) continue;
      n++;
      s.proc.kill();
    }
    if (n == 0) exit(0);
    Timer(const Duration(seconds: 3), () => exit(0));
  }

  void _spawn(String id, SpawnOpts opts) {
    UnixPty proc;
    try {
      proc = UnixPty.start(
        opts.file,
        opts.args,
        workingDirectory: opts.cwd,
        environment: {'TERM': 'xterm-256color', ...opts.env},
        cols: opts.cols,
        rows: opts.rows,
      );
    } catch (err) {
      send({'t': 'exit', 'id': id, 'exitCode': -1, 'error': err is ProcessException ? err.message : '$err'});
      return;
    }
    final term = HeadlessTerminal(cols: opts.cols, rows: opts.rows);
    final prelude = opts.prelude;
    if (prelude != null && prelude.isNotEmpty) term.write(prelude);
    final s = _Session(id, proc, term, opts.cols, opts.rows);
    sessions[id] = s;
    term.onProgress = (busy) => s.busy = busy;
    term.onTitleChange = (title) => s.title = title;
    proc.output.listen((data) {
      term.write(data);
      if (s.attached) send({'t': 'data', 'id': id, 'data': data});
    });
    proc.exit.then((status) {
      s.exitCode = status.exitCode;
      if (s.attached) {
        send({'t': 'exit', 'id': id, 'exitCode': status.exitCode});
        _drop(s);
      }
      if (stopping ? _live() == 0 : office == null && _live() == 0) exit(0);
    });
    send({'t': 'spawned', 'id': id, 'pid': proc.pid});
  }

  /// Hands a running terminal to the office: a snapshot of it so far, then its output as it comes.
  /// The screen is up to date the moment output is written to it, so nothing comes in between.
  void _attach(String id) {
    final s = sessions[id];
    if (s == null || s.exitCode != null) {
      if (s != null) _drop(s);
      send({'t': 'gone', 'id': id});
      return;
    }
    s.attached = true;
    final snapshot = s.term.serialize(scrollback: scrollback);
    send({
      't': 'attached',
      'id': id,
      'pid': s.proc.pid,
      'cols': s.cols,
      'rows': s.rows,
      'busy': s.busy,
      'title': s.title,
      'snapshot': snapshot,
    });
  }

  void _onMessage(Map<String, dynamic> msg) {
    final id = msg['id'];
    switch (msg['t']) {
      case 'spawn':
        final opts = msg['opts'];
        if (id is String && opts is Map<String, dynamic> && !stopping && !sessions.containsKey(id)) {
          SpawnOpts parsed;
          try {
            parsed = SpawnOpts.fromJson(opts);
          } catch (err) {
            send({'t': 'exit', 'id': id, 'exitCode': -1, 'error': 'bad spawn options: $err'});
            return;
          }
          _spawn(id, parsed);
        }
      case 'attach':
        if (id is String) _attach(id);
      case 'write':
        final data = msg['data'];
        if (data is String) sessions[id]?.proc.write(data);
      case 'resize':
        final s = sessions[id];
        final cols = msg['cols'], rows = msg['rows'];
        if (s == null || s.exitCode != null || cols is! num || rows is! num) break;
        final c = cols.toInt(), r = rows.toInt();
        if (c < 1 || r < 1) break;
        s.proc.resize(c, r);
        s.term.resize(c, r);
        s.cols = c;
        s.rows = r;
      case 'kill':
        final s = sessions[id];
        if (s == null) break;
        if (s.exitCode != null) {
          _drop(s);
        } else {
          s.proc.kill();
        }
      case 'stop':
        _stopAll();
    }
  }

  void _onConnection(Socket sock) {
    var authed = false;
    sock.done.catchError((Object _) {});
    readMessages(
      sock,
      (msg) {
        if (authed) {
          if (office == sock) _onMessage(msg);
          return;
        }
        final given = msg['token'];
        if (msg['t'] != 'hello' || given is! String || !_safeEq(given, token)) {
          sock.destroy();
          return;
        }
        authed = true;
        // The newest office wins; an older connection still open is a restart that hasn't finished dying.
        final old = office;
        if (old != null && old != sock) old.destroy();
        office = sock;
        idleTimer?.cancel();
        for (final s in sessions.values) {
          s.attached = false;
        }
        send({'t': 'ready', 'version': ptyProtocol, 'sessions': sessions.keys.toList()});
      },
      onDone: () {
        sock.destroy();
        if (office != sock) return;
        office = null;
        for (final s in sessions.values) {
          s.attached = false;
        }
        if (!stopping) _orphaned();
      },
    );
  }
}

bool _safeEq(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
