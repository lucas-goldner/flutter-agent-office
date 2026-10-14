import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'office.dart';
import 'wire.dart';

// The listening half of `agent-office tunnel`: for every web server a worker runs, the same port
// on this computer. What arrives there goes to the office with this client's session and the port
// it's for, and the office relays it to the worker's server (relay.dart), WebSockets included. So
// http://localhost:5173 here is the worker's localhost:5173, for a browser, curl or anything else.
// Ported from src/server/tunnel/forwarder.ts.

/// Both of this computer's own addresses, as `ssh -L` listens on: a browser may try either for "localhost".
final _addresses = [InternetAddress.loopbackIPv4, InternetAddress.loopbackIPv6];

/// How long a port stays open once its server is off the office's list. A dev server restarting, or
/// the office missing it for one look on a busy machine, isn't the worker stopping it; meanwhile the
/// office answers for it with its "not running" page.
const lingerMs = 10000;

/// Headers about one hop of the connection, which the HTTP client and server set themselves.
const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-connection',
  'transfer-encoding',
  'te',
  'trailer',
  'upgrade',
  'content-length',
};

/// Why a port can't be opened on this computer: something here has it, or only root may open it.
enum PortBusy { taken, denied }

/// What the client says as ports open and close.
class ForwardEvents {
  const ForwardEvents({required this.opened, required this.closed, required this.busy});

  /// `localhost:<port>` now reaches the worker's server.
  final void Function(Forward f) opened;

  /// The worker's server stopped, and so did `localhost:<port>`.
  final void Function(Forward f) closed;

  /// The port can't be opened here. It's tried again on every sync.
  final void Function(Forward f, PortBusy why) busy;
}

class _Open {
  _Open(this.forward, this.servers);
  Forward forward;
  final List<HttpServer> servers;

  /// When the office's list stopped having it, while it doesn't.
  int? goneAt;
}

/// Whether something on this computer answers on the port, on either address.
Future<bool> _taken(int port) async {
  Future<bool> answers(InternetAddress host) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 1));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  return (await Future.wait(_addresses.map(answers))).any((b) => b);
}

bool _inUse(SocketException e) => const {98, 48, 10048}.contains(e.osError?.errorCode);
bool _denied(SocketException e) => const {13, 10013}.contains(e.osError?.errorCode);

class Forwarder {
  /// [skip]: ports never to listen on (the one the office itself is reached on). [linger]: see [lingerMs].
  Forwarder(this._office, this._events, {Set<int> skip = const {}, int linger = lingerMs})
    : _skip = skip,
      _linger = linger;

  final TunnelOffice _office;
  final ForwardEvents _events;
  final Set<int> _skip;
  final int _linger;
  final _open = <int, _Open>{};

  /// Ports that can't be opened on this computer, already said so.
  final _busy = <int>{};
  bool _closed = false;

  /// The ports open right now.
  List<int> ports() => _open.keys.toList()..sort();

  /// Listens on exactly these servers' ports: opens the new ones, closes the ones that stopped a while ago.
  Future<void> sync(List<Forward> items, [int? now]) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    final wanted = {
      for (final f in items)
        if (!_skip.contains(f.port)) f.port: f,
    };
    for (final port in _open.keys.toList()) {
      final o = _open[port]!;
      if (wanted.containsKey(port)) {
        o.goneAt = null;
        continue;
      }
      o.goneAt ??= now;
      if (now - o.goneAt! < _linger) continue;
      await _shut(o);
      _open.remove(port);
      _events.closed(o.forward);
    }
    _busy.removeWhere((port) => !wanted.containsKey(port));
    for (final MapEntry(key: port, value: forward) in wanted.entries) {
      final cur = _open[port];
      if (cur != null) {
        cur.forward = forward;
        continue;
      }
      final servers = await _listen(port);
      if (servers is PortBusy) {
        if (!_busy.contains(port)) _events.busy(forward, servers);
        _busy.add(port);
        continue;
      }
      servers as List<HttpServer>;
      if (_closed) {
        for (final s in servers) {
          await s.close(force: true);
        }
        return;
      }
      _busy.remove(port);
      _open[port] = _Open(forward, servers);
      _events.opened(forward);
    }
  }

  Future<void> close() async {
    _closed = true;
    final all = _open.values.toList();
    _open.clear();
    for (final o in all) {
      await _shut(o);
    }
  }

  Future<void> _shut(_Open o) async {
    for (final s in o.servers) {
      await s.close(force: true);
    }
  }

  /// Servers listening on the port, or why it can't be opened on this computer.
  Future<Object> _listen(int port) async {
    // Asked first: a port taken on every address (0.0.0.0) can still be bound on one of them, and
    // then whatever was there stops getting its own visitors.
    if (await _taken(port)) return PortBusy.taken;
    final servers = <HttpServer>[];
    for (final host in _addresses) {
      try {
        final server = await HttpServer.bind(host, port, v6Only: host.type == InternetAddressType.IPv6);
        server
          ..autoCompress = false
          ..idleTimeout = const Duration(seconds: 120)
          ..defaultResponseHeaders.clear();
        server.listen((req) => _relay(port, req), onError: (_) {});
        servers.add(server);
      } on SocketException catch (e) {
        // A computer without IPv6 has no ::1 to listen on, which is fine. Anything else: not ours.
        if (_inUse(e) || _denied(e) || host == _addresses.first) {
          for (final s in servers) {
            await s.close(force: true);
          }
          return _denied(e) ? PortBusy.denied : PortBusy.taken;
        }
      }
    }
    return servers;
  }

  /// What the office gets: the request as it came, plus this client's session and the port. Only a
  /// name for this computer is let through as the Host, so a page elsewhere can't point a name of
  /// its own at the port and read a worker's server through it.
  Map<String, List<String>>? _headers(int port, HttpRequest req) {
    final host = req.headers.value('host') ?? '';
    if (!loopbackName.hasMatch(host)) return null;
    final out = <String, List<String>>{};
    req.headers.forEach((k, v) => out[k.toLowerCase()] = v);
    out[serviceHeader] = ['$port'];
    final theirs = req.headers['cookie']?.join('; ');
    out['cookie'] = [_office.cookie(theirs)];
    // An office at an address of its own is asked for by that name; it gives the worker's server
    // localhost:<port> again. Through an SSH tunnel the Host stays what the browser sent.
    out['host'] = [_office.local ? host : _office.host];
    return out;
  }

  Future<void> _relay(int port, HttpRequest req) async {
    final res = req.response;
    final headers = _headers(port, req);
    if (headers == null) {
      return _refuse(
        res,
        421,
        'This is localhost:$port, forwarded by agent-office tunnel. Open it as http://localhost:$port.',
      );
    }
    final upgrade =
        (req.headers.value('upgrade') ?? '').isNotEmpty &&
        (req.headers['connection'] ?? const []).any((v) => v.toLowerCase().contains('upgrade'));
    if (upgrade) return _upgrade(req, headers);
    HttpClientResponse ur;
    try {
      final up = await _office.request(req.method, req.uri.toString());
      up.followRedirects = false;
      up.persistentConnection = true;
      for (final e in headers.entries) {
        if (_hopByHop.contains(e.key)) continue;
        up.headers.set(e.key, e.value, preserveHeaderCase: false);
      }
      if (req.contentLength >= 0) {
        up.contentLength = req.contentLength;
      } else if (req.headers.chunkedTransferEncoding) {
        up.headers.chunkedTransferEncoding = true;
      } else {
        up.contentLength = 0;
      }
      await up.addStream(req);
      ur = await up.close();
    } catch (_) {
      return _refuse(
        res,
        502,
        "agent-office tunnel couldn't reach the office at ${_office.origin}. It keeps trying — reload in a moment.",
      );
    }
    try {
      res.statusCode = ur.statusCode;
      res.reasonPhrase = ur.reasonPhrase;
      ur.headers.forEach((k, v) {
        if (_hopByHop.contains(k)) return;
        for (final one in v) {
          res.headers.add(k, one, preserveHeaderCase: false);
        }
      });
      if (ur.contentLength >= 0) {
        res.contentLength = ur.contentLength;
      } else {
        res.headers.chunkedTransferEncoding = true;
      }
      await res.addStream(ur);
      await res.close();
    } catch (_) {
      // Cut off halfway (the tunnel dropped): the browser hears so, instead of waiting for the rest.
      try {
        (await res.detachSocket(writeHeaders: false)).destroy();
      } catch (_) {
        // already gone
      }
    }
  }

  /// WebSockets (hot reload and the like): replay the handshake to the office, then splice the sockets.
  Future<void> _upgrade(HttpRequest req, Map<String, List<String>> headers) async {
    final lines = ['${req.method} ${req.uri} HTTP/1.1'];
    for (final e in headers.entries) {
      for (final one in e.value) {
        lines.add('${e.key}: $one');
      }
    }
    Socket up;
    try {
      up = await _office.connect();
    } catch (_) {
      return _refuse(req.response, 502, "agent-office tunnel couldn't reach the office at ${_office.origin}.");
    }
    final socket = await req.response.detachSocket(writeHeaders: false);
    var done = false;
    void close() {
      if (done) return;
      done = true;
      up.destroy();
      socket.destroy();
    }

    up.add(utf8.encode('${lines.join('\r\n')}\r\n\r\n'));
    socket.listen(up.add, onError: (_) => close(), onDone: close, cancelOnError: true);
    up.listen(socket.add, onError: (_) => close(), onDone: close, cancelOnError: true);
    unawaited(up.done.catchError((_) => close()));
    unawaited(socket.done.catchError((_) => close()));
  }
}

Future<void> _refuse(HttpResponse res, int status, String text) async {
  try {
    res.statusCode = status;
    res.headers.set('content-type', 'text/plain; charset=utf-8');
    res.headers.set('cache-control', 'no-store');
    res.write('$text\n');
    await res.close();
  } catch (_) {
    // the browser went away
  }
}
