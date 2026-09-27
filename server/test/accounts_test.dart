import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/accounts.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Accounts accounts;
  File file() => File(p.join(dir.path, 'accounts.json'));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ao-accounts-');
    accounts = Accounts(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('cleanName collapses whitespace, drops control characters and caps the length', () {
    expect(cleanName('  Ada ​ Lovelace\n'), 'Ada Lovelace');
    expect(cleanName('A' * 40), 'A' * nameMax);
    expect(cleanName(42), '');
    expect(cleanName('\u0000\u0007'), '');
  });

  test('a fresh office has no accounts and the shared password on', () {
    expect(accounts.any, isFalse);
    expect(accounts.sharedPassword, isTrue);
    expect(file().existsSync(), isFalse);
  });

  test('an invite makes one account, once', () async {
    final v = accounts.invite('Grace', AccountRole.admin, 'Ada') as AccountInvite;
    expect(v.name, 'Ada');
    expect(v.role, AccountRole.admin);
    expect(v.token, isNot(contains('=')));
    expect(v.expiresAt - v.createdAt, 7 * 24 * 60 * 60000);
    expect(accounts.findInvite(v.token)?.id, v.id);
    expect(accounts.findInvite('${v.token}x'), isNull);
    expect(accounts.findInvite(''), isNull);

    expect(await accounts.join(v.token, 'Someone else', 'short'), 'Pick a password of at least 8 characters');
    final a = await accounts.join(v.token, 'ignored: the invite names them', 'long enough');
    expect(a, isA<Account>());
    a as Account;
    expect(a.name, 'Ada');
    expect(a.role, AccountRole.admin);
    expect(a.createdBy, 'Grace');
    expect(await accounts.join(v.token, 'Ada', 'long enough'), startsWith('This invite link has expired'));
    expect((await accounts.check('ADA', 'long enough'))?.id, a.id);
    expect(await accounts.check('Ada', 'long enougH'), isNull);
  });

  test('names are unique, among accounts and open invites alike', () async {
    final v = accounts.invite('x', AccountRole.member) as AccountInvite;
    expect(v.name, isNull);
    expect(await accounts.join(v.token, '   ', 'password1'), 'Pick a name');
    expect(await accounts.join(v.token, 'Bob', 'password1'), isA<Account>());
    expect(accounts.invite('x', AccountRole.member, 'bob'), "There's already an account called bob");
    expect(accounts.invite('x', AccountRole.member, 'Cy'), isA<AccountInvite>());
    expect(accounts.invite('x', AccountRole.member, 'cy'), 'cy already has an open invite');
    expect(accounts.invite('x', AccountRole.member, '​'), 'That name has no letters in it');
  });

  test('open invites are capped', () {
    for (var i = 0; i < 100; i++) {
      expect(accounts.invite('x', AccountRole.member), isA<AccountInvite>());
    }
    expect(accounts.invite('x', AccountRole.member), 'Too many open invites — cancel some first');
  });

  test('expired invites are dropped', () {
    final v = accounts.invite('x', AccountRole.member) as AccountInvite;
    final saved = jsonDecode(file().readAsStringSync()) as Map<String, dynamic>;
    (saved['invites'] as List).first['expiresAt'] = 1;
    file().writeAsStringSync(jsonEncode(saved));
    // Another size, so the stamp changes even within one mtime tick.
    file().writeAsStringSync('${jsonEncode(saved)}\n');
    expect(accounts.findInvite(v.token), isNull);
    expect(accounts.state({}).invites, isEmpty);
  });

  test('the file keeps the Node server\'s shape, and edits from elsewhere are picked up', () async {
    final v = accounts.invite('Grace', AccountRole.member, 'Ada') as AccountInvite;
    final a = await accounts.join(v.token, '', 'password1') as Account;
    accounts.setSharedPassword(false);
    final saved = jsonDecode(file().readAsStringSync()) as Map<String, dynamic>;
    expect(saved.keys, ['accounts', 'invites', 'sharedPassword']);
    expect((saved['accounts'] as List).first.keys, ['id', 'name', 'role', 'hash', 'salt', 'createdAt', 'createdBy']);
    expect(saved['sharedPassword'], false);
    expect(file().readAsStringSync(), startsWith('{\n  "accounts": [\n    {\n      "id": '));

    // The `accounts` command, as another process, turns the password back on.
    final other = Accounts(dir.path);
    other.setSharedPassword(true);
    expect(jsonDecode(file().readAsStringSync()), isNot(contains('sharedPassword')));
    expect(accounts.sharedPassword, isTrue);
    other.setRole(a.id, AccountRole.admin);
    expect(accounts.get(a.id)?.role, AccountRole.admin);
    expect(accounts.state({a.id}).accounts.single.online, isTrue);
    expect(accounts.state({a.id}).accounts.single.toJson(), isNot(contains('hash')));
  });

  test('an unreadable file is never written over', () {
    file().writeAsStringSync('{ not json');
    final broken = Accounts(dir.path);
    expect(broken.unreadableFile, file().path);
    broken.setSharedPassword(false);
    expect(file().readAsStringSync(), '{ not json');
  });
}
