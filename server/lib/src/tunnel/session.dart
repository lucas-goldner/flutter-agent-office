import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../secrets.dart' show chmodPrivate;
import 'office.dart';

// Signing `agent-office tunnel` in to the office: with the session it kept from last time, or by
// asking for the password in the terminal. The session is what a browser's cookie is, good for two
// weeks, and is kept in a file only this user can read, so the password is asked for once.
// Ported from src/server/tunnel/session.ts.

String _home() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;

/// Where the sessions are kept, one per office.
String sessionsFile() {
  final xdg = Platform.environment['XDG_CONFIG_HOME'];
  return p.join(xdg != null && xdg.isNotEmpty ? xdg : p.join(_home(), '.config'), 'agent-office', 'tunnel.json');
}

Map<String, String> _saved() {
  try {
    final all = jsonDecode(File(sessionsFile()).readAsStringSync());
    if (all is! Map) return {};
    return {
      for (final e in all.entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String,
    };
  } catch (_) {
    return {};
  }
}

/// Keeps the session for this office (or, without one, forgets it).
void _keep(String office, String? token) {
  final all = _saved();
  if (token != null && token.isNotEmpty) {
    all[office] = token;
  } else {
    all.remove(office);
  }
  final file = sessionsFile();
  try {
    final dir = Directory(p.dirname(file));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      chmodPrivate(dir.path, '700');
    }
    final f = File(file);
    if (!f.existsSync()) f.createSync();
    chmodPrivate(file, '600');
    f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(all)}\n');
  } catch (_) {
    // Not kept: the password is asked for again next time.
  }
}

String _tildify(String file) {
  final home = _home();
  return file.startsWith('$home${p.separator}') ? '~${file.substring(home.length)}' : file;
}

/// Someone's at a terminal to answer questions.
bool _interactive() => stdin.hasTerminal && stdout.hasTerminal;

String _ask(String question) {
  stdout.write(question);
  return (stdin.readLineSync(encoding: utf8) ?? '').trim();
}

/// Asks without showing what's typed.
String _askHidden(String question) {
  stdout.write(question);
  final echo = stdin.echoMode;
  try {
    stdin.echoMode = false;
    return stdin.readLineSync(encoding: utf8) ?? '';
  } finally {
    stdin.echoMode = echo;
    stdout.writeln();
  }
}

/// Who to sign in as: an account's name (without one the password is the shared office password),
/// and its password.
typedef Credentials = ({String? name, String? password});

/// Signs in to the office: with the session kept from last time ([key] names the office in the
/// file), else the password given, else by asking. Why it couldn't, or '' when `office.token` is good.
Future<String> tunnelSignIn(TunnelOffice office, String key, Credentials given, void Function(String) say) async {
  final kept = _saved()[key];
  if (kept != null) {
    office.token = kept;
    if (await office.forwards() != ForwardsRefused.signedOut) return '';
    office.token = '';
    _keep(key, null);
  }
  if (given.password != null) {
    final err = await office.signIn(given.name ?? '', given.password!);
    if (err.isEmpty) _keep(key, office.token);
    // AGENT_OFFICE_PASSWORD may be another office's (one that runs on this computer): ask instead.
    if (err.isEmpty || !_interactive()) return err;
    say('  $err');
  }
  if (!_interactive()) {
    return 'Not signed in. Run it in a terminal to type the password, or set AGENT_OFFICE_PASSWORD '
        '(and --name for an account of your own).';
  }

  final opts = await office.loginOptions();
  final askName = given.name == null && (opts.accounts || !opts.shared);
  say('  Sign in to the office at ${office.origin} (asked once: the session is kept in ${_tildify(sessionsFile())})');
  for (var tries = 0; tries < 3; tries++) {
    final name = askName
        ? _ask(opts.shared ? '  Your name (Enter for the office password): ' : '  Your name: ')
        : (given.name ?? '');
    final err = await office.signIn(name, _askHidden(name.isNotEmpty ? '  Password: ' : '  Office password: '));
    if (err.isEmpty) {
      _keep(key, office.token);
      return '';
    }
    say('  $err');
    if (RegExp('too many', caseSensitive: false).hasMatch(err)) return err;
  }
  return 'Sign-in failed';
}

/// The session stopped working (the password changed, the account was revoked): forget it.
void forgetSession(TunnelOffice office, String key) {
  office.token = '';
  _keep(key, null);
}
