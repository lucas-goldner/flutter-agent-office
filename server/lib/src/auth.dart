import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import 'accounts.dart';
import 'secrets.dart';

// Works on plain header maps (relic's `Headers` is one: a case-insensitive
// Map<String, Iterable<String>>), so it stays framework-free and testable. With a plain map, use
// lowercase header names.

const cookieNameBase = 'ao_session';
const _sessionTtlMs = 1000 * 60 * 60 * 24 * 14;

const _maxAttempts = 10;
const _windowMs = 5 * 60000;

/// A signed-in browser: with its own account, or (no account) with the shared office password.
class Session {
  const Session([this.account]);
  final Account? account;
}

class _Attempts {
  _Attempts(this.count, this.resetAt);
  int count;
  final int resetAt;
}

/// One header's value, several of a kind joined the way a proxy would fold them.
String? headerValue(Map<String, Iterable<String>> headers, String name, [String join = ', ']) {
  final v = headers[name];
  if (v == null || v.isEmpty) return null;
  return v.join(join);
}

class Auth {
  /// [now] is the clock, for tests.
  Auth(Uint8List verifier, this._salt, String secret, this._accounts, {int Function()? now})
    : _verifier = verifier,
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
      _key = Uint8List.fromList(
        Hmac(sha256, utf8.encode(secret)).convert([...utf8.encode('session:'), ...verifier]).bytes,
      ),
      _accountKey = Uint8List.fromList(
        Hmac(sha256, utf8.encode(secret)).convert(utf8.encode('account-session:')).bytes,
      );

  final Uint8List _verifier;
  final Uint8List _salt;
  final Accounts _accounts;
  final int Function() _now;
  final Map<String, _Attempts> _attempts = {};

  /// Signs shared-password sessions. Derived from the password too, so changing it logs those out.
  final Uint8List _key;

  /// Signs account sessions, which outlive a change of the shared password.
  final Uint8List _accountKey;

  /// scrypt runs on another isolate, so guessing can't stall the event loop.
  Future<bool> checkPassword(String candidate) async {
    try {
      return timingSafeEqual(await scrypt(candidate, _salt, 32), _verifier);
    } catch (_) {
      return false;
    }
  }

  bool checkToken(String candidate, String expected) {
    final a = Hmac(sha256, _key).convert(utf8.encode(candidate)).bytes;
    final b = Hmac(sha256, _key).convert(utf8.encode(expected)).bytes;
    return timingSafeEqual(a, b);
  }

  /// Counts a login attempt; returns false once this client has used up its window.
  bool allowAttempt(String ip) {
    final now = _now();
    if (_attempts.length > 10000) _attempts.removeWhere((_, v) => v.resetAt < now);
    final rec = _attempts[ip];
    if (rec == null || rec.resetAt < now) {
      _attempts[ip] = _Attempts(1, now + _windowMs);
      return true;
    }
    rec.count++;
    return rec.count <= _maxAttempts;
  }

  void recordSuccess(String ip) => _attempts.remove(ip);

  /// A session cookie's value: for that account, or for the shared password when there's none.
  String issue([String? accountId]) {
    final account = accountId != null && accountId.isNotEmpty;
    final body = {'exp': _now() + _sessionTtlMs, 'n': toHex(randomBytes(8)), if (account) 'u': accountId};
    final payload = base64UrlNoPad(utf8.encode(jsonEncode(body)));
    return '$payload.${_sign(payload, account)}';
  }

  /// Who a cookie signs in, if anyone. A revoked account, or the shared password once it's switched
  /// off, stops working at once, whatever the cookie's expiry says.
  Session? verify(String? token) {
    if (token == null || token.isEmpty) return null;
    final dot = token.indexOf('.');
    if (dot < 1) return null;
    final payload = token.substring(0, dot);
    Object? body;
    try {
      final raw = decodeBase64Url(payload);
      if (raw == null) return null;
      body = jsonDecode(utf8.decode(raw, allowMalformed: true));
    } catch (_) {
      return null;
    }
    if (body is! Map) return null;
    final u = body['u'];
    final accountId = u is String && u.isNotEmpty ? u : null;
    final sig = utf8.encode(token.substring(dot + 1));
    final expected = utf8.encode(_sign(payload, accountId != null));
    if (!timingSafeEqual(sig, expected)) return null;
    final exp = body['exp'];
    if (exp is! num || exp <= _now()) return null;
    if (accountId == null) return _accounts.sharedPassword ? const Session() : null;
    final account = _accounts.get(accountId);
    return account != null ? Session(account) : null;
  }

  /// The session of a request with these headers (its Cookie and Host).
  Session? fromRequest(Map<String, Iterable<String>> headers) =>
      verify(parseCookies(headerValue(headers, 'cookie', '; '))[cookieName(headerValue(headers, 'host'))]);

  /// Signed in to this office on any port of this host. A service tunnel (localhost:5173) carries
  /// the cookie you got on the office's own tunnel (localhost:4600), since cookies ignore ports.
  bool fromAnyCookie(Map<String, Iterable<String>> headers) {
    for (final e in parseCookies(headerValue(headers, 'cookie', '; ')).entries) {
      if (_officeCookie.hasMatch(e.key) && verify(e.value) != null) return true;
    }
    return false;
  }

  /// The Set-Cookie value for a session on the office this request came to.
  String cookie(Map<String, Iterable<String>> headers, String token, bool secure) =>
      '${cookieName(headerValue(headers, 'host'))}=$token; Path=/; HttpOnly; SameSite=Lax; '
      'Max-Age=${_sessionTtlMs ~/ 1000}${secure ? '; Secure' : ''}';

  String clearCookie(Map<String, Iterable<String>> headers) =>
      '${cookieName(headerValue(headers, 'host'))}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0';

  String _sign(String payload, bool account) =>
      base64UrlNoPad(Hmac(sha256, account ? _accountKey : _key).convert(utf8.encode(payload)).bytes);
}

final _hostPort = RegExp(r':(\d+)$');

/// Cookies ignore ports, so offices sharing a host (e.g. SSH tunnels on localhost:4600 and :4601)
/// each get their own. [host] is the request's Host header.
String cookieName(String? host) {
  final port = _hostPort.firstMatch(host ?? '')?.group(1);
  return port != null ? '${cookieNameBase}_$port' : cookieNameBase;
}

final _officeCookie = RegExp('^$cookieNameBase(?:_\\d+)?\$');

/// The Cookie header without the office's session cookies, for passing on to someone else's server.
String? withoutOfficeCookies(String? header) {
  if (header == null || header.isEmpty) return header;
  final kept = header
      .split(';')
      .where((part) => !_officeCookie.hasMatch(part.split('=').first.trim()))
      .join(';')
      .trim();
  return kept.isEmpty ? null : kept;
}

Map<String, String> parseCookies(String? header) {
  final out = <String, String>{};
  if (header == null || header.isEmpty) return out;
  for (final part in header.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    final raw = part.substring(i + 1).trim();
    final name = part.substring(0, i).trim();
    try {
      out[name] = Uri.decodeComponent(raw);
    } catch (_) {
      out[name] = raw; // someone else's malformed cookie must not take us down
    }
  }
  return out;
}
