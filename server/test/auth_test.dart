import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/accounts.dart';
import 'package:agent_office_server/src/auth.dart';
import 'package:agent_office_server/src/secrets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Vectors made with Node's node:crypto, as the TypeScript server computed them:
//   scryptSync(pw, Buffer.from('00112233445566778899aabbccddeeff', 'hex'), 32)
//   key = createHmac('sha256', 's3cret').update('session:').update(verifier).digest()
//   cookie = base64url(JSON {exp: 4102444800000, n: '0011223344556677'[, u: 'abcd']}) + '.' + HMAC
final salt = fromHex('00112233445566778899aabbccddeeff');
const verifierHex = 'f5206d570fcd120bd1f23a8cd186bd87c04ac1db00e9ac1efca589774ae6ecb8'; // 'correct horse'
const unicodeHex = '7a75f9d757cd57830f7f69fe9df8122f0b6ceb6f81e686bcdb8814d9d743ce15'; // 'pässwörd ✓'
const secret = 's3cret';
const nodeSharedCookie =
    'eyJleHAiOjQxMDI0NDQ4MDAwMDAsIm4iOiIwMDExMjIzMzQ0NTU2Njc3In0.t2kzWbEPp_cVd8Qfh9jyb4EtuSQHgynQ16s3Kr8YL9E';
const nodeAccountCookie =
    'eyJleHAiOjQxMDI0NDQ4MDAwMDAsIm4iOiIwMDExMjIzMzQ0NTU2Njc3IiwidSI6ImFiY2QifQ.g3-ALXaUm4PZ6y5OJcQFmlGoYBWw4CSex0bhFaKmiQs';

Map<String, List<String>> headers({String? cookie, String host = 'localhost:4600'}) => {
  'host': [host],
  'cookie': ?(cookie == null ? null : [cookie]),
};

void main() {
  late Directory dir;
  late Accounts accounts;
  late Auth auth;
  var now = 1700000000000;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ao-auth-');
    // An account the Node-made account cookie names.
    File(p.join(dir.path, 'accounts.json')).writeAsStringSync(
      jsonPretty({
        'accounts': [
          {
            'id': 'abcd',
            'name': 'Ada',
            'role': 'admin',
            'hash': verifierHex,
            'salt': toHex(salt),
            'createdAt': 1,
            'createdBy': 'the terminal',
          },
        ],
        'invites': [],
      }),
    );
    accounts = Accounts(dir.path);
    now = 1700000000000;
    auth = Auth(fromHex(verifierHex), salt, secret, accounts, now: () => now);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('scrypt', () {
    test('matches hashes Node wrote (N=16384, r=8, p=1)', () {
      expect(toHex(scryptSync('correct horse', salt)), verifierHex);
      expect(toHex(scryptSync('pässwörd ✓', salt)), unicodeHex);
    });

    test('checkPassword accepts the password and nothing else', () async {
      expect(await auth.checkPassword('correct horse'), isTrue);
      expect(await auth.checkPassword('correct horse '), isFalse);
      expect(await auth.checkPassword(''), isFalse);
    });

    test('an account hashed by Node signs in', () async {
      expect((await accounts.check('ada', 'correct horse'))?.id, 'abcd');
      expect(await accounts.check('Ada', 'wrong'), isNull);
      expect(await accounts.check('Nobody', 'correct horse'), isNull);
    });
  });

  group('session cookies', () {
    test('cookies the Node server signed still verify', () {
      expect(auth.verify(nodeSharedCookie), isNotNull);
      expect(auth.verify(nodeSharedCookie)!.account, isNull);
      expect(auth.verify(nodeAccountCookie)?.account?.id, 'abcd');
    });

    test('issued cookies verify, for the shared password and for an account', () {
      final shared = auth.issue();
      expect(shared, isNot(contains('=')));
      expect(auth.verify(shared)?.account, isNull);
      expect(auth.verify(shared), isNotNull);
      expect(auth.verify(auth.issue('abcd'))?.account?.name, 'Ada');
    });

    test('a tampered, truncated or foreign cookie is refused', () {
      final t = auth.issue();
      expect(auth.verify('${t}x'), isNull);
      expect(auth.verify(t.substring(0, t.length - 1)), isNull);
      expect(auth.verify('.${t.split('.')[1]}'), isNull);
      expect(auth.verify('garbage'), isNull);
      expect(auth.verify(''), isNull);
      expect(auth.verify(null), isNull);
      // Swapping the body for an account's, keeping the shared signature, doesn't sign that account in.
      final body = base64UrlNoPad(utf8.encode(jsonEncode({'exp': now + 100000, 'n': 'x', 'u': 'abcd'})));
      expect(auth.verify('$body.${t.split('.')[1]}'), isNull);
      // Another office's secret, or another password, signs differently.
      expect(Auth(fromHex(verifierHex), salt, 'other', accounts, now: () => now).verify(t), isNull);
      expect(Auth(fromHex(unicodeHex), salt, secret, accounts, now: () => now).verify(t), isNull);
    });

    test('account sessions outlive a password change; shared ones do not', () {
      final a = auth.issue('abcd');
      final other = Auth(fromHex(unicodeHex), salt, secret, accounts, now: () => now);
      expect(other.verify(a)?.account?.id, 'abcd');
    });

    test('an expired cookie is refused', () {
      final t = auth.issue();
      now += 14 * 24 * 60 * 60 * 1000 - 1;
      expect(auth.verify(t), isNotNull);
      now += 1;
      expect(auth.verify(t), isNull);
    });

    test('revoking the account, or switching the shared password off, signs out at once', () {
      final shared = auth.issue();
      final account = auth.issue('abcd');
      accounts.setSharedPassword(false);
      expect(auth.verify(shared), isNull);
      expect(auth.verify(account), isNotNull);
      accounts.revoke('abcd');
      expect(auth.verify(account), isNull);
    });

    test('checkToken compares claim tokens', () {
      expect(auth.checkToken('abc', 'abc'), isTrue);
      expect(auth.checkToken('abd', 'abc'), isFalse);
      expect(auth.checkToken('', 'abc'), isFalse);
    });
  });

  group('cookies on requests', () {
    test('each port of a host has its own cookie', () {
      expect(cookieName('localhost:4600'), 'ao_session_4600');
      expect(cookieName('office.example.com'), 'ao_session');
      expect(cookieName(null), 'ao_session');
      final t = auth.issue();
      expect(auth.fromRequest(headers(cookie: 'ao_session_4600=$t')), isNotNull);
      expect(auth.fromRequest(headers(cookie: 'ao_session_4601=$t')), isNull);
      expect(auth.fromRequest(headers(cookie: 'other=1; ao_session=$t', host: 'office.example.com')), isNotNull);
    });

    test('fromAnyCookie accepts the office cookie of any port', () {
      final t = auth.issue();
      expect(auth.fromAnyCookie(headers(cookie: 'ao_session_4600=$t', host: 'localhost:5173')), isTrue);
      expect(auth.fromAnyCookie(headers(cookie: 'ao_session_4600=nope', host: 'localhost:5173')), isFalse);
      expect(auth.fromAnyCookie(headers(cookie: 'x_ao_session=$t', host: 'localhost:5173')), isFalse);
    });

    test('Set-Cookie values', () {
      final h = headers();
      expect(auth.cookie(h, 'T', true), 'ao_session_4600=T; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600; Secure');
      expect(auth.cookie(h, 'T', false), 'ao_session_4600=T; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600');
      expect(auth.clearCookie(h), 'ao_session_4600=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0');
    });

    test('parseCookies decodes, and survives malformed values', () {
      expect(parseCookies('a=1; b=hello%20world; c=%E0%A4%A; d'), {'a': '1', 'b': 'hello world', 'c': '%E0%A4%A'});
      expect(parseCookies(null), isEmpty);
    });

    test('withoutOfficeCookies strips only the office sessions', () {
      expect(withoutOfficeCookies('ao_session_4600=x; theme=dark; ao_session=y'), 'theme=dark');
      expect(withoutOfficeCookies('ao_session=y'), isNull);
      expect(withoutOfficeCookies('ao_sessionX=1'), 'ao_sessionX=1');
      expect(withoutOfficeCookies(null), isNull);
    });
  });

  group('login rate limit', () {
    test('ten attempts per five minutes, per client', () {
      for (var i = 0; i < 10; i++) {
        expect(auth.allowAttempt('1.2.3.4'), isTrue, reason: 'attempt ${i + 1}');
      }
      expect(auth.allowAttempt('1.2.3.4'), isFalse);
      expect(auth.allowAttempt('5.6.7.8'), isTrue);
      now += 5 * 60000;
      expect(auth.allowAttempt('1.2.3.4'), isFalse, reason: 'the window runs until its end');
      now += 1;
      expect(auth.allowAttempt('1.2.3.4'), isTrue);
    });

    test('a success clears the count', () {
      for (var i = 0; i < 10; i++) {
        auth.allowAttempt('1.2.3.4');
      }
      auth.recordSuccess('1.2.3.4');
      expect(auth.allowAttempt('1.2.3.4'), isTrue);
    });
  });
}
