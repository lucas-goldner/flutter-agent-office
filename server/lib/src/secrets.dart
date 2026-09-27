// The small crypto and file helpers that config, accounts and auth share, standing in for the bits
// of node:crypto and node:fs they used: scrypt with Node's defaults, a constant-time compare,
// random bytes, unpadded base64url, and files only the office's user may read.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show Scrypt, ScryptParameters;

final Random _random = Random.secure();

/// `crypto.randomBytes(n)`.
Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

/// Node's scrypt defaults (N=16384, r=8, p=1), so hashes the Node server wrote keep verifying.
Uint8List scryptSync(String password, List<int> salt, [int keyLength = 32]) {
  final s = Scrypt()..init(ScryptParameters(16384, 8, 1, keyLength, Uint8List.fromList(salt)));
  return s.process(Uint8List.fromList(utf8.encode(password)));
}

/// scrypt on another isolate, so guessing can't stall the event loop (Node ran it on the libuv pool).
Future<Uint8List> scrypt(String password, List<int> salt, [int keyLength = 32]) {
  final saltCopy = Uint8List.fromList(salt);
  return Isolate.run(() => scryptSync(password, saltCopy, keyLength));
}

/// Compares in time that depends only on the length. Unlike Node's, different lengths are just
/// unequal rather than an exception.
bool timingSafeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String toHex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Hex to bytes, reading as far as the text is valid hex, like `Buffer.from(s, 'hex')`.
Uint8List fromHex(String s) {
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    final v = int.tryParse(s.substring(i, i + 2), radix: 16);
    if (v == null) break;
    out.add(v);
  }
  return Uint8List.fromList(out);
}

/// `Buffer.toString('base64url')`: no padding.
String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Reads unpadded (or padded) base64url; null when it isn't.
Uint8List? decodeBase64Url(String s) {
  try {
    final t = s.replaceAll('=', '');
    return base64Url.decode(t.padRight((t.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return null;
  }
}

/// Makes the file readable by its owner only, the way the TS created it with `mode: 0o600`.
void chmodPrivate(String path, [String mode = '600']) {
  if (Platform.isWindows) return;
  try {
    Process.runSync('chmod', [mode, path]);
  } catch (_) {
    // no chmod: the file keeps the umask's mode
  }
}

/// Writes `<file>.tmp` (owner-only) and renames it into place, so nobody reads half a file.
void writePrivateFile(String path, String content, {String? tmp}) {
  final tmpPath = tmp ?? '$path.tmp';
  final f = File(tmpPath);
  f.writeAsStringSync('');
  chmodPrivate(tmpPath);
  f.writeAsStringSync(content, flush: true);
  f.renameSync(path);
}

/// `JSON.stringify(v, null, 2)`.
String jsonPretty(Object? v) => const JsonEncoder.withIndent('  ').convert(v);
