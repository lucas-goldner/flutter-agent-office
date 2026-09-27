import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:office_shared/json_util.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'secrets.dart';

const nameMax = 24;
const passwordMin = 8;
const _passwordMax = 512;
const _inviteTtlMs = 7 * 24 * 60 * 60000;
const _maxInvites = 100;

class Account {
  Account({
    required this.id,
    required this.name,
    required this.role,
    required this.hash,
    required this.salt,
    required this.createdAt,
    required this.createdBy,
    this.lastSeenAt,
  });

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: asString(j['id']),
    name: asString(j['name']),
    role: AccountRole.parse(j['role']),
    hash: asString(j['hash']),
    salt: asString(j['salt']),
    createdAt: asInt(j['createdAt']),
    createdBy: asString(j['createdBy']),
    lastSeenAt: asIntOrNull(j['lastSeenAt']),
  );

  final String id;
  final String name;
  AccountRole role;

  /// scrypt(password, salt), hex.
  final String hash;
  final String salt;
  final int createdAt;
  final String createdBy;
  int? lastSeenAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role.wire,
    'hash': hash,
    'salt': salt,
    'createdAt': createdAt,
    'createdBy': createdBy,
    'lastSeenAt': ?lastSeenAt,
  };
}

class _Saved {
  _Saved({List<Account>? accounts, List<AccountInvite>? invites, this.sharedPassword})
    : accounts = accounts ?? [],
      invites = invites ?? [];
  List<Account> accounts;
  List<AccountInvite> invites;

  /// Missing means on: offices from before accounts keep working with their password.
  bool? sharedPassword;

  Map<String, dynamic> toJson() => {
    'accounts': [for (final a in accounts) a.toJson()],
    'invites': [for (final v in invites) v.toJson()],
    if (sharedPassword == false) 'sharedPassword': false,
  };
}

final _control = RegExp(r'\p{C}', unicode: true);
final _space = RegExp(r'\s+', unicode: true);

/// Collapses whitespace and drops control characters, so "Ada" and " Ada​" are one name.
String cleanName(Object? v) {
  if (v is! String) return '';
  final t = v.replaceAll(_control, '').replaceAll(_space, ' ').trim();
  return t.length > nameMax ? t.substring(0, nameMax) : t;
}

/// The TS compared with localeCompare at 'accent' sensitivity: case doesn't count, accents do.
bool _sameName(String a, String b) => a.toLowerCase() == b.toLowerCase();

List<int> _digest(String s) => sha256.convert(utf8.encode(s)).bytes;

/// Everyone's own sign-in, in .agent-office/accounts.json: named accounts made from single-use
/// invite links, and whether the shared office password still works alongside them.
/// `agent-office accounts` edits the same file while the office runs, so it's re-read when it changes.
class Accounts {
  Accounts(String dataDir) : _file = p.join(dataDir, 'accounts.json') {
    _sync();
  }

  _Saved _data = _Saved();
  final String _file;
  String _stamp = '';

  /// The file is there but couldn't be read: never write over it, or everyone's accounts are gone.
  bool _unreadable = false;

  /// The accounts file, when it's there but broken (nothing is saved over it).
  String? get unreadableFile => _unreadable ? _file : null;

  bool get sharedPassword {
    _sync();
    return _data.sharedPassword != false;
  }

  /// Whether anyone has an account yet.
  bool get any {
    _sync();
    return _data.accounts.isNotEmpty;
  }

  Account? get(String? id) {
    if (id == null || id.isEmpty) return null;
    _sync();
    for (final a in _data.accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  Account? byName(String name) {
    _sync();
    final n = cleanName(name);
    if (n.isEmpty) return null;
    for (final a in _data.accounts) {
      if (_sameName(a.name, n)) return a;
    }
    return null;
  }

  AccountsState state(Set<String> online) {
    _sync();
    _dropExpired();
    return AccountsState(
      accounts: [
        for (final a in _data.accounts)
          AccountInfo(
            id: a.id,
            name: a.name,
            role: a.role,
            createdAt: a.createdAt,
            createdBy: a.createdBy,
            lastSeenAt: a.lastSeenAt,
            online: online.contains(a.id),
          ),
      ],
      invites: List.of(_data.invites),
      sharedPassword: _data.sharedPassword != false,
    );
  }

  /// The account for a name and password, or null. Takes as long either way.
  Future<Account?> check(String name, String password) async {
    final a = byName(name);
    final pw = password.length > _passwordMax ? password.substring(0, _passwordMax) : password;
    final derived = await scrypt(pw, a != null ? fromHex(a.salt) : randomBytes(16), 32);
    return a != null && timingSafeEqual(derived, fromHex(a.hash)) ? a : null;
  }

  /// The new invite, or why there can't be one.
  Object /* AccountInvite | String */ invite(String by, AccountRole role, [String? name]) {
    _sync();
    _dropExpired();
    final n = cleanName(name);
    if (name != null && name.isNotEmpty && n.isEmpty) return 'That name has no letters in it';
    if (n.isNotEmpty) {
      final taken = _nameTaken(n);
      if (taken != null) return taken;
    }
    if (_data.invites.length >= _maxInvites) return 'Too many open invites — cancel some first';
    final now = DateTime.now().millisecondsSinceEpoch;
    final invite = AccountInvite(
      id: toHex(randomBytes(5)),
      token: base64UrlNoPad(randomBytes(24)),
      name: n.isEmpty ? null : n,
      role: role == AccountRole.admin ? AccountRole.admin : AccountRole.member,
      createdBy: by,
      createdAt: now,
      expiresAt: now + _inviteTtlMs,
    );
    _data.invites.add(invite);
    _save();
    return invite;
  }

  AccountInvite? cancel(String inviteId) {
    _sync();
    final i = _data.invites.indexWhere((v) => v.id == inviteId);
    if (i < 0) return null;
    final v = _data.invites.removeAt(i);
    _save();
    return v;
  }

  /// The open invite for a link's token.
  AccountInvite? findInvite(String token) {
    _sync();
    _dropExpired();
    if (token.isEmpty) return null;
    final want = _digest(token);
    for (final v in _data.invites) {
      if (timingSafeEqual(_digest(v.token), want)) return v;
    }
    return null;
  }

  /// Uses up an invite: makes the account and returns it, or says what's wrong (a String).
  Future<Object /* Account | String */> join(String token, String name, String password) async {
    final invite = findInvite(token);
    if (invite == null) return 'This invite link has expired or was already used. Ask for a new one.';
    final n = invite.name ?? cleanName(name);
    if (n.isEmpty) return 'Pick a name';
    if (password.length < passwordMin) return 'Pick a password of at least $passwordMin characters';
    if (password.length > _passwordMax) return 'That password is too long';
    final salt = randomBytes(16);
    final derived = await scrypt(password, salt, 32);
    // Hashing took a moment: someone else may have used the link or taken the name meanwhile.
    _sync();
    final i = _data.invites.indexWhere((v) => v.id == invite.id);
    if (i < 0) return 'This invite link was just used. Ask for a new one.';
    final taken = _nameTaken(n, invite.id);
    if (taken != null) return taken;
    final account = Account(
      id: toHex(randomBytes(8)),
      name: n,
      role: invite.role,
      hash: toHex(derived),
      salt: toHex(salt),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      createdBy: invite.createdBy,
    );
    _data.invites.removeAt(i);
    _data.accounts.add(account);
    _save();
    return account;
  }

  /// Deletes an account. Its sessions stop working on their next request.
  Account? revoke(String id) {
    _sync();
    final i = _data.accounts.indexWhere((a) => a.id == id);
    if (i < 0) return null;
    final a = _data.accounts.removeAt(i);
    _save();
    return a;
  }

  Account? setRole(String id, AccountRole role) {
    final a = get(id);
    if (a == null) return null;
    a.role = role == AccountRole.admin ? AccountRole.admin : AccountRole.member;
    _save();
    return a;
  }

  void setSharedPassword(bool on) {
    _sync();
    _data.sharedPassword = on ? null : false;
    _save();
  }

  void seen(String id) {
    final a = get(id);
    if (a == null) return;
    a.lastSeenAt = DateTime.now().millisecondsSinceEpoch;
    _save();
  }

  String? _nameTaken(String n, [String? exceptInvite]) {
    if (_data.accounts.any((a) => _sameName(a.name, n))) return "There's already an account called $n";
    if (_data.invites.any(
      (v) => v.id != exceptInvite && v.name != null && v.name!.isNotEmpty && _sameName(v.name!, n),
    )) {
      return '$n already has an open invite';
    }
    return null;
  }

  void _dropExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final keep = _data.invites.where((v) => v.expiresAt > now).toList();
    if (keep.length == _data.invites.length) return;
    _data.invites = keep;
    _save();
  }

  String _statStamp() {
    final st = FileStat.statSync(_file);
    if (st.type == FileSystemEntityType.notFound) return '';
    return '${st.modified.microsecondsSinceEpoch}:${st.size}';
  }

  /// Re-reads the file when something else (the `accounts` command) changed it.
  void _sync() {
    final stamp = _statStamp();
    if (stamp == _stamp) return;
    _stamp = stamp;
    if (stamp.isEmpty) {
      _data = _Saved();
      _unreadable = false;
      return;
    }
    try {
      final saved = jsonDecode(File(_file).readAsStringSync());
      if (saved is! Map) throw const FormatException('not a JSON object');
      final accounts = saved['accounts'];
      final invites = saved['invites'];
      _data = _Saved(
        accounts: accounts is List
            ? [
                for (final a in accounts)
                  if (a is Map && a['id'] is String && a['hash'] is String)
                    Account.fromJson(Map<String, dynamic>.from(a)),
              ]
            : [],
        invites: invites is List
            ? [
                for (final v in invites)
                  if (v is Map && v['token'] is String) AccountInvite.fromJson(Map<String, dynamic>.from(v)),
              ]
            : [],
        sharedPassword: saved['sharedPassword'] == false ? false : null,
      );
      _unreadable = false;
    } catch (err) {
      _unreadable = true;
      stderr.writeln("agent-office: couldn't read $_file: ${err is FormatException ? err.message : err}");
    }
  }

  void _save() {
    if (_unreadable) {
      stderr.writeln("agent-office: not saving accounts over $_file, which couldn't be read — fix or move it");
      return;
    }
    // Written whole and renamed into place, so the office and the `accounts` command never read half a file.
    try {
      writePrivateFile(_file, jsonPretty(_data.toJson()), tmp: '$_file.$pid.tmp');
    } catch (err) {
      stderr.writeln("agent-office: couldn't save $_file: $err");
      return;
    }
    try {
      _stamp = _statStamp();
    } catch (_) {
      _stamp = '';
    }
  }
}

const _help = '''agent-office accounts — who can sign in to the office

Usage:
  agent-office accounts [list]                 Accounts, open invites, and the shared password
  agent-office accounts invite [name] [--admin]
                                               Make a single-use invite link (valid 7 days)
  agent-office accounts revoke <name>          Delete an account; it's signed out at once
  agent-office accounts role <name> admin|member
  agent-office accounts password on|off        Whether the shared office password still works

Options:
  -d, --dir <dir>   The office's directory: the project it was started in, or its
                    home (default: the current directory if an office ran there,
                    else ~/agent-office or \$AGENT_OFFICE_HOME)
  -h, --help        Show this help

Works while the office runs: it picks up the changes within seconds.
''';

String _day(int t) =>
    DateTime.fromMillisecondsSinceEpoch(t, isUtc: true).toIso8601String().substring(0, 16).replaceFirst('T', ' ');

/// `agent-office accounts`: returns 0 when done, 1 when it couldn't, 2 for a usage error.
int accountsCommand(List<String> argv) {
  // An office started in this project keeps its accounts here; one started anywhere else, in its home.
  final cwd = Directory.current.path;
  var dir = File(p.join(cwd, '.agent-office', 'config.json')).existsSync() ? cwd : officeHome();
  var admin = false;
  final args = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '-h' || a == '--help') {
      stdout.write(_help);
      return 0;
    } else if (a == '-d' || a == '--dir') {
      if (i + 1 >= argv.length || argv[i + 1].isEmpty) return _usage('--dir needs a value');
      dir = p.normalize(p.absolute(argv[++i]));
    } else if (a == '--admin') {
      admin = true;
    } else if (a.startsWith('-')) {
      return _usage('unknown option $a');
    } else {
      args.add(a);
    }
  }
  final dataDir = p.join(dir, '.agent-office');
  if (FileSystemEntity.typeSync(dataDir) == FileSystemEntityType.notFound) {
    stderr.writeln('agent-office accounts: no office has run in $dir yet — start it once with `agent-office` there');
    return 1;
  }
  final accounts = Accounts(dataDir);
  if (accounts.unreadableFile != null) {
    return _fail("${accounts.unreadableFile} couldn't be read (see above) — fix or move it first");
  }
  final cmd = args.isNotEmpty ? args[0] : 'list';
  final arg = args.length > 1 ? args[1] : null;
  final arg2 = args.length > 2 ? args[2] : null;
  switch (cmd) {
    case 'list':
      final s = accounts.state({});
      print('Shared office password: ${s.sharedPassword ? 'on' : 'off'}');
      print('\nAccounts (${s.accounts.length}):');
      for (final a in s.accounts) {
        final seen = a.lastSeenAt != null ? 'last seen ${_day(a.lastSeenAt!)}' : 'never signed in';
        print('  ${a.name.padRight(nameMax)}  ${a.role.wire.padRight(6)}  since ${_day(a.createdAt)}  $seen');
      }
      if (s.accounts.isEmpty) print('  none yet: `agent-office accounts invite <name> --admin` makes you one');
      if (s.invites.isNotEmpty) {
        print('\nOpen invites (${s.invites.length}):');
        for (final v in s.invites) {
          print(
            '  ${(v.name ?? '(they pick)').padRight(nameMax)}  ${v.role.wire.padRight(6)}  '
            'by ${v.createdBy}, until ${_day(v.expiresAt)}  /join#${v.token}',
          );
        }
      }
      return 0;
    case 'invite':
      final v = accounts.invite('the terminal', admin ? AccountRole.admin : AccountRole.member, arg);
      if (v is String) return _fail(v);
      v as AccountInvite;
      print(
        'Invite ${v.name != null ? 'for ${v.name} ' : ''}(${v.role.wire}), single use, valid for 7 days:\n\n  /join#${v.token}\n',
      );
      print("Open it on the office's own address, e.g. http://localhost:4600/join#${v.token}");
      return 0;
    case 'revoke':
    case 'role':
      if (arg == null || arg.isEmpty) return _usage('$cmd needs a name');
      final a = accounts.byName(arg);
      if (a == null) return _fail("there's no account called $arg");
      if (cmd == 'revoke') {
        accounts.revoke(a.id);
        print("Revoked ${a.name}'s account. They're signed out of the office within seconds.");
        return 0;
      }
      if (arg2 != 'admin' && arg2 != 'member') return _usage('role takes admin or member');
      accounts.setRole(a.id, AccountRole.parse(arg2));
      print('${a.name} is ${arg2 == 'admin' ? 'an admin' : 'a member'} now.');
      return 0;
    case 'password':
      if (arg != 'on' && arg != 'off') return _usage('password takes on or off');
      if (arg == 'off' && !accounts.state({}).accounts.any((a) => a.role == AccountRole.admin)) {
        return _fail(
          'make an admin account first (`agent-office accounts invite <name> --admin`), or nobody could manage the office',
        );
      }
      accounts.setSharedPassword(arg == 'on');
      print(
        arg == 'on'
            ? 'The shared office password works again.'
            : 'The shared office password no longer signs anyone in; people who used it are signed out within seconds.',
      );
      return 0;
    default:
      return _usage('unknown command $cmd');
  }
}

int _usage(String msg) {
  stderr.writeln('agent-office accounts: $msg\n');
  stderr.write(_help);
  return 2;
}

int _fail(String msg) {
  stderr.writeln('agent-office accounts: $msg');
  return 1;
}
