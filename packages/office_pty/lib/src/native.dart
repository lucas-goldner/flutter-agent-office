// The libc calls a PTY needs. Adapted from pty2 0.5.4 (MIT, Copyright (c) 2020 xuty; see LICENSE).
//
// Everything the forked child calls is an `@Native` leaf function, resolved before the fork (see
// unix_pty.dart): a leaf call never enters the VM, which is all the child can safely do before exec.
// The calls that can wait (poll, read, waitpid) are not leaf calls: a leaf call holds off every
// garbage collection in the process until it returns.

// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

@Native<Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Void>,)>)>(symbol: 'ioctl', isLeaf: true)
external int ioctl(int fd, int request, Pointer<Void> arg);

@Native<Int32 Function(Int32)>(symbol: 'close', isLeaf: true)
external int close(int fd);

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'chdir', isLeaf: true)
external int chdir(Pointer<Utf8> path);

@Native<Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)>(symbol: 'execve', isLeaf: true)
external int execve(Pointer<Utf8> file, Pointer<Pointer<Utf8>> argv, Pointer<Pointer<Utf8>> envp);

@Native<Int32 Function()>(symbol: 'getpid', isLeaf: true)
external int getpid();

@Native<Int32 Function(Int32, Int32)>(symbol: 'kill', isLeaf: true)
external int kill(int pid, int sig);

@Native<Pointer<Void> Function(Int32, Pointer<Void>)>(symbol: 'signal', isLeaf: true)
external Pointer<Void> signal(int sig, Pointer<Void> handler);

@Native<Int32 Function(Int32, Pointer<Void>, Pointer<Void>)>(symbol: 'sigprocmask', isLeaf: true)
external int sigprocmask(int how, Pointer<Void> set, Pointer<Void> old);

@Native<Int32 Function(Int32, Int32, VarArgs<(Int32,)>)>(symbol: 'fcntl', isLeaf: true)
external int fcntl(int fd, int cmd, int arg);

@Native<IntPtr Function(Int32, Pointer<Uint8>, Size)>(symbol: 'read')
external int read(int fd, Pointer<Uint8> buf, int count);

@Native<IntPtr Function(Int32, Pointer<Uint8>, Size)>(symbol: 'write')
external int write(int fd, Pointer<Uint8> buf, int count);

@Native<Int32 Function(Pointer<PollFd>, UnsignedLong, Int32)>(symbol: 'poll')
external int poll(Pointer<PollFd> fds, int nfds, int timeout);

@Native<Int32 Function(Int32, Pointer<Int32>, Int32)>(symbol: 'waitpid')
external int waitpid(int pid, Pointer<Int32> status, int options);

typedef _ForkptyC = Int32 Function(Pointer<Int32>, Pointer<Void>, Pointer<Void>, Pointer<WinSize>);
typedef _ForkptyDart = int Function(Pointer<Int32>, Pointer<Void>, Pointer<Void>, Pointer<WinSize>);

/// `forkpty`: opens a PTY and forks, the child in a new session with the PTY as its controlling
/// terminal and stdio. It is in libc on macOS and on glibc 2.34+, in libutil before that.
///
/// A leaf call, like pty2's `fork`: the child comes back into Dart code in the state the parent left.
final _ForkptyDart forkpty = () {
  for (final lib in [
    DynamicLibrary.process,
    () => DynamicLibrary.open('libutil.so.1'),
    () => DynamicLibrary.open('libutil.so'),
  ]) {
    try {
      return lib().lookupFunction<_ForkptyC, _ForkptyDart>('forkpty', isLeaf: true);
    } catch (_) {
      // next
    }
  }
  throw UnsupportedError('forkpty is not available');
}();

final class WinSize extends Struct {
  @Uint16()
  external int rows;
  @Uint16()
  external int cols;
  @Uint16()
  external int xpixel;
  @Uint16()
  external int ypixel;
}

final class PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

final bool _mac = Platform.isMacOS;

final int TIOCSWINSZ = _mac ? 0x80087467 : 0x5414;
final int O_NONBLOCK = _mac ? 0x4 : 0x800;
final int SIG_SETMASK = _mac ? 3 : 2;
const F_SETFD = 2;
const F_GETFL = 3;
const F_SETFL = 4;
const FD_CLOEXEC = 1;
const WNOHANG = 1;
const POLLIN = 0x1;
const POLLERR = 0x8;
const POLLHUP = 0x10;
const POLLNVAL = 0x20;

/// Signals the Dart VM may have set to be ignored, which (unlike handled ones) stay ignored across exec.
final List<int> resetSignals = [
  1, // SIGHUP
  2, // SIGINT
  3, // SIGQUIT
  13, // SIGPIPE
  15, // SIGTERM
  _mac ? 18 : 20, // SIGTSTP
  21, // SIGTTIN
  22, // SIGTTOU
  25, // SIGXFSZ
];

@Native<Int32 Function(Pointer<Utf8>, Uint16)>(symbol: 'chmod')
external int chmod(Pointer<Utf8> path, int mode);
