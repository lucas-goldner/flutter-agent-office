// What `agent-office tunnel` and the office say to each other: the client asks which web servers
// the workers are running (GET /api/services), listens on each one's port on its own computer, and
// sends what arrives there to the office, which relays it to that server (relay.dart).
// Ported from src/server/tunnel/wire.ts.

/// Where the client asks for the list.
const forwardsPath = '/api/services';

/// Names the worker's server a request is for. The client reaches the office at whatever address
/// the office has (an SSH tunnel, a domain, a tailnet), where the Host header can't always say.
const serviceHeader = 'x-agent-office-service';

/// A worker's web server, as the client shows it in its terminal.
class Forward {
  const Forward({required this.port, required this.title, required this.command, this.worker, this.floor});

  /// Null when [j] isn't one (a port out of range, say).
  static Forward? fromJson(Object? j) {
    if (j is! Map) return null;
    final port = j['port'];
    if (port is! num || port != port.truncate() || port <= 0 || port >= 65536) return null;
    String str(Object? v) => v is String ? v : '';
    String? opt(Object? v) => v is String ? v : null;
    return Forward(
      port: port.toInt(),
      title: str(j['title']),
      command: str(j['command']),
      worker: opt(j['worker']),
      floor: opt(j['floor']),
    );
  }

  final int port;

  /// Its page's <title>, or its command line when it has none.
  final String title;

  /// Its command line, shortened, e.g. "vite --port 5173".
  final String command;

  /// The worker who started it.
  final String? worker;

  /// The floor that worker is on.
  final String? floor;

  Map<String, Object?> toJson() => {
    'port': port,
    'title': title,
    'command': command,
    'worker': ?worker,
    'floor': ?floor,
  };
}

class ForwardList {
  const ForwardList({required this.port, required this.items});

  /// The office's own port on its machine.
  final int port;
  final List<Forward> items;

  Map<String, Object?> toJson() => {
    'port': port,
    'items': [for (final f in items) f.toJson()],
  };
}

/// A Host a browser on this computer would send: localhost, 127.0.0.1, [::1] or `<name>.localhost`,
/// with or without a port.
final loopbackName = RegExp(
  r'^(?:localhost|127\.0\.0\.1|\[::1\]|[a-z0-9-]+\.localhost)(?::\d{1,5})?$',
  caseSensitive: false,
);
