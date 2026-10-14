import 'dart:async';
import 'dart:io';

// On an office set up with `deploy/provision.sh --tailscale`, Tailscale Serve puts the office on
// https://<office>.ts.net for everyone on the tailnet. Each worker's web server gets its own port
// there too, https://<office>.ts.net:5173, which Serve also points at the office's port: the office
// checks the visitor is signed in and relays it by that port (relay.dart), like a service tunnel.
// Changing Tailscale's settings takes root, so this goes through a helper provision.sh installs
// (with a sudoers line) that only ever points a port at the office. Ported from src/server/tailnet.ts.

String _defaultHelper() => Platform.environment['AGENT_OFFICE_SERVE_HELPER'] ?? '/usr/local/bin/agent-office-serve';

/// Long enough for the first scan of workers' servers to land, so a restart doesn't drop them for a moment.
const _firstSync = Duration(seconds: 10);

/// Runs the helper: its error, or '' when it worked.
typedef ServeHelper = Future<String> Function(List<String> args);

Future<String> _runHelper(String helper, List<String> args) async {
  try {
    final r = await Process.run(helper, args).timeout(const Duration(seconds: 60));
    if (r.exitCode == 0) return '';
    final err = '${r.stderr}'.trim();
    return err.isNotEmpty ? err : 'exited with ${r.exitCode}';
  } on TimeoutException {
    return 'timed out';
  } catch (e) {
    return '$e';
  }
}

class Tailnet {
  /// [host]: e.g. agent-office.tail1234.ts.net, or null when the office isn't on a tailnet.
  Tailnet(this.host, {String? helper, ServeHelper? run}) : _helper = helper ?? _defaultHelper(), _run = run;

  final String? host;
  final String _helper;
  final ServeHelper? _run;

  /// The ports Serve points at the office, as last set; null until the first sync.
  String? _served;
  List<int> _wanted = [];
  bool _busy = false;
  String _lastError = '';
  Timer? _timer;

  /// Once the workers' servers are known, drop ports a previous office left behind.
  void start(List<int> Function() ports) {
    if (host == null) return;
    _timer = Timer(_firstSync, () => sync(ports()));
  }

  void stop() => _timer?.cancel();

  /// Serve exactly these workers' ports on the tailnet, and stop serving any others.
  void sync(Iterable<int> ports) {
    if (host == null || (_run == null && !File(_helper).existsSync())) return;
    _wanted = ports.toSet().toList()..sort();
    unawaited(_flush());
  }

  /// Done once what's wanted is served (or failed); for tests.
  Future<void> get idle async {
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> _flush() async {
    if (_busy) return;
    _busy = true;
    try {
      // The list can change while the helper runs (each Serve change takes a moment).
      while (_wanted.join(' ') != _served) {
        final want = _wanted.join(' ');
        final args = ['sync', for (final p in _wanted) '$p'];
        final err = await (_run ?? (a) => _runHelper(_helper, a))(args);
        if (err.isNotEmpty) {
          if (err != _lastError) stderr.writeln("[agent-office] couldn't serve workers' servers on the tailnet: $err");
          _lastError = err;
          break; // the next change tries again
        }
        _lastError = '';
        _served = want;
      }
    } finally {
      _busy = false;
    }
  }
}
