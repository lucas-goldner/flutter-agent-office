import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

final Random _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A placement or patch as a JSON map, whether it came as one or as its wire type.
Object? _asJson(Object? x) => switch (x) {
  DecorPlacement d => d.toJson(),
  DecorPatch d => d.toJson(),
  _ => x,
};

/// The pictures on the office walls, saved in .agent-office/decor.json.
class Decor {
  Decor(String dataDir) : _file = p.join(dataDir, 'decor.json') {
    _load();
  }

  final List<Decoration> _items = [];
  final String _file;

  List<Decoration> list() => _items;

  /// Hangs a picture ([input] is a placement, as a map or a [DecorPlacement]), or says why it can't.
  ({Decoration? decoration, String? error}) add(Object? input, String by) {
    if (_items.length >= maxDecor) {
      return (decoration: null, error: 'The walls are full ($maxDecor pictures). Take one down first.');
    }
    final s = sanitizePlacement(_asJson(input));
    final pl = s.placement;
    if (pl == null) return (decoration: null, error: s.error);
    final d = _decoration(pl, _randomHex(5), by, _now());
    _items.add(d);
    _save();
    return (decoration: d, error: null);
  }

  /// Changes any part of a picture's placement; what the patch leaves out stays as it was.
  ({Decoration? decoration, String? error}) update(String id, Object? patch) {
    final i = _items.indexWhere((d) => d.id == id);
    if (i < 0) return (decoration: null, error: 'Someone already took that picture down');
    final had = _items[i];
    final placement = had.toJson()
      ..remove('id')
      ..remove('by')
      ..remove('at');
    final changes = _asJson(patch);
    final s = sanitizePlacement({...placement, if (changes is Map) ...changes});
    final pl = s.placement;
    if (pl == null) return (decoration: null, error: s.error);
    _items[i] = _decoration(pl, id, had.by, had.at);
    _save();
    return (decoration: _items[i], error: null);
  }

  Decoration? remove(String id) {
    final i = _items.indexWhere((d) => d.id == id);
    if (i < 0) return null;
    final d = _items.removeAt(i);
    _save();
    return d;
  }

  void _load() {
    final file = File(_file);
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      for (final s in saved is List ? saved : const []) {
        final pl = sanitizePlacement(s).placement;
        if (pl == null || s is! Map || s['id'] is! String) continue;
        final by = s['by'];
        final at = s['at'];
        _items.add(_decoration(pl, s['id'] as String, by is String ? by : '?', at is num ? at.toInt() : _now()));
      }
    } catch (_) {
      // a broken file just means bare walls
    }
  }

  void _save() {
    try {
      _writePrivate(_file, const JsonEncoder.withIndent('  ').convert([for (final d in _items) d.toJson()]));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

Decoration _decoration(DecorPlacement pl, String id, String by, int at) => Decoration(
  id: id,
  by: by,
  at: at,
  url: pl.url,
  title: pl.title,
  wall: pl.wall,
  u: pl.u,
  y: pl.y,
  w: pl.w,
  h: pl.h,
  frame: pl.frame,
);

/// Writes [text] to [file] readable by this user only: to `<file>.tmp` first, then moved into place.
void _writePrivate(String file, String text) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', tmp]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  File(tmp).renameSync(file);
}

// ---- Image proxy ------------------------------------------------------------------------------
// Browsers only let WebGL draw an image from another site when that site sends CORS headers, and
// most don't. So the office fetches pictures itself and serves them from its own origin. It only
// does this for signed-in people, who can already run any command on this machine from a shell
// worker, so fetching a link for them gives them nothing new.

/// A picture the proxy fetched, or why it couldn't.
sealed class ImageResult {
  const ImageResult();
}

class ImageData extends ImageResult {
  const ImageData(this.type, this.body);

  /// Its media type, like image/png.
  final String type;
  final Uint8List body;
}

class ImageError extends ImageResult {
  const ImageError(this.status, this.error);

  /// The HTTP status to answer with.
  final int status;
  final String error;
}

class _Cached extends ImageData {
  _Cached(super.type, super.body, this.at);
  final int at;
}

const int _maxImageBytes = 15 * 1024 * 1024;
const int _cacheBytes = 96 * 1024 * 1024;
const int _cacheMs = 30 * 60000;
const Duration _timeout = Duration(milliseconds: 12000);

/// Recognizes common image formats from their first bytes, for hosts that don't say.
String? _sniff(Uint8List b) {
  bool at(int i, String s) {
    if (b.length < i + s.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (b[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  int byte(int i) => i < b.length ? b[i] : -1;
  if (at(0, '\x89PNG')) return 'image/png';
  if (byte(0) == 0xff && byte(1) == 0xd8 && byte(2) == 0xff) return 'image/jpeg';
  if (at(0, 'GIF8')) return 'image/gif';
  if (at(0, 'RIFF') && at(8, 'WEBP')) return 'image/webp';
  if (at(4, 'ftypavif') || at(4, 'ftypavis')) return 'image/avif';
  if (at(0, 'BM')) return 'image/bmp';
  if (byte(0) == 0 && byte(1) == 0 && byte(2) == 1 && byte(3) == 0) return 'image/x-icon';
  final head = utf8.decode(b.sublist(0, min(512, b.length)), allowMalformed: true).trimLeft().toLowerCase();
  if (head.startsWith('<svg') || (head.startsWith('<?xml') && head.contains('<svg'))) return 'image/svg+xml';
  return null;
}

class _TooBig implements Exception {}

class ImageProxy {
  ImageProxy({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  /// Least recently used first (a Dart map keeps insertion order).
  final Map<String, _Cached> _cache = {};
  int _bytes = 0;
  final Map<String, Future<ImageResult>> _inflight = {};

  Future<ImageResult> get(String raw) {
    final checked = checkImageUrl(raw);
    final url = checked.url;
    if (url == null) return Future.value(ImageError(400, checked.error ?? 'Bad link'));
    final hit = _cache[url];
    if (hit != null && _now() - hit.at < _cacheMs) {
      // Most recently used goes to the back, so eviction takes the stalest first.
      _cache.remove(url);
      _cache[url] = hit;
      return Future.value(hit);
    }
    // (The block body matters: whenComplete waits on a returned future, and remove() returns this one.)
    return _inflight.putIfAbsent(
      url,
      () => _fetch(url).whenComplete(() {
        _inflight.remove(url);
      }),
    );
  }

  /// Stops the proxy's HTTP client.
  void close() => _client.close(force: true);

  Future<ImageResult> _fetch(String url) async {
    final uri = Uri.parse(url);
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    HttpClientResponse res;
    try {
      final req = await _client.getUrl(uri).timeout(_timeout);
      req.followRedirects = true;
      req.maxRedirects = 20;
      req.headers.set(
        HttpHeaders.acceptHeader,
        'image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5',
      );
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (compatible; agent-office; +https://github.com/AgentSystemLabs/agent-office)',
      );
      res = await req.close().timeout(_timeout);
    } on TimeoutException {
      return ImageError(504, '$host took too long to answer');
    } catch (err) {
      return ImageError(502, "Couldn't reach $host${_codeOf(err)}");
    }
    if (res.statusCode < 200 || res.statusCode > 299) {
      unawaited(res.drain<void>().catchError((Object _) {}));
      final text = res.reasonPhrase;
      return ImageError(502, '$host answered ${res.statusCode}${text.isNotEmpty ? ' $text' : ''}');
    }
    var type = (res.headers.value(HttpHeaders.contentTypeHeader) ?? '').split(';')[0].trim().toLowerCase();
    if (type == 'text/html' || type == 'application/xhtml+xml') {
      unawaited(res.drain<void>().catchError((Object _) {}));
      return const ImageError(
        415,
        'That link is a web page, not an image. Right-click the picture and choose “Copy image address”.',
      );
    }
    if (res.contentLength > _maxImageBytes) {
      unawaited(res.drain<void>().catchError((Object _) {}));
      return const ImageError(413, 'That image is over 15 MB. Try a smaller one.');
    }
    final builder = BytesBuilder(copy: false);
    try {
      await res
          .forEach((chunk) {
            builder.add(chunk);
            if (builder.length > _maxImageBytes) throw _TooBig();
          })
          .timeout(_timeout);
    } on _TooBig {
      return const ImageError(413, 'That image is over 15 MB. Try a smaller one.');
    } catch (_) {
      return ImageError(502, '$host stopped sending the image halfway');
    }
    final body = builder.takeBytes();
    if (!type.startsWith('image/')) {
      final sniffed = _sniff(body);
      if (sniffed == null) return ImageError(415, "That link isn't an image${type.isNotEmpty ? " (it's $type)" : ''}");
      type = sniffed;
    }
    final entry = _Cached(type, body, _now());
    final old = _cache.remove(url);
    if (old != null) _bytes -= old.body.length;
    _cache[url] = entry;
    _bytes += body.length;
    for (final k in [..._cache.keys]) {
      if (_bytes <= _cacheBytes) break;
      _bytes -= _cache.remove(k)!.body.length;
    }
    return entry;
  }
}

/// Node's error code for a failed connection, like " (ENOTFOUND)", when there's one to say.
String _codeOf(Object err) {
  if (err is SocketException) {
    if (err.message.contains('Failed host lookup')) return ' (ENOTFOUND)';
    final code = err.osError?.errorCode;
    if (code == 111 || code == 61) return ' (ECONNREFUSED)';
    if (code == 104 || code == 54) return ' (ECONNRESET)';
  }
  return '';
}
