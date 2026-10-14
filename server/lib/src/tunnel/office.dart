import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth.dart' show cookieNameBase;
import 'wire.dart';

// The office as `agent-office tunnel` reaches it: through an SSH tunnel on localhost, or at its own
// address. Ported from src/server/tunnel/office.ts.

const _timeout = Duration(seconds: 10);

class _Answer {
  _Answer(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final String body;
}

/// What [TunnelOffice.forwards] says when it doesn't have the list.
enum ForwardsRefused {
  /// The session isn't good (any more).
  signedOut,

  /// The office is a version from before it could say.
  old,
}

class TunnelOffice {
  /// [insecure]: take a certificate nobody vouches for (an office started with --self-signed).
  TunnelOffice(Uri url, {this.insecure = false})
    : secure = url.scheme == 'https',
      hostname = url.host.replaceAll(RegExp(r'^\[|\]$'), ''),
      port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80),
      origin = url.origin,
      host = url.hasPort ? '${_bracket(url.host)}:${url.port}' : _bracket(url.host),
      local = loopbackName.hasMatch(_bracket(url.host)) {
    _client = HttpClient()
      ..autoUncompress = false
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 64;
    if (insecure) _client.badCertificateCallback = (_, _, _) => true;
  }

  static String _bracket(String h) => h.contains(':') && !h.startsWith('[') ? '[$h]' : h;

  final bool secure;
  final bool insecure;
  final String hostname;
  final int port;

  /// Its address as a browser has it, e.g. http://localhost:4600.
  final String origin;

  /// The Host the office expects from someone who came to it by that address.
  final String host;

  /// Whether that's this computer's own address (an SSH tunnel, or an office running here).
  final bool local;

  /// One set of connections for everything sent to the office, kept open between requests.
  late final HttpClient _client;

  /// The session this client is signed in with ('' until it is).
  String token = '';

  /// The Cookie header that signs a request in, after whatever cookies [theirs] already has. The
  /// office names its cookie after its port when the Host has one, so both names go along.
  String cookie([String? theirs]) {
    final mine = '$cookieNameBase=$token; ${cookieNameBase}_$port=$token';
    return theirs != null && theirs.isNotEmpty ? '$theirs; $mine' : mine;
  }

  /// A request to the office, to be filled in and closed by the caller.
  Future<HttpClientRequest> request(String method, String pathAndQuery) =>
      _client.openUrl(method, Uri.parse('$origin$pathAndQuery'));

  /// A raw connection to the office, for a WebSocket.
  Future<Socket> connect() {
    if (!secure) return Socket.connect(hostname, port);
    return SecureSocket.connect(
      hostname,
      port,
      supportedProtocols: const ['http/1.1'],
      onBadCertificate: insecure ? (_) => true : null,
    );
  }

  void close() => _client.close(force: true);

  Future<_Answer> _call(String method, String path, [Object? body]) async {
    return () async {
      final req = await request(method, path);
      req.followRedirects = false;
      req.headers.set('accept', 'application/json');
      if (token.isNotEmpty) req.headers.set('cookie', cookie());
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return _Answer(res.statusCode, res.headers, text);
    }().timeout(_timeout, onTimeout: () => throw TimeoutException('timed out'));
  }

  /// Whether an office answers there.
  Future<bool> up() async {
    try {
      final r = await _call('GET', '/api/health');
      final j = _parse(r.body);
      return r.status == 200 && j is Map && j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Which fields its sign-in asks for: a name when there are accounts, the shared password while it's on.
  Future<({bool accounts, bool shared})> loginOptions() async {
    final o = _parse((await _call('GET', '/api/login')).body);
    return (accounts: o is Map && o['accounts'] == true, shared: !(o is Map && o['shared'] == false));
  }

  /// Signs in; why it didn't work, or '' when it did (and [token] is set).
  Future<String> signIn(String name, String password) async {
    final r = await _call('POST', '/api/login', {'name': name, 'password': password});
    if (r.status != 200) {
      final j = _parse(r.body);
      final err = j is Map ? j['error'] : null;
      return err is String && err.isNotEmpty ? err : 'Sign-in failed (${r.status})';
    }
    final mine = RegExp('^$cookieNameBase(?:_\\d+)?=([^;]+)');
    for (final c in r.headers['set-cookie'] ?? const <String>[]) {
      final m = mine.firstMatch(c);
      if (m != null) {
        token = Uri.decodeComponent(m[1]!);
        return '';
      }
    }
    return "The office didn't answer with a session";
  }

  /// The workers' web servers: a [ForwardList], or a [ForwardsRefused]. Throws when it can't be reached.
  Future<Object> forwards() async {
    final r = await _call('GET', forwardsPath);
    if (r.status == 401 || r.status == 302) return ForwardsRefused.signedOut;
    final list = r.status == 200 ? _parse(r.body) : null;
    final items = list is Map ? list['items'] : null;
    if (items is! List) {
      if (r.status == 200 || r.status == 404) return ForwardsRefused.old;
      throw HttpException('the office answered ${r.status}');
    }
    final port = (list as Map)['port'];
    return ForwardList(
      port: port is num && port.isFinite ? port.toInt() : 0,
      items: [for (final f in items.map(Forward.fromJson)) ?f],
    );
  }
}

Object? _parse(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}
