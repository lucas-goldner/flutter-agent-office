import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';

// Installed by deploy/provision.sh. It edits the `office` user's authorized_keys (root-owned), so
// it re-runs itself with sudo; the office only ever passes it a validated name and key text.
final String _helper = (Platform.environment['AGENT_OFFICE_TEAM_HELPER'] ?? '').isNotEmpty
    ? Platform.environment['AGENT_OFFICE_TEAM_HELPER']!
    : '/usr/local/bin/agent-office-team';
const _teamUser = 'office';
final _githubUser = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$');

/// deploy/aws.sh also accepts other names, for keys invited from a file.
final _member = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$');

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

Future<_Run> _runHelper(List<String> args, [String input = '']) async {
  Process child;
  try {
    child = await Process.start(_helper, args);
  } catch (err) {
    return _Run(1, '', '$err');
  }
  final out = child.stdout.transform(utf8.decoder).join();
  final errOut = child.stderr.transform(utf8.decoder).join();
  // The helper may exit before reading everything.
  child.stdin.done.catchError((_) {});
  try {
    child.stdin.write(input);
    await child.stdin.close();
  } catch (_) {}
  var timedOut = false;
  final code = await child.exitCode.timeout(
    const Duration(seconds: 15),
    onTimeout: () {
      timedOut = true;
      child.kill(ProcessSignal.sigterm);
      return 1;
    },
  );
  final e = (await errOut).trim();
  return _Run(code, await out, e.isNotEmpty ? e : (timedOut ? 'timed out' : (code != 0 ? 'exited with $code' : '')));
}

/// What [Team.invite] gives back: the teammate's name and how many keys went in, or why not.
class TeamInvite {
  const TeamInvite({this.name, this.keys = 0, this.error});
  final String? name;
  final int keys;
  final String? error;
}

/// Who may open the SSH tunnel to this office, for offices deployed with deploy/aws.sh.
class Team {
  Team(this._publicHost, this._port, {HttpClient Function()? httpClient}) : _httpClient = httpClient ?? HttpClient.new;

  final String? _publicHost;
  final int _port;
  final HttpClient Function() _httpClient;
  String? _fingerprint;

  /// Invites work when the office knows its public address and the helper is installed.
  bool get available => (_publicHost ?? '').isNotEmpty && File(_helper).existsSync();

  /// user@host teammates tunnel to, when invites work.
  String? get ssh => available ? '$_teamUser@$_publicHost' : null;

  Future<TeamState> state() async {
    if (!available) {
      return TeamState(
        port: _port,
        members: const [],
        unavailable:
            'Invites work on offices deployed with deploy/aws.sh (re-run `deploy/aws.sh up` on one made before invites).',
      );
    }
    if (_fingerprint == null) {
      final f = (await _runHelper(['fingerprint'])).out.trim();
      _fingerprint = f.isEmpty ? null : f;
    }
    final list = await _runHelper(['list']);
    if (list.code != 0) {
      return TeamState(
        port: _port,
        members: const [],
        ssh: ssh,
        fingerprint: _fingerprint,
        error: "Couldn't list the team: ${list.err}",
      );
    }
    final members = <TeamMember>[];
    for (final l in list.out.split('\n')) {
      final parts = l.trim().split(RegExp(r'\s+'));
      if (parts.length != 2 || parts[0].isEmpty) continue;
      members.add(TeamMember(name: parts[0], keys: int.tryParse(parts[1]) ?? 0));
    }
    return TeamState(port: _port, members: members, ssh: ssh, fingerprint: _fingerprint);
  }

  /// Installs the SSH keys on `github.com/<user>.keys`, each limited to opening the tunnel.
  Future<TeamInvite> invite(String github) async {
    if (!available) return const TeamInvite(error: 'Invites work on offices deployed with deploy/aws.sh');
    final user = github.trim().replaceFirst(RegExp(r'^@'), '');
    if (!_githubUser.hasMatch(user)) return TeamInvite(error: '"$github" isn\'t a GitHub username');
    String text;
    final client = _httpClient();
    try {
      final res = await () async {
        final req = await client.getUrl(Uri.parse('https://github.com/$user.keys'));
        final res = await req.close();
        final bytes = await res.fold<List<int>>([], (a, c) => a.length > 64 * 1024 ? a : (a..addAll(c)));
        return (status: res.statusCode, body: utf8.decode(bytes, allowMalformed: true));
      }().timeout(const Duration(seconds: 10));
      if (res.status == 404) return TeamInvite(error: "There's no GitHub user called $user");
      if (res.status < 200 || res.status >= 300) {
        return TeamInvite(error: "GitHub answered ${res.status} for $user's keys — try again");
      }
      text = res.body.length > 64 * 1024 ? res.body.substring(0, 64 * 1024) : res.body;
    } on TimeoutException {
      return const TeamInvite(error: "Couldn't reach GitHub: The operation was aborted due to timeout");
    } catch (err) {
      return TeamInvite(error: "Couldn't reach GitHub: ${err is IOException ? err.toString() : err}");
    } finally {
      client.close(force: true);
    }
    if (text.trim().isEmpty) {
      return TeamInvite(error: '$user has no SSH keys on GitHub — they can add one at github.com/settings/keys');
    }
    final r = await _runHelper(['add', user], text);
    if (r.code == 65) return TeamInvite(error: "None of $user's GitHub keys are a type SSH accepts here");
    if (r.code != 0) return TeamInvite(error: "Couldn't add $user's keys: ${r.err}");
    return TeamInvite(name: user, keys: int.tryParse(r.out.trim()) ?? 0);
  }

  /// Removes their keys. Open tunnels drop for everyone (they just re-run the command).
  /// Null when done, else why not.
  Future<String?> remove(String name) async {
    if (!available) return 'Invites work on offices deployed with deploy/aws.sh';
    if (!_member.hasMatch(name)) return '"$name" isn\'t a teammate name';
    final r = await _runHelper(['remove', name]);
    if (r.code == 66) return "$name isn't invited";
    if (r.code != 0) return "Couldn't remove $name: ${r.err}";
    return null;
  }
}
