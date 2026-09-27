// A process in a Unix pseudo-terminal. The fork/exec sequence is pty2 0.5.4's (MIT, Copyright (c)
// 2020 xuty; see LICENSE); the rest is rewritten for the office (see README.md for what and why).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart' as c;

/// How a PTY's process ended, as node-pty reports it.
class PtyExitStatus {
  const PtyExitStatus(this.exitCode, this.signal);

  /// Its exit status; 0 when a signal ended it, -1 when it can't be known (something else reaped it).
  final int exitCode;

  /// The signal that ended it, else 0.
  final int signal;

  @override
  String toString() => 'PtyExitStatus($exitCode, signal $signal)';
}

/// A process running in its own session with a new pseudo-terminal as its controlling terminal, the
/// way node-pty starts one: Ctrl+C typed into it reaches the process as SIGINT.
class UnixPty {
  UnixPty._(this.pid, this._fd) {
    final port = ReceivePort();
    final decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_StringSink(_out.add));
    port.listen((msg) {
      if (msg is TransferableTypedData) {
        decoder.add(msg.materialize().asUint8List());
      } else if (msg == 'reaped') {
        // Its pid is free for the system to reuse from here on: no more signals to it.
        _reaped = true;
      } else if (msg is List) {
        // The reader is done with the master: only now is it safe to close (and its number reused).
        port.close();
        decoder.close();
        _closeFd();
        _exited = true;
        _out.close();
        _exit.complete(PtyExitStatus(msg[0] as int, msg[1] as int));
      }
    });
    Isolate.spawn(_readLoop, (port.sendPort, _fd, pid), debugName: 'pty $pid reader').catchError((Object e) {
      port.close();
      _closeFd();
      _exited = true;
      _out.close();
      _exit.complete(const PtyExitStatus(-1, 0));
      return Isolate.current;
    });
  }

  /// Starts [executable] (looked up on the `PATH` of [environment] when it has no slash) with
  /// [arguments]. [environment] is the child's whole environment; null inherits this process's.
  /// Throws when it can't start: no such executable or working directory, no PTY to be had.
  static UnixPty start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int cols = 80,
    int rows = 24,
  }) {
    if (Platform.isWindows) throw UnsupportedError('UnixPty is Unix only');
    final env = {...(environment ?? Platform.environment)};
    env.putIfAbsent('TERM', () => 'xterm-256color');
    final file = _resolve(executable, env['PATH'] ?? Platform.environment['PATH'] ?? '');
    if (file == null) throw ProcessException(executable, arguments, 'No such file or executable', 2);
    if (workingDirectory != null && !Directory(workingDirectory).existsSync()) {
      throw ProcessException(executable, arguments, 'No such working directory: $workingDirectory', 2);
    }

    return using((arena) {
      final nativeFile = file.toNativeUtf8(allocator: arena);
      final nativeCwd = workingDirectory?.toNativeUtf8(allocator: arena) ?? nullptr;
      final argv = arena<Pointer<Utf8>>(arguments.length + 2);
      argv[0] = executable.toNativeUtf8(allocator: arena);
      for (var i = 0; i < arguments.length; i++) {
        argv[i + 1] = arguments[i].toNativeUtf8(allocator: arena);
      }
      argv[arguments.length + 1] = nullptr;
      final entries = env.entries.toList();
      final envp = arena<Pointer<Utf8>>(entries.length + 1);
      for (var i = 0; i < entries.length; i++) {
        envp[i] = '${entries[i].key}=${entries[i].value}'.toNativeUtf8(allocator: arena);
      }
      envp[entries.length] = nullptr;
      // An empty sigset_t (128 bytes covers every platform's).
      final emptySet = arena<Uint8>(128).cast<Void>();

      final pPtm = arena<Int32>();
      final size = arena<c.WinSize>();
      size.ref
        ..cols = cols
        ..rows = rows;

      // Everything the child uses is computed here: after the fork it may only make leaf calls,
      // with no loops (a backward branch is a safepoint check, which can deadlock in the child).
      final setmask = c.SIG_SETMASK;
      final hasCwd = nativeCwd != nullptr;
      final s = c.resetSignals;
      final s0 = s[0], s1 = s[1], s2 = s[2], s3 = s[3], s4 = s[4], s5 = s[5], s6 = s[6], s7 = s[7], s8 = s[8];
      final dfl = Pointer<Void>.fromAddress(0); // SIG_DFL
      // Resolve every native the child calls before forking, with calls that change nothing.
      c.chdir(nullptr);
      c.signal(-1, dfl);
      c.sigprocmask(setmask, nullptr, nullptr);
      c.execve(nullptr, nullptr, nullptr);
      c.kill(c.getpid(), 0);
      final forkpty = c.forkpty;

      // The session, the controlling terminal and stdio are set up by forkpty itself, in C: no
      // Dart code has to run in the child for them (pty2 calls setsid from Dart, which can't be
      // resolved ahead of time without calling it in the parent).
      final pid = forkpty(pPtm, nullptr, nullptr, size);
      if (pid == 0) {
        // The child. No loops, no allocation: leaf calls only.
        if (hasCwd) c.chdir(nativeCwd);
        c.signal(s0, dfl);
        c.signal(s1, dfl);
        c.signal(s2, dfl);
        c.signal(s3, dfl);
        c.signal(s4, dfl);
        c.signal(s5, dfl);
        c.signal(s6, dfl);
        c.signal(s7, dfl);
        c.signal(s8, dfl);
        c.sigprocmask(setmask, emptySet, nullptr);
        c.execve(nativeFile, argv, envp);
        c.kill(c.getpid(), 9); // exec failed
      }
      if (pid < 0) throw ProcessException(executable, arguments, 'forkpty failed');
      final ptm = pPtm.value;
      // Children started later must not hold this master open (see README.md).
      c.fcntl(ptm, c.F_SETFD, c.FD_CLOEXEC);
      c.fcntl(ptm, c.F_SETFL, c.fcntl(ptm, c.F_GETFL, 0) | c.O_NONBLOCK);
      return UnixPty._(pid, ptm);
    });
  }

  /// The child's process id.
  final int pid;

  int _fd;
  bool _exited = false;
  bool _reaped = false;
  final _out = StreamController<String>();
  final _exit = Completer<PtyExitStatus>();
  final _pending = <Uint8List>[];
  Timer? _retry;

  /// Everything the process writes to the terminal, decoded as UTF-8. Done before [exit] completes.
  Stream<String> get output => _out.stream;

  /// Completes once the process has ended and all of its output has been delivered.
  Future<PtyExitStatus> get exit => _exit.future;

  bool get exited => _exited;

  /// Types [data] into the terminal. Queued when the terminal's input buffer is full.
  void write(String data) {
    if (_fd < 0 || data.isEmpty) return;
    _pending.add(utf8.encode(data));
    _flush();
  }

  void _flush() {
    _retry = null;
    if (_fd < 0) {
      _pending.clear();
      return;
    }
    while (_pending.isNotEmpty) {
      final chunk = _pending.first;
      final n = using((arena) {
        final buf = arena<Uint8>(chunk.length);
        buf.asTypedList(chunk.length).setAll(0, chunk);
        return c.write(_fd, buf, chunk.length);
      });
      if (n <= 0) break; // full (EAGAIN) or gone: try again shortly
      _pending[0] = Uint8List.sublistView(chunk, n);
      if (_pending.first.isEmpty) _pending.removeAt(0);
    }
    if (_pending.isNotEmpty) _retry ??= Timer(const Duration(milliseconds: 10), _flush);
  }

  /// Tells the process its terminal is now [cols] x [rows] (SIGWINCH).
  void resize(int cols, int rows) {
    if (_fd < 0) return;
    using((arena) {
      final size = arena<c.WinSize>();
      size.ref
        ..cols = cols
        ..rows = rows;
      c.ioctl(_fd, c.TIOCSWINSZ, size.cast());
    });
  }

  /// Sends [signal] to the process (node-pty's default, SIGHUP, is a terminal hanging up). False
  /// once it has ended.
  bool kill([ProcessSignal signal = ProcessSignal.sighup]) {
    if (_exited || _reaped) return false;
    return Process.killPid(pid, signal);
  }

  void _closeFd() {
    _retry?.cancel();
    _pending.clear();
    if (_fd >= 0) c.close(_fd);
    _fd = -1;
  }

  static String? _resolve(String executable, String path) {
    bool runnable(String f) {
      final stat = FileStat.statSync(f);
      return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0; // any x bit
    }

    if (executable.contains('/')) return runnable(executable) ? executable : null;
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      final f = '$dir/$executable';
      if (runnable(f)) return f;
    }
    return null;
  }
}

/// How long output is still read after the process ended, for a background process that still
/// holds the terminal. Then the master is closed, which hangs the terminal up on it.
const _drainMs = 1000;

/// Runs in its own isolate: reads the master until the terminal is hung up and the process has
/// ended, then reports the exit. The master stays open; the owner closes it on the exit message.
void _readLoop((SendPort, int, int) args) {
  final (port, fd, pid) = args;
  final buf = calloc<Uint8>(65536);
  final pfd = calloc<c.PollFd>();
  final status = calloc<Int32>();
  int? code;
  var sig = 0;
  var eof = false;
  int? drainUntil;

  void reap(bool block) {
    final r = c.waitpid(pid, status, block ? 0 : c.WNOHANG);
    if (r == pid) {
      final st = status.value;
      if (st & 0x7f == 0) {
        code = (st >> 8) & 0xff;
      } else {
        code = 0;
        sig = st & 0x7f;
      }
    } else if (r < 0) {
      // Not our child any more: something else reaped it (the VM's own process handling can).
      code = -1;
    }
  }

  try {
    while (!eof) {
      pfd.ref
        ..fd = fd
        ..events = c.POLLIN
        ..revents = 0;
      final n = c.poll(pfd, 1, code == null ? 250 : 50);
      if (n > 0) {
        final re = pfd.ref.revents;
        if (re & c.POLLIN != 0) {
          final got = c.read(fd, buf, 65536);
          if (got > 0) {
            port.send(TransferableTypedData.fromList([Uint8List.fromList(buf.asTypedList(got))]));
            continue;
          }
          // 0 is end of file; -1 with a hang-up is the terminal gone (EIO), else just nothing yet.
          if (got == 0 || re & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) eof = true;
        } else if (re & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) {
          eof = true;
        }
      }
      if (code == null) {
        reap(false);
        if (code != null) port.send('reaped');
      }
      if (code != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        drainUntil ??= now + _drainMs;
        if (now >= drainUntil) break;
      }
    }
    // Hung up: the process has closed the terminal, and is ending (or has) if it hasn't already.
    if (code == null) reap(true);
  } finally {
    calloc.free(buf);
    calloc.free(pfd);
    calloc.free(status);
  }
  port.send([code ?? -1, sig]);
}

class _StringSink implements Sink<String> {
  _StringSink(this._add);
  final void Function(String) _add;

  @override
  void add(String data) {
    if (data.isNotEmpty) _add(data);
  }

  @override
  void close() {}
}
