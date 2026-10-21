import 'dart:async';
import 'dart:io';

/// Opens a page in this computer's browser. Not over SSH, in CI, or on a Linux box without a
/// desktop: nobody would see it there.
bool openBrowser(String url) {
  final env = Platform.environment;
  bool set(String k) => (env[k] ?? '').isNotEmpty;
  if (set('SSH_CONNECTION') || set('SSH_TTY') || set('CI')) return false;
  if (Platform.isLinux && !set('DISPLAY') && !set('WAYLAND_DISPLAY')) return false;
  final (cmd, args) = Platform.isMacOS
      ? ('open', [url])
      : Platform.isWindows
      ? ('rundll32', ['url.dll,FileProtocolHandler', url])
      : ('xdg-open', [url]);
  unawaited(Process.start(cmd, args, mode: ProcessStartMode.detached).then((_) {}, onError: (Object _) {}));
  return true;
}

/// Shows [path] in this computer's file manager: Finder with the file selected (a folder, opened).
bool revealInFiles(String path, {required bool folder}) {
  final (cmd, args) = Platform.isMacOS
      ? ('open', folder ? [path] : ['-R', path])
      : Platform.isWindows
      ? ('explorer', folder ? [path] : ['/select,', path])
      : ('xdg-open', [folder ? path : File(path).parent.path]);
  unawaited(Process.start(cmd, args, mode: ProcessStartMode.detached).then((_) {}, onError: (Object _) {}));
  return true;
}
