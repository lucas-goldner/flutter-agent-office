import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:office_shared/shared.dart';
import 'package:relic/relic.dart';

import 'auth.dart';

// Service tunnels: `ssh -L 5173:localhost:4600 office@box` lands on the office's own port, and the
// browser's Host header (localhost:5173) says which worker server it's for. So teammates reach
// every service through the one port their SSH key may already forward to, and only while
// signed in to the office.

/// Set on everything the office relays, so a server that proxies back to the office can't loop.
const _relayed = 'x-agent-office-relay';
final _loopbackHost = RegExp(
  r'^(?:localhost|127\.0\.0\.1|\[::1\]|[a-z0-9-]+\.localhost):(\d{1,5})$',
  caseSensitive: false,
);

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

/// The service port a request came in for, when it came through a service tunnel.
int? tunneledPort(Map<String, Iterable<String>> headers, int officePort) {
  if (headers[_relayed]?.isNotEmpty ?? false) return null;
  final m = _loopbackHost.firstMatch(headerValue(headers, 'host') ?? '');
  final port = m != null ? int.parse(m[1]!) : 0;
  return port != 0 && port != officePort ? port : null;
}

/// The request's headers as the worker's server gets them: marked as relayed, without the
/// office's own session cookies.
Map<String, List<String>> _upstreamHeaders(Map<String, Iterable<String>> headers) {
  final out = <String, List<String>>{};
  headers.forEach((k, v) => out[k.toLowerCase()] = v.toList());
  out[_relayed] = ['1'];
  final cookie = withoutOfficeCookies(headerValue(headers, 'cookie', '; '));
  if (cookie != null) {
    out['cookie'] = [cookie];
  } else {
    out.remove('cookie');
  }
  return out;
}

String _pathAndQuery(Uri url) {
  final path = url.path.isEmpty ? '/' : url.path;
  return url.hasQuery ? '$path?${url.query}' : path;
}

/// Relays a request to the worker's server and streams its answer back. A server that doesn't
/// answer gets the office's "Not answering" page instead.
Future<Response> relayRequest(Request req, ServiceInfo svc) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final up = await client.open(req.method.value, svc.host, svc.port, _pathAndQuery(req.url));
    up.followRedirects = false;
    up.persistentConnection = false;
    final headers = _upstreamHeaders(req.headers);
    for (final e in headers.entries) {
      if (_hopByHop.contains(e.key)) continue;
      up.headers.set(e.key, e.value, preserveHeaderCase: false);
    }
    final length = req.body.contentLength;
    if (length != null) up.contentLength = length;
    await up.addStream(req.body.read());
    final ur = await up.close();
    final out = Headers.build((h) {
      ur.headers.forEach((k, v) {
        if (_hopByHop.contains(k) || k == 'content-type') return;
        h[k] = v;
      });
    });
    // relic sets Content-Type from the body, so the upstream one travels as the body's type.
    MimeType? mime;
    Encoding? encoding;
    final ct = ur.headers.contentType;
    if (ct != null) {
      mime = MimeType(ct.primaryType, ct.subType);
      encoding = ct.charset != null ? Encoding.getByName(ct.charset) : null;
    }
    final body = Body.fromDataStream(
      ur.map((c) => c is Uint8List ? c : Uint8List.fromList(c)).transform(_closeWhenDone(client)),
      mimeType: mime,
      encoding: encoding,
      contentLength: ur.contentLength >= 0 && !_noBody(req.method.value, ur.statusCode) ? ur.contentLength : null,
    );
    return Response(ur.statusCode, headers: out, body: _noBody(req.method.value, ur.statusCode) ? Body.empty() : body);
  } catch (_) {
    client.close(force: true);
    return _page(
      502,
      'Not answering',
      "The server on port ${svc.port} (<code>${_esc(svc.command)}</code>) didn't answer. It may be restarting — try again in a moment.",
    );
  }
}

bool _noBody(String method, int status) =>
    method == 'HEAD' || status == 204 || status == 304 || (status >= 100 && status < 200);

StreamTransformer<Uint8List, Uint8List> _closeWhenDone(HttpClient client) => StreamTransformer.fromHandlers(
  handleDone: (sink) {
    client.close();
    sink.close();
  },
);

/// WebSockets (hot reload and the like): replay the handshake upstream, then splice the sockets.
Hijack relayUpgrade(Request req, ServiceInfo svc) {
  final lines = ['${req.method.value} ${_pathAndQuery(req.url)} HTTP/1.1'];
  for (final e in _upstreamHeaders(req.headers).entries) {
    for (final one in e.value) {
      lines.add('${e.key}: $one');
    }
  }
  return Hijack((channel) async {
    Socket up;
    StreamSubscription<List<int>>? down;
    try {
      up = await Socket.connect(svc.host, svc.port);
    } catch (_) {
      await channel.sink.close();
      return;
    }
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      up.destroy();
      down?.cancel();
      channel.sink.close().catchError((_) {});
    }

    up.add(utf8.encode('${lines.join('\r\n')}\r\n\r\n'));
    // Whatever the browser sent after its handshake is still unread on the hijacked socket, so it
    // follows here like the rest.
    down = channel.stream.listen(up.add, onError: (_) => close(), onDone: close, cancelOnError: true);
    up.listen(channel.sink.add, onError: (_) => close(), onDone: close, cancelOnError: true);
    up.done.catchError((_) => close());
  });
}

String _esc(String s) => s.replaceAllMapped(RegExp('[&<>"\']'), (m) => '&#${m[0]!.codeUnitAt(0)};');

const _style =
    '''body{margin:0;min-height:100vh;display:grid;place-items:center;background:#bfe3ff;font:16px/1.5 Nunito,ui-rounded,system-ui,sans-serif;color:#2b2d42}
main{background:#fffaf3;border:3px solid #2b2d42;border-radius:18px;box-shadow:0 6px 0 #2b2d42;padding:28px 32px;max-width:440px;margin:16px}
h1{margin:0 0 8px;font-size:22px}p{margin:0 0 14px}code{background:#f1e7d8;border-radius:6px;padding:1px 5px}
form{display:flex;flex-wrap:wrap;gap:8px}input{flex:1;min-width:0;font:inherit;padding:8px 12px;border:2px solid #2b2d42;border-radius:10px}
button{font:inherit;font-weight:800;padding:8px 16px;border:2px solid #2b2d42;border-radius:10px;background:#ffd166;cursor:pointer}
.err{color:#c1121f;font-weight:700;min-height:1.5em;margin:10px 0 0}''';

Response _page(int status, String title, String body, [String script = '']) {
  final html =
      '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" '
      'content="width=device-width,initial-scale=1"><title>${_esc(title)} · Agent Office</title>'
      '<style>$_style</style></head><body><main><h1>${_esc(title)}</h1>$body</main>'
      '${script.isNotEmpty ? '<script>$script</script>' : ''}</body></html>';
  return Response(
    status,
    headers: Headers.build((h) {
      h['cache-control'] = ['no-store'];
      h['content-security-policy'] = [
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'",
      ];
      h['x-frame-options'] = ['DENY'];
    }),
    body: Body.fromString(html, mimeType: MimeType.html),
  );
}

/// Where the sign-in form below posts; the office answers it on service tunnels only.
const relayLogin = '/__agent-office/login';

/// [accounts] and [shared] say which fields to ask for: a name when there are accounts, a password always.
Response signInPage(int port, {required bool accounts, required bool shared}) {
  final askName = accounts || !shared;
  final how = !askName
      ? 'the office password'
      : shared
      ? 'your name and password (or just the office password)'
      : 'your name and password';
  final nameInput = askName
      ? '<input id="name" placeholder="${shared ? 'Your name (optional)' : 'Your name'}" '
            'autocomplete="username"${shared ? '' : ' required'} autofocus>'
      : '';
  return _page(
    401,
    '🔒 Sign in to the office',
    '''<p>This is a worker's server on port $port, reached through the office. Sign in with $how to see it.</p>
<form id="f">$nameInput<input id="pw" type="password" placeholder="${askName ? 'Password' : 'Office password'}" autocomplete="current-password"${askName ? '' : ' autofocus'}><button>Sign in</button></form><p class="err" id="err"></p>''',
    '''document.getElementById('f').addEventListener('submit',async(e)=>{e.preventDefault();const err=document.getElementById('err');err.textContent='';const n=document.getElementById('name');
try{const r=await fetch(${jsonEncode(relayLogin)},{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:n?n.value:'',password:document.getElementById('pw').value})});
if(r.ok)location.reload();else err.textContent=(await r.json().catch(()=>({}))).error||'Sign-in failed'}catch{err.textContent='Could not reach the office'}})''',
  );
}

Response stoppedPage(int port) => _page(
  503,
  '💤 Not running',
  '<p>Nothing is serving port $port right now. The worker may have stopped its server — check the 🌐 Services board '
      'in the office, or ask the worker to start it again.</p>',
);
