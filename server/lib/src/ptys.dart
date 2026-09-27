// Workers' terminals live in a small host process of their own (ptyhost.dart), not in the office.
// When the office restarts (a self-upgrade, a crash), Claude keeps working in the host, and the new
// office picks every terminal back up where it was. Without a host, terminals run in-process as
// before and die with the office.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:office_pty/office_pty.dart';
import 'package:path/path.dart' as p;
import 'package:pty2/pty2.dart' as pty2;

export 'headless.dart' show scrollback;

/// Bump whenever the host's messages change: an office that finds another host stops it and starts
/// its own. 1 was the Node host; 2 is the Dart one, whose snapshots come from its own serializer.
const int ptyProtocol = 2;

/// The subcommand of the office's executable that runs the host (see bin/agent_office.dart).
const String ptyHostCommand = '__ptyhost';

class SpawnOpts {
  const SpawnOpts({
    required this.file,
    required this.args,
    required this.cwd,
    required this.env,
    required this.cols,
    required this.rows,
    this.prelude,
  });

  factory SpawnOpts.fromJson(Map<String, dynamic> j) => SpawnOpts(
    file: j['file'] as String,
    args: [for (final a in j['args'] as List) a as String],
    cwd: j['cwd'] as String,
    env: {for (final e in (j['env'] as Map).entries) e.key as String: e.value as String},
    cols: (j['cols'] as num).toInt(),
    rows: (j['rows'] as num).toInt(),
    prelude: j['prelude'] as String?,
  );

  final String file;
  final List<String> args;
  final String cwd;
  final Map<String, String> env;
  final int cols;
  final int rows;

  /// Output from before this process (a restored scrollback), for the host's copy of the screen.
  final String? prelude;

  Map<String, dynamic> toJson() => {
    'file': file,
    'args': args,
    'cwd': cwd,
    'env': env,
    'cols': cols,
    'rows': rows,
    'prelude': ?prelude,
  };
}

class PtyExit {
  const PtyExit(this.exitCode, {this.error, this.lost = false});

  final int exitCode;

  /// It never started.
  final String? error;

  /// The host went away under it; the process is gone.
  final bool lost;
}

/// A worker's terminal process, wherever it runs.
abstract interface class Pty {
  /// Its session in the host, which outlives the office. None: it dies with the office.
  String? get id;
  int get pid;
  void write(String data);
  void resize(int cols, int rows);
  void kill();
  void onData(void Function(String data) cb);
  void onExit(void Function(PtyExit e) cb);
}

/// A terminal the host was still running when the office came back.
class Adopted {
  const Adopted({
    required this.pty,
    required this.cols,
    required this.rows,
    required this.busy,
    required this.title,
    required this.snapshot,
  });

  final Pty pty;
  final int cols;
  final int rows;

  /// Claude's last OSC 9;4 progress report.
  final bool busy;
  final String title;

  /// Scrollback and screen, to replay into a fresh terminal.
  final String snapshot;
}

/// Calls [onMsg] with each newline-delimited JSON object on [sock].
StreamSubscription<String> readMessages(
  Stream<List<int>> sock,
  void Function(Map<String, dynamic> msg) onMsg, {
  void Function()? onDone,
}) {
  return sock
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line.isEmpty) return;
          Object? msg;
          try {
            msg = jsonDecode(line);
          } catch (_) {
            return;
          }
          if (msg is Map<String, dynamic>) onMsg(msg);
        },
        onError: (Object _) {},
        onDone: onDone,
        cancelOnError: false,
      );
}

String frame(Map<String, dynamic> msg) => '${jsonEncode(msg)}\n';

/// Where the host listens and where its token is kept, for a data dir.
({String socketPath, String infoPath}) hostPaths(String dataDir) {
  // Unix socket paths are capped at ~104 bytes; a deep project falls back to the temp dir.
  final inData = p.join(dataDir, 'pty.sock');
  final hash = sha256.convert(utf8.encode(dataDir)).toString().substring(0, 16);
  final socketPath = utf8.encode(inData).length < 100
      ? inData
      : p.join(Directory.systemTemp.path, 'agent-office-$hash.sock');
  return (socketPath: socketPath, infoPath: p.join(dataDir, 'pty-host.json'));
}

class _RemotePty implements Pty {
  _RemotePty(this.id, this._send);

  @override
  final String id;
  @override
  int pid = 0;
  final void Function(Map<String, dynamic>) _send;
  final _dataCbs = <void Function(String)>[];
  final _exitCbs = <void Function(PtyExit)>[];

  /// Output that came in before anyone listened (between an attach and the worker wiring up).
  final _held = <String>[];
  PtyExit? _exited;

  @override
  void write(String data) => _send({'t': 'write', 'id': id, 'data': data});

  @override
  void resize(int cols, int rows) => _send({'t': 'resize', 'id': id, 'cols': cols, 'rows': rows});

  @override
  void kill() => _send({'t': 'kill', 'id': id});

  @override
  void onData(void Function(String data) cb) {
    _dataCbs.add(cb);
    final held = List.of(_held);
    _held.clear();
    held.forEach(cb);
  }

  @override
  void onExit(void Function(PtyExit e) cb) {
    _exitCbs.add(cb);
    final e = _exited;
    if (e != null) cb(e);
  }

  void emitData(String data) {
    if (_dataCbs.isEmpty) _held.add(data);
    for (final cb in List.of(_dataCbs)) {
      cb(data);
    }
  }

  void emitExit(PtyExit e) {
    _exited = e;
    for (final cb in List.of(_exitCbs)) {
      cb(e);
    }
  }
}

/// A terminal run in this process: it dies with the office.
class LocalPty implements Pty {
  LocalPty._(this.pid, Stream<String> output, Future<PtyExit> exit, this._write, this._resize, this._kill) {
    output.listen((d) {
      if (_dataCbs.isEmpty) _held.add(d);
      for (final cb in List.of(_dataCbs)) {
        cb(d);
      }
    });
    exit.then((e) {
      _exited = e;
      for (final cb in List.of(_exitCbs)) {
        cb(e);
      }
    });
  }

  /// Starts [opts] in a new PTY, like node-pty's spawn: `TERM=xterm-256color`, exactly
  /// [SpawnOpts.env] besides. Throws if it can't start.
  factory LocalPty.spawn(SpawnOpts opts) {
    final env = {'TERM': 'xterm-256color', ...opts.env};
    if (Platform.isWindows) {
      // No pid there (pty2 doesn't expose it); the office only needs it for the port list.
      final proc = pty2.PseudoTerminal.start(opts.file, opts.args, workingDirectory: opts.cwd, environment: env);
      proc.resize(opts.cols, opts.rows);
      return LocalPty._(0, proc.out, proc.exitCode.then((c) => PtyExit(c)), proc.write, proc.resize, () => proc.kill());
    }
    final proc = UnixPty.start(
      opts.file,
      opts.args,
      workingDirectory: opts.cwd,
      environment: env,
      cols: opts.cols,
      rows: opts.rows,
    );
    return LocalPty._(
      proc.pid,
      proc.output,
      proc.exit.then((s) => PtyExit(s.exitCode)),
      proc.write,
      proc.resize,
      () => proc.kill(),
    );
  }

  @override
  String? get id => null;
  @override
  final int pid;
  final void Function(String) _write;
  final void Function(int, int) _resize;
  final void Function() _kill;
  final _dataCbs = <void Function(String)>[];
  final _exitCbs = <void Function(PtyExit)>[];
  final _held = <String>[];
  PtyExit? _exited;

  @override
  void write(String data) {
    if (_exited == null) _write(data);
  }

  @override
  void resize(int cols, int rows) {
    if (_exited == null) _resize(cols, rows);
  }

  @override
  void kill() {
    if (_exited == null) _kill();
  }

  @override
  void onData(void Function(String data) cb) {
    _dataCbs.add(cb);
    final held = List.of(_held);
    _held.clear();
    held.forEach(cb);
  }

  @override
  void onExit(void Function(PtyExit e) cb) {
    _exitCbs.add(cb);
    final e = _exited;
    if (e != null) cb(e);
  }
}

/// An open, authenticated connection to a host.
class _Conn {
  _Conn(this.sock);
  final Socket sock;
  late final StreamSubscription<String> sub;
  void Function(Map<String, dynamic>)? onMsg;
  final closed = Completer<void>();
  bool destroyed = false;

  void send(Map<String, dynamic> msg) {
    if (destroyed) return;
    try {
      sock.write(frame(msg));
    } catch (_) {
      // closing
    }
  }

  void destroy() {
    if (destroyed) return;
    destroyed = true;
    sub.cancel();
    sock.destroy();
    if (!closed.isCompleted) closed.complete();
  }
}

class PtyHost {
  PtyHost(this.dataDir, this.onLost) {
    final paths = hostPaths(dataDir);
    socketPath = paths.socketPath;
    infoPath = paths.infoPath;
  }

  final String dataDir;
  final void Function() onLost;
  late final String socketPath;
  late final String infoPath;

  _Conn? _conn;
  final _ptys = <String, _RemotePty>{};
  final _attaching = <String, void Function(Map<String, dynamic>?)>{};

  /// Sessions the host already had when the office connected, not yet claimed by a worker.
  var _unclaimed = <String>{};

  /// Leaving on purpose: the connection closing is not the host dying.
  var _leaving = false;

  bool get hosted => _conn != null;

  /// Finds the host this office left running, or starts one. False when there is no host to be
  /// had: terminals then run in-process.
  Future<bool> connect() async {
    if (Platform.isWindows) return false;
    try {
      var found = await _hello();
      if (found != null && found.version != ptyProtocol) {
        // A host from another build: its terminals go (workers resume their conversations).
        final old = found.conn;
        old.onMsg = null;
        old.send({'t': 'stop'});
        try {
          await old.sock.flush();
          await old.sock.close();
        } catch (_) {
          // gone already
        }
        await old.closed.future.timeout(const Duration(seconds: 5), onTimeout: () {});
        old.destroy();
        found = null;
      }
      if (found == null) {
        await _startHost();
        // A compiled office's host is up at once; under `dart run` / `dart test` the VM compiles it
        // first, which on a busy machine (several hosts starting together) takes a good while.
        final wait = hostCommand().length > 1 ? const Duration(seconds: 60) : const Duration(seconds: 10);
        final deadline = DateTime.now().add(wait);
        while (found == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          found = await _hello();
        }
      }
      if (found == null) return false;
      final conn = found.conn;
      _conn = conn;
      _unclaimed = found.sessions.toSet();
      conn.onMsg = _onMessage;
      conn.closed.future.then((_) => _onClose(conn));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A new terminal: in the host when there is one, else in-process. Throws if it can't start.
  Pty spawn(SpawnOpts opts) {
    if (_conn == null) return LocalPty.spawn(opts);
    final id = _randomHex(8);
    final pty = _RemotePty(id, _send);
    _ptys[id] = pty;
    _send({'t': 'spawn', 'id': id, 'opts': opts.toJson()});
    return pty;
  }

  /// Picks up a terminal from before the restart. Null if the host no longer has it running.
  Future<Adopted?> attach(String id) async {
    if (_conn == null || !_unclaimed.remove(id)) return null;
    final pty = _RemotePty(id, _send);
    _ptys[id] = pty;
    final done = Completer<Map<String, dynamic>?>();
    // The office waits on this before it opens its doors: never for long.
    final timer = Timer(const Duration(seconds: 5), () {
      _attaching.remove(id);
      if (!done.isCompleted) done.complete(null);
    });
    _attaching[id] = (m) {
      timer.cancel();
      if (!done.isCompleted) done.complete(m);
    };
    _send({'t': 'attach', 'id': id});
    final msg = await done.future;
    if (msg == null || msg['t'] != 'attached') {
      _ptys.remove(id);
      // Its worker resumes the conversation afresh; the old process mustn't carry on beside it.
      _send({'t': 'kill', 'id': id});
      return null;
    }
    pty.pid = (msg['pid'] as num?)?.toInt() ?? 0;
    return Adopted(
      pty: pty,
      cols: (msg['cols'] as num?)?.toInt() ?? 80,
      rows: (msg['rows'] as num?)?.toInt() ?? 24,
      busy: msg['busy'] == true,
      title: msg['title'] is String ? msg['title'] as String : '',
      snapshot: msg['snapshot'] is String ? msg['snapshot'] as String : '',
    );
  }

  /// Ends the host's terminals that no worker claimed (their worker was sent home meanwhile).
  void killUnclaimed() {
    for (final id in _unclaimed) {
      _send({'t': 'kill', 'id': id});
    }
    _unclaimed.clear();
  }

  /// The office is restarting: leave every terminal running in the host for the next one.
  Future<void> detach() async {
    _leaving = true;
    await _end(null);
  }

  /// The office is closing for good: the host ends every terminal and exits.
  Future<void> stop() async {
    _leaving = true;
    await _end({'t': 'stop'});
  }

  Future<void> _end(Map<String, dynamic>? last) async {
    final conn = _conn;
    if (conn == null) return;
    if (last != null) conn.send(last);
    try {
      await conn.sock.flush().timeout(const Duration(seconds: 2));
      await conn.sock.close().timeout(const Duration(seconds: 2));
      // close() can complete before the last bytes are out, and destroying the socket then drops
      // them (a stop the host never hears leaves it running). The host hangs up once it has read
      // everything, so wait for that.
      await conn.closed.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // gone already
    }
    conn.destroy();
  }

  void _send(Map<String, dynamic> msg) => _conn?.send(msg);

  void _onMessage(Map<String, dynamic> msg) {
    final id = msg['id'];
    if (id is! String) return;
    switch (msg['t']) {
      case 'spawned':
        final pty = _ptys[id];
        if (pty != null) pty.pid = (msg['pid'] as num?)?.toInt() ?? 0;
      case 'attached':
      case 'gone':
        _attaching.remove(id)?.call(msg);
      case 'data':
        final data = msg['data'];
        if (data is String) _ptys[id]?.emitData(data);
      case 'exit':
        final pty = _ptys.remove(id);
        pty?.emitExit(PtyExit((msg['exitCode'] as num?)?.toInt() ?? -1, error: msg['error'] as String?));
    }
  }

  void _onClose(_Conn conn) {
    if (_conn != conn) return;
    _conn = null;
    for (final resolve in List.of(_attaching.values)) {
      resolve(null);
    }
    _attaching.clear();
    if (_leaving) return;
    // The host died (killed, crashed). From here on terminals run in-process.
    final lost = List.of(_ptys.values);
    _ptys.clear();
    onLost();
    for (final pty in lost) {
      pty.emitExit(const PtyExit(-1, lost: true));
    }
  }

  /// Connects and says hello with the saved token. Null if no host answers.
  Future<({_Conn conn, int version, List<String> sessions})?> _hello() async {
    String token;
    try {
      final info = jsonDecode(File(infoPath).readAsStringSync());
      token = (info as Map)['token'] as String;
    } catch (_) {
      return null;
    }
    Socket sock;
    try {
      sock = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
    final conn = _Conn(sock);
    final ready = Completer<Map<String, dynamic>?>();
    conn.onMsg = (msg) {
      if (msg['t'] == 'ready' && !ready.isCompleted) ready.complete(msg);
    };
    conn.sub = readMessages(
      sock,
      (msg) => conn.onMsg?.call(msg),
      onDone: () {
        if (!ready.isCompleted) ready.complete(null);
        conn.destroy();
      },
    );
    sock.done.catchError((Object _) {
      if (!ready.isCompleted) ready.complete(null);
      conn.destroy();
    });
    conn.send({'t': 'hello', 'token': token});
    final msg = await ready.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (msg == null) {
      conn.destroy();
      return null;
    }
    conn.onMsg = null;
    final sessions = msg['sessions'];
    return (
      conn: conn,
      version: (msg['version'] as num?)?.toInt() ?? 0,
      sessions: sessions is List ? [for (final s in sessions) '$s'] : <String>[],
    );
  }

  /// Starts a host, detached so that it outlives this process and never sees its Ctrl+C.
  Future<void> _startHost() async {
    _writeInfo(infoPath, {'token': _randomHex(24)});
    final cmd = hostCommand();
    await Process.start(
      cmd.first,
      [...cmd.skip(1), ptyHostCommand, socketPath, infoPath],
      mode: ProcessStartMode.detached,
      workingDirectory: Directory.systemTemp.path,
    );
  }
}

/// How to run this program again, to start the host: the compiled executable itself, or under
/// `dart run` / `dart test` the Dart VM with bin/agent_office.dart.
List<String> hostCommand() {
  final exe = Platform.resolvedExecutable;
  final name = p.basenameWithoutExtension(exe);
  if (name != 'dart' && name != 'dartvm' && name != 'dartaotruntime') return [exe];
  final lib = Isolate.resolvePackageUriSync(Uri.parse('package:agent_office_server/src/ptys.dart'));
  if (lib == null) throw StateError("can't find the office's sources to start the terminal host");
  final root = p.dirname(p.dirname(p.dirname(lib.toFilePath())));
  final packages = Isolate.packageConfigSync;
  return [exe, if (packages != null) '--packages=${packages.toFilePath()}', p.join(root, 'bin', 'agent_office.dart')];
}

void _writeInfo(String file, Map<String, dynamic> info) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(jsonEncode(info), flush: true);
  chmodSync(tmp, 0x180); // 0600: the token opens every worker's terminal
  File(tmp).renameSync(file);
}

final _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
