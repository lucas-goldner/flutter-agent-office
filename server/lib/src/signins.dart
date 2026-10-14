import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'ptys.dart' show LocalPty, Pty, SpawnOpts;
import 'secrets.dart' show chmodPrivate, jsonPretty, writePrivateFile;
import 'workers.dart' show RunAs;

/*
 * Everyone's own Claude and GitHub
 * --------------------------------
 * In an office with accounts, each person's workers run on that person's own Claude plan and
 * GitHub account. Every account gets a folder, .agent-office/homes/<id>/, holding its own Claude
 * config (CLAUDE_CONFIG_DIR), gh config (GH_CONFIG_DIR) and git config (GIT_CONFIG_GLOBAL), and
 * whatever runs for that account gets those in its environment in place of the office's: its
 * workers, and what the office does on GitHub when they click (comment, merge, open a PR). Nothing
 * global changes, so any number of people can be signed in to different accounts at once.
 *
 * Signing in happens from the office: it runs `claude auth login` or `gh auth login --web` against
 * the account's folders and hands the browser the page to open (and GitHub's one-time code). A
 * token from `claude setup-token`, or a GitHub token, can be pasted instead, and a shell at a desk
 * runs with the same folders, so `claude auth login` typed there works too. Admins may keep using
 * the office machine's own sign-ins.
 *
 * An office without accounts (you alone, on the shared password) never comes here: everything runs
 * on the machine's own `claude` and `gh`, exactly as before.
 *
 * Ported from src/server/signins.ts.
 */

/// Credentials the office's own environment may carry. None of them reach anything run as someone else.
const claudeVars = [
  'CLAUDE_CODE_OAUTH_TOKEN',
  'CLAUDE_CODE_OAUTH_REFRESH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'CLAUDE_CONFIG_DIR',
  'CLAUDE_SECURESTORAGE_CONFIG_DIR',
];
const githubVars = [
  'GH_TOKEN',
  'GITHUB_TOKEN',
  'GH_ENTERPRISE_TOKEN',
  'GITHUB_ENTERPRISE_TOKEN',
  'GH_CONFIG_DIR',
  'GIT_CONFIG_GLOBAL',
];

/// GitHub's one-time codes last 15 minutes; a Claude sign-in link gets as long.
const _flow = Duration(minutes: 15);

/// Someone's sign-ins are looked at again at most this often, unless they ask.
const _lookGapMs = 20000;
const _lookTimeout = Duration(seconds: 30);

/// From `claude setup-token` (sk-ant-oat01-…), or an Anthropic API key (sk-ant-api03-…).
final claudeToken = RegExp(r'^sk-ant-[a-z]+\d*-[A-Za-z0-9_-]{20,}$');
final _apiKey = RegExp(r'^sk-ant-api');

/// ghp_…, github_pat_…, gho_… and the like.
final githubToken = RegExp(r'^[A-Za-z0-9_]{20,255}$');
final _accountId = RegExp(r'^[A-Za-z0-9]{6,64}$');
final _claudeCode = RegExp(r'^[A-Za-z0-9#_.~-]{8,2048}$');
const _helpWhere = '☰ → 🔐 Your sign-ins';

/// Whose gh the office runs for someone: their own sign-in's environment ([key] tells logins apart).
class GhAs {
  const GhAs(this.key, this.env);
  final String key;
  final Map<String, String> env;
}

/// How the office runs gh for someone: as them ([as]), as itself (neither set: no account, or an
/// admin's choice), or not at all ([refused] says why).
typedef GhRunAs = ({GhAs? as, String? refused});

/// What a command said: its exit code, stdout (trimmed), and the last line it said on stderr.
typedef RunResult = ({int code, String out, String last});

/// Runs a command to the end; never throws.
typedef SignInRunner =
    Future<RunResult> Function(String cmd, List<String> args, Map<String, String> env, [String? input]);

/// A sign-in the office is running for someone.
class _Flow {
  _Flow(this.stop, [this.write]);
  final void Function() stop;

  /// Types into it: the code from Claude's sign-in page.
  final void Function(String data)? write;
}

/// One kind of sign-in as the browser sees it, without `how`.
class _Look {
  const _Look(this.status, {this.who, this.pending, this.error});
  final SignInStatus status;
  final String? who;
  final SignInPending? pending;
  final String? error;
}

class _Live {
  _Live(this.claude, this.github);
  _Look claude;
  _Look github;
  final flows = <SignInKind, _Flow>{};
  Future<void>? looking;
  int lookedAt = 0;

  _Look of(SignInKind k) => k == SignInKind.claude ? claude : github;
  void set(SignInKind k, _Look l) => k == SignInKind.claude ? claude = l : github = l;
}

class SignIns implements RunAs {
  /// [claude] and [gh] are the binaries, or null when they aren't installed. [base] is the office's own
  /// environment, which everyone's is built on. [mayUseOffice]: whether the account may use the office's
  /// own sign-ins (admins). [run] and [spawn] stand in for running commands and PTYs, in tests.
  SignIns(
    String dataDir,
    this._claude,
    this._gh,
    this._base,
    this._mayUseOffice,
    this._onChange, {
    SignInRunner? run,
    Pty Function(SpawnOpts opts)? spawn,
    String? home,
  }) : _homes = p.join(dataDir, 'homes'),
       _run = run ?? runCommand,
       _spawn = spawn ?? LocalPty.spawn,
       _userHome = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  final String _homes;
  final String? _claude;
  final String? _gh;
  final Map<String, String> Function() _base;
  final bool Function(String accountId) _mayUseOffice;
  final void Function(String accountId) _onChange;
  final SignInRunner _run;
  final Pty Function(SpawnOpts opts) _spawn;
  final String _userHome;
  final _live = <String, _Live>{};

  /// Where an account's folder is.
  String homeOf(String id) => _home(id);

  SignInsState state(String id) {
    final s = _load(id);
    final l = _get(id);
    SignInState one(SignInKind k) {
      final x = l.of(k);
      return SignInState(status: x.status, how: _how(id, s, k), who: x.who, pending: x.pending, error: x.error);
    }

    return SignInsState(claude: one(SignInKind.claude), github: one(SignInKind.github), office: _mayUseOffice(id));
  }

  /// Whether [id] has a Claude sign-in its workers can start on, as far as the last look knows.
  @override
  bool claudeReady(String id) {
    final s = _load(id);
    return _how(id, s, SignInKind.claude) != SignInHow.login || s.seen(SignInKind.claude) != null;
  }

  bool githubReady(String id) {
    final s = _load(id);
    return _how(id, s, SignInKind.github) == SignInHow.office || s.seen(SignInKind.github) != null;
  }

  /// What to tell someone who needs [which] signed in first.
  @override
  String why(SignInKind which) => which == SignInKind.claude
      ? 'Sign in to Claude first ($_helpWhere): your workers run on your own Claude plan'
      : 'Sign in to GitHub first ($_helpWhere): the office acts on GitHub as you';

  /// Changes whenever what [id]'s Claude signs in with changes (to read its plan's limits afresh).
  /// Null when it's the office's own.
  String? claudeKey(String id) {
    final s = _load(id);
    final how = _how(id, s, SignInKind.claude);
    if (how == SignInHow.office) return null;
    final token = s.claudeToken;
    final tail = token != null ? token.substring(token.length > 12 ? token.length - 12 : 0) : '';
    return '${how.wire}:$tail:${s.seen(SignInKind.claude) ?? ''}';
  }

  /// The GitHub login [id] acts as (for "you" on comments); null when it's the office's own or none.
  String? githubLogin(String id) {
    final s = _load(id);
    return _how(id, s, SignInKind.github) == SignInHow.login
        ? s.seen(SignInKind.github)?.replaceFirst(RegExp('^@'), '')
        : null;
  }

  /// Puts [id]'s own sign-ins in place of the office's in [env] (changed in place, and returned).
  /// [dirs] are where a worker is about to start, to carry over the office's folder trust.
  @override
  Map<String, String> apply(String id, Map<String, String> env, [List<String> dirs = const [], SignInKind? only]) {
    final s = _load(id);
    final home = _prepare(id);
    if (only != SignInKind.github && _how(id, s, SignInKind.claude) != SignInHow.office) {
      for (final k in claudeVars) {
        env.remove(k);
      }
      final dir = p.join(home, 'claude');
      env['CLAUDE_CONFIG_DIR'] = dir;
      final token = s.claudeToken;
      if (token != null) env[_apiKey.hasMatch(token) ? 'ANTHROPIC_API_KEY' : 'CLAUDE_CODE_OAUTH_TOKEN'] = token;
      if (dirs.isNotEmpty) _trust(dir, dirs);
    }
    if (only != SignInKind.claude && _how(id, s, SignInKind.github) != SignInHow.office) {
      for (final k in githubVars) {
        env.remove(k);
      }
      env['GH_CONFIG_DIR'] = p.join(home, 'gh');
      env['GIT_CONFIG_GLOBAL'] = p.join(home, 'gitconfig');
    }
    return env;
  }

  /// How the office runs gh for [id]: as them, as itself (an admin's choice), or why it can't.
  GhRunAs ghAs(String id) {
    final s = _load(id);
    if (_how(id, s, SignInKind.github) == SignInHow.office) return (as: null, refused: null);
    if (s.seen(SignInKind.github) == null) return (as: null, refused: why(SignInKind.github));
    return (as: GhAs(id, apply(id, _base(), const [], SignInKind.github)), refused: null);
  }

  /// Looks at who [id] is signed in as, now if [force], else unless it just did.
  Future<void> look(String id, [bool force = false]) {
    final l = _get(id);
    final busy = l.looking;
    if (busy != null) return busy;
    if (!force && DateTime.now().millisecondsSinceEpoch - l.lookedAt < _lookGapMs) return Future.value();
    final f = Future.wait([_lookClaude(id), _lookGithub(id)]).then((_) {
      l.lookedAt = DateTime.now().millisecondsSinceEpoch;
      l.looking = null;
      _onChange(id);
    });
    l.looking = f;
    return f;
  }

  /// Starts signing [id] in from the office. The page to open comes through [state]. Returns why it can't.
  String? start(String id, SignInKind which) => which == SignInKind.claude ? _startClaude(id) : _startGithub(id);

  /// The code Claude's sign-in page showed, typed in where `claude auth login` waits for it.
  String? code(String id, String code) {
    final l = _get(id);
    final write = l.flows[SignInKind.claude]?.write;
    if (write == null) return 'Start signing in to Claude first';
    final clean = code.trim();
    if (!_claudeCode.hasMatch(clean)) return "That doesn't look like the code from Claude's sign-in page";
    write('$clean\r');
    final pending = l.claude.pending;
    l.claude = _Look(
      l.claude.status,
      who: l.claude.who,
      pending: SignInPending(url: pending?.url, code: pending?.code, sent: true),
    );
    _onChange(id);
    return null;
  }

  void cancel(String id, SignInKind which) {
    _stop(id, which);
    unawaited(look(id, true));
  }

  /// A pasted token: from `claude setup-token` (or an API key), or a GitHub token. Why it didn't take.
  Future<String?> token(String id, SignInKind which, String raw) async {
    final token = raw.trim();
    _stop(id, which);
    if (which == SignInKind.claude) {
      if (!claudeToken.hasMatch(token)) {
        return "That isn't a token from `claude setup-token` (sk-ant-oat01-…) or an Anthropic API key (sk-ant-api03-…)";
      }
      final s = _load(id);
      s.j['claude'] = {'use': 'token', 'token': token};
      _save(id, s);
      // Claude asks once before it uses an API key from the environment; this one is theirs, so it's approved.
      if (_apiKey.hasMatch(token)) {
        _seed(p.join(_prepare(id), 'claude'), (c) {
          final r = c['customApiKeyResponses'] is Map
              ? c['customApiKeyResponses'] as Map
              : (c['customApiKeyResponses'] = <String, dynamic>{'approved': <Object?>[], 'rejected': <Object?>[]});
          final approved = r['approved'] is List ? r['approved'] as List : (r['approved'] = <Object?>[]);
          final tail = token.substring(token.length - 20);
          if (!approved.contains(tail)) approved.add(tail);
        });
      }
      await look(id, true);
      return null;
    }
    final gh = _gh;
    if (gh == null) return "The GitHub CLI (gh) isn't installed on the office's machine";
    if (!githubToken.hasMatch(token)) return "That doesn't look like a GitHub token (ghp_…, github_pat_…)";
    final s = _load(id);
    s.j.remove('github');
    _save(id, s);
    // On stdin, never in argv or a log.
    final r = await _run(
      gh,
      ['auth', 'login', '--hostname', 'github.com', '--with-token', '--insecure-storage'],
      _githubEnv(id),
      '$token\n',
    );
    await look(id, true);
    return r.code == 0 ? null : "GitHub didn't take that token: ${r.last.isNotEmpty ? r.last : 'gh auth login failed'}";
  }

  /// Uses the office machine's own sign-in (admins only).
  String? useOffice(String id, SignInKind which) {
    if (!_mayUseOffice(id)) return "Only admins can use the office's own sign-ins";
    _stop(id, which);
    final s = _load(id);
    s.j[which.wire] = {'use': 'office'};
    _save(id, s);
    unawaited(look(id, true));
    return null;
  }

  Future<void> signOut(String id, SignInKind which) async {
    _stop(id, which);
    final s = _load(id);
    final how = _how(id, s, which);
    if (how == SignInHow.login) await _logout(id, which);
    s.j.remove(which.wire);
    final seen = s.j['seen'];
    if (seen is Map) seen.remove(which.wire);
    _save(id, s);
    if (which == SignInKind.github) _writeGitConfig(id);
    await look(id, true);
  }

  /// An account is gone: sign its logins out and delete its folder. Resolves once it's gone.
  Future<void> forget(String id) async {
    if (!_accountId.hasMatch(id)) return;
    _stop(id, SignInKind.claude);
    _stop(id, SignInKind.github);
    _live.remove(id);
    final home = p.join(_homes, id);
    // Never anything outside homes/, whatever the id says.
    if (!p.isWithin(_homes, home) || !Directory(home).existsSync()) return;
    // On a Mac, Claude keeps the login in the keychain, not the folder: sign out so it goes too.
    try {
      await _logout(id, SignInKind.claude);
    } catch (_) {
      // gone anyway below
    }
    try {
      Directory(home).deleteSync(recursive: true);
    } catch (err) {
      stderr.writeln("agent-office: couldn't delete $home: $err");
    }
  }

  /// Deletes the folders of accounts that no longer exist (revoked from the terminal meanwhile).
  void prune(Set<String> accounts) {
    List<FileSystemEntity> names;
    try {
      names = Directory(_homes).listSync();
    } catch (_) {
      return;
    }
    for (final e in names) {
      final n = p.basename(e.path);
      if (_accountId.hasMatch(n) && !accounts.contains(n)) unawaited(forget(n));
    }
  }

  void shutdown() {
    for (final id in _live.keys.toList()) {
      _stop(id, SignInKind.claude);
      _stop(id, SignInKind.github);
    }
  }

  // ---------------------------------------------------------------------------

  /// How [which] signs [id] in. A demoted admin's 'office' no longer counts: back to their own.
  SignInHow _how(String id, _Saved s, SignInKind which) {
    final use = s.use(which);
    if (use == 'office') return _mayUseOffice(id) ? SignInHow.office : SignInHow.login;
    return use == 'token' ? SignInHow.token : SignInHow.login;
  }

  _Live _get(String id) => _live.putIfAbsent(id, () {
    final s = _load(id);
    _Look of(SignInKind k) {
      final who = s.seen(k);
      return who != null ? _Look(SignInStatus.ok, who: who) : const _Look(SignInStatus.none);
    }

    return _Live(of(SignInKind.claude), of(SignInKind.github));
  });

  String _home(String id) {
    if (!_accountId.hasMatch(id)) throw ArgumentError('not an account id: $id');
    return p.join(_homes, id);
  }

  void _mkdir(String dir) {
    final d = Directory(dir);
    if (d.existsSync()) return;
    d.createSync(recursive: true);
    chmodPrivate(dir, '700');
  }

  /// The account's folder, made on first use.
  String _prepare(String id) {
    final home = _home(id);
    if (!File(p.join(home, 'gitconfig')).existsSync()) {
      for (final d in [_homes, home, p.join(home, 'claude'), p.join(home, 'gh')]) {
        _mkdir(d);
      }
      _seed(p.join(home, 'claude'));
      _writeGitConfig(id);
    }
    return home;
  }

  _Saved _load(String id) {
    try {
      final j = jsonDecode(File(p.join(_home(id), 'signins.json')).readAsStringSync());
      return _Saved(j is Map ? Map<String, dynamic>.from(j) : {});
    } catch (_) {
      return _Saved({});
    }
  }

  void _save(String id, _Saved s) {
    _prepare(id);
    try {
      writePrivateFile(p.join(_home(id), 'signins.json'), jsonPretty(s.j));
    } catch (err) {
      stderr.writeln("agent-office: couldn't save $id's sign-ins: $err");
    }
  }

  void _stop(String id, SignInKind which) {
    final l = _live[id];
    final flow = l?.flows.remove(which);
    if (l == null || flow == null) return;
    flow.stop();
    final x = l.of(which);
    l.set(which, _Look(x.who != null ? SignInStatus.ok : SignInStatus.none, who: x.who, error: x.error));
  }

  /// The environment for `claude` run as [id]'s own login (never a pasted token or the office's).
  Map<String, String> _claudeEnv(String id) {
    final env = _base();
    for (final k in claudeVars) {
      env.remove(k);
    }
    env['CLAUDE_CONFIG_DIR'] = p.join(_prepare(id), 'claude');
    return env;
  }

  Map<String, String> _githubEnv(String id) {
    final env = _base();
    for (final k in githubVars) {
      env.remove(k);
    }
    final home = _prepare(id);
    env['GH_CONFIG_DIR'] = p.join(home, 'gh');
    env['GIT_CONFIG_GLOBAL'] = p.join(home, 'gitconfig');
    return env;
  }

  String? _startClaude(String id) {
    final claude = _claude;
    if (claude == null) {
      return "Claude Code isn't installed where the office can run it — paste a token from `claude setup-token` instead";
    }
    _stop(id, SignInKind.claude);
    final l = _get(id);
    // BROWSER=true: Claude "opens" the page with the `true` command and just prints it, for the browser to show.
    final env = {..._claudeEnv(id), 'BROWSER': 'true', 'TERM': 'xterm-256color'};
    Pty pty;
    try {
      // Wide, so the link comes out on one line.
      pty = _spawn(
        SpawnOpts(
          file: claude,
          args: const ['auth', 'login', '--claudeai'],
          cwd: _home(id),
          env: env,
          cols: 4000,
          rows: 40,
        ),
      );
    } catch (err) {
      return "Couldn't start Claude Code's sign-in: $err";
    }
    var out = '';

    /// Where the output after the code was sent starts, to tell a wrong code apart from the first ask.
    var sentAt = -1;
    late final _Flow flow;
    flow = _Flow(
      () {
        try {
          pty.kill();
        } catch (_) {
          // already gone
        }
      },
      (data) {
        sentAt = out.length;
        pty.write(data);
      },
    );
    final timer = Timer(_flow, flow.stop);
    pty.onData((d) {
      out = _tail(out + d, 50000, (n) => sentAt = sentAt >= 0 ? (sentAt - n).clamp(0, 1 << 30) : sentAt);
      if (l.flows[SignInKind.claude] != flow) return;
      final text = _plain(out);
      final url = l.claude.pending?.url;
      if (url == null) {
        final m = RegExp(r'https://\S*oauth/authorize\?\S+').firstMatch(text);
        if (m != null) {
          l.claude = _Look(SignInStatus.busy, pending: SignInPending(url: m[0]));
          _onChange(id);
        }
      } else if (sentAt >= 0 &&
          RegExp('error|invalid|expired|failed', caseSensitive: false).hasMatch(_plain(out.substring(sentAt)))) {
        // Still running after complaining: the code didn't take, and it waits for another.
        final said = _lastWords(out.substring(sentAt));
        sentAt = -1;
        l.claude = _Look(
          SignInStatus.busy,
          pending: SignInPending(url: url),
          error: said.isNotEmpty ? said : "That code didn't work — copy it again, or start over",
        );
        _onChange(id);
      }
    });
    pty.onExit((e) {
      timer.cancel();
      if (l.flows[SignInKind.claude] != flow) return;
      l.flows.remove(SignInKind.claude);
      if (e.exitCode == 0) {
        // Signed in with its own login: that's what its workers use from now on.
        final s = _load(id);
        s.j.remove('claude');
        _save(id, s);
        l.claude = const _Look(SignInStatus.busy);
      } else {
        final said = _lastWords(out);
        l.claude = _Look(SignInStatus.none, error: said.isNotEmpty ? said : 'Signing in stopped before it finished');
      }
      _onChange(id);
      unawaited(look(id, true));
    });
    l.flows[SignInKind.claude] = flow;
    l.claude = const _Look(SignInStatus.busy, pending: SignInPending());
    _onChange(id);
    return null;
  }

  String? _startGithub(String id) {
    final gh = _gh;
    if (gh == null) return "The GitHub CLI (gh) isn't installed on the office's machine";
    _stop(id, SignInKind.github);
    final l = _get(id);
    final env = {..._githubEnv(id), 'BROWSER': 'true', 'GH_BROWSER': 'true'};
    Process? proc;
    var stopped = false;
    final flow = _Flow(() {
      stopped = true;
      proc?.kill();
    });
    var out = '';
    void onData(List<int> d) {
      out = _tail(out + utf8.decode(d, allowMalformed: true), 20000);
      if (l.flows[SignInKind.github] != flow || l.github.pending?.code != null) return;
      final code = RegExp(r'one-time code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})', caseSensitive: false).firstMatch(out)?[1];
      if (code == null) return;
      final url =
          RegExp(r'https://github\.com/login/device\S*').firstMatch(out)?[0] ?? 'https://github.com/login/device';
      l.github = _Look(
        SignInStatus.busy,
        pending: SignInPending(url: url, code: code),
      );
      _onChange(id);
    }

    final timer = Timer(_flow, flow.stop);
    // Over pipes, gh prints the one-time code and the page, then waits for GitHub to say yes.
    Process.start(
      gh,
      const [
        'auth',
        'login',
        '--hostname',
        'github.com',
        '--git-protocol',
        'https',
        '--web',
        '--insecure-storage',
        '--skip-ssh-key',
      ],
      workingDirectory: _home(id),
      environment: env,
      includeParentEnvironment: false,
    ).then(
      (pr) async {
        proc = pr;
        if (stopped) pr.kill();
        final a = pr.stdout.listen(onData).asFuture<void>();
        final b = pr.stderr.listen(onData).asFuture<void>();
        final exitCode = await pr.exitCode;
        await Future.wait([a, b]).catchError((_) => <void>[]);
        timer.cancel();
        if (l.flows[SignInKind.github] != flow) return;
        l.flows.remove(SignInKind.github);
        if (exitCode == 0) {
          final s = _load(id);
          s.j.remove('github');
          _save(id, s);
          l.github = const _Look(SignInStatus.busy);
        } else {
          final said = _lastWords(out);
          l.github = _Look(SignInStatus.none, error: said.isNotEmpty ? said : 'Signing in stopped before it finished');
        }
        _onChange(id);
        unawaited(look(id, true));
      },
      onError: (Object err) {
        timer.cancel();
        if (l.flows[SignInKind.github] != flow) return;
        l.flows.remove(SignInKind.github);
        l.github = _Look(SignInStatus.none, error: "Couldn't start gh: $err");
        _onChange(id);
      },
    );
    l.flows[SignInKind.github] = flow;
    l.github = const _Look(SignInStatus.busy, pending: SignInPending());
    _onChange(id);
    return null;
  }

  Future<void> _lookClaude(String id) async {
    final l = _get(id);
    if (l.flows.containsKey(SignInKind.claude)) return;
    final s = _load(id);
    final how = _how(id, s, SignInKind.claude);
    final claude = _claude;
    if (claude == null) {
      l.claude = how == SignInHow.token
          ? const _Look(SignInStatus.ok, who: 'a pasted token')
          : const _Look(SignInStatus.none, error: "Claude Code isn't installed on the office's machine");
      return;
    }
    final env = how == SignInHow.office ? _base() : apply(id, _base(), const [], SignInKind.claude);
    final r = await _run(claude, const ['auth', 'status', '--json'], env);
    Map status = {};
    try {
      final j = jsonDecode(r.out);
      if (j is Map) status = j;
    } catch (_) {
      // older Claude Code, or it failed: nothing to go on
    }
    if (l.flows.containsKey(SignInKind.claude)) return;
    final sub = status['subscriptionType'];
    final plan = sub is String && sub.isNotEmpty ? ' · ${sub[0].toUpperCase()}${sub.substring(1)}' : '';
    final token = s.claudeToken;
    final pasted = token != null
        ? (_apiKey.hasMatch(token) ? 'an API key' : 'a token from claude setup-token')
        : 'a token';
    final email = status['email'];
    // A token in the environment is taken on trust: whether it works shows when a worker starts.
    final who = status['loggedIn'] == true || how == SignInHow.token
        ? '${email is String ? email : pasted}$plan'
        : null;
    // Signed out, `claude auth status` still answers (and exits 1); anything else went wrong.
    l.claude = who != null
        ? _Look(SignInStatus.ok, who: who)
        : _Look(SignInStatus.none, error: r.out.isNotEmpty || r.last.isEmpty ? null : r.last);
    _remember(id, SignInKind.claude, how == SignInHow.office ? null : who);
  }

  Future<void> _lookGithub(String id) async {
    final l = _get(id);
    if (l.flows.containsKey(SignInKind.github)) return;
    final s = _load(id);
    final how = _how(id, s, SignInKind.github);
    final gh = _gh;
    if (gh == null) {
      l.github = const _Look(SignInStatus.none, error: "The GitHub CLI (gh) isn't installed on the office's machine");
      return;
    }
    final r = await _run(gh, const [
      'api',
      'user',
      '--jq',
      '{login, id, name}',
    ], how == SignInHow.office ? _base() : _githubEnv(id));
    if (l.flows.containsKey(SignInKind.github)) return;
    Map user = {};
    try {
      final j = r.code == 0 ? jsonDecode(r.out) : null;
      if (j is Map) user = j;
    } catch (_) {
      // not JSON: treated as not signed in
    }
    final login = user['login'];
    if (login is String && login.isNotEmpty) {
      l.github = _Look(SignInStatus.ok, who: '@$login');
      if (how != SignInHow.office) {
        final name = user['name'];
        _writeGitConfig(id, (
          name: name is String && name.trim().isNotEmpty ? name.trim() : login,
          email: '${user['id']}+$login@users.noreply.github.com',
        ));
      }
    } else {
      final signedOut = RegExp(
        'auth login|not logged in|authenticat|401|bad credentials',
        caseSensitive: false,
      ).hasMatch(r.last);
      l.github = _Look(SignInStatus.none, error: signedOut || r.last.isEmpty ? null : r.last);
    }
    _remember(id, SignInKind.github, how == SignInHow.office ? null : l.github.who);
  }

  /// Keeps who the last look found, for the next start of the office.
  void _remember(String id, SignInKind which, String? who) {
    final s = _load(id);
    if (s.seen(which) == who) return;
    final seen = s.j['seen'] is Map ? Map<String, dynamic>.from(s.j['seen'] as Map) : <String, dynamic>{};
    if (who != null) {
      seen[which.wire] = who;
    } else {
      seen.remove(which.wire);
    }
    s.j['seen'] = seen;
    _save(id, s);
  }

  Future<void> _logout(String id, SignInKind which) async {
    if (which == SignInKind.claude) {
      final claude = _claude;
      if (claude != null) await _run(claude, const ['auth', 'logout'], _claudeEnv(id));
    } else {
      final gh = _gh;
      if (gh != null) await _run(gh, const ['auth', 'logout', '--hostname', 'github.com'], _githubEnv(id));
      try {
        File(p.join(_home(id), 'gh', 'hosts.yml')).deleteSync();
      } catch (_) {
        // not there
      }
    }
  }

  /// Claude's own settings in an account's folder: its first-run questions already answered.
  void _seed(String dir, [void Function(Map<String, dynamic> c)? change]) {
    final file = p.join(dir, '.claude.json');
    var c = <String, dynamic>{};
    try {
      final j = jsonDecode(File(file).readAsStringSync());
      if (j is Map) c = Map<String, dynamic>.from(j);
    } catch (_) {
      // new
    }
    final before = jsonEncode(c);
    c['hasCompletedOnboarding'] = true;
    change?.call(c);
    if (jsonEncode(c) == before) return;
    try {
      writePrivateFile(file, jsonPretty(c));
    } catch (err) {
      stderr.writeln("agent-office: couldn't write $file: $err");
    }
  }

  /// Folders the office's own Claude trusts, the account's Claude trusts too: they're the same projects.
  void _trust(String configDir, List<String> dirs) {
    Map office;
    try {
      final base = _base();
      final dir = base['CLAUDE_CONFIG_DIR'];
      final j = jsonDecode(
        File(
          dir != null && dir.isNotEmpty ? p.join(dir, '.claude.json') : p.join(_userHome, '.claude.json'),
        ).readAsStringSync(),
      );
      if (j is! Map) return;
      office = j;
    } catch (_) {
      return;
    }
    bool trusted(String d) {
      final projects = office['projects'];
      final one = projects is Map ? projects[d] : null;
      return one is Map && one['hasTrustDialogAccepted'] == true;
    }

    if (!dirs.any(trusted)) return;
    _seed(configDir, (c) {
      final projects = c['projects'] is Map ? c['projects'] as Map : (c['projects'] = <String, dynamic>{});
      for (final d in dirs) {
        final cur = projects[d];
        projects[d] = {...(cur is Map ? cur : const {}), 'hasTrustDialogAccepted': true};
      }
    });
  }

  /// The account's git config: the office's own (included), with gh as the credentials for GitHub,
  /// so pushes go out as them, and their GitHub name and private email on commits once it's known.
  void _writeGitConfig(String id, [({String name, String email})? user]) {
    final home = _home(id);
    final base = _base();
    final xdgEnv = base['XDG_CONFIG_HOME'];
    final xdg = xdgEnv != null && xdgEnv.isNotEmpty ? xdgEnv : p.join(_userHome, '.config');
    final global = base['GIT_CONFIG_GLOBAL'];
    final includes = global != null && global.isNotEmpty
        ? [global]
        : [p.join(xdg, 'git', 'config'), p.join(_userHome, '.gitconfig')];
    final lines = [
      '# Written by Agent Office: git for this account, on top of the office machine’s own settings.',
      '[include]',
      for (final i in includes) '\tpath = ${gitQuote(i)}',
    ];
    final gh = _gh;
    if (gh != null) {
      for (final host in ['https://github.com', 'https://gist.github.com']) {
        lines.addAll([
          '[credential ${gitQuote(host)}]',
          '\thelper =',
          "\thelper = ${gitQuote("!'${gh.replaceAll("'", r"'\''")}' auth git-credential")}",
        ]);
      }
    }
    if (user != null) lines.addAll(['[user]', '\tname = ${gitQuote(user.name)}', '\temail = ${gitQuote(user.email)}']);
    final text = '${lines.join('\n')}\n';
    final file = p.join(home, 'gitconfig');
    try {
      final f = File(file);
      if (f.existsSync() && f.readAsStringSync() == text) return;
      writePrivateFile(file, text);
    } catch (err) {
      stderr.writeln("agent-office: couldn't write $file: $err");
    }
  }
}

/// signins.json: what an account picked for each sign-in, and who the last look found.
class _Saved {
  _Saved(this.j);
  final Map<String, dynamic> j;

  /// Unset: its own login, in its folder. 'token': pasted from `claude setup-token` (or an API key).
  /// 'office': the office machine's own (admins).
  String? use(SignInKind k) {
    final v = j[k.wire];
    return v is Map && v['use'] is String ? v['use'] as String : null;
  }

  String? get claudeToken {
    final v = j['claude'];
    return v is Map && v['use'] == 'token' && v['token'] is String ? v['token'] as String : null;
  }

  String? seen(SignInKind k) {
    final s = j['seen'];
    final v = s is Map ? s[k.wire] : null;
    return v is String ? v : null;
  }
}

final _controls = RegExp(r'[\p{C}]', unicode: true);

/// A value for a git config file, quoted.
String gitQuote(String v) => '"${v.replaceAll(_controls, '').replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Keeps the last [max] characters of [s], telling [cut] how many went.
String _tail(String s, int max, [void Function(int cut)? cut]) {
  if (s.length <= max) return s;
  cut?.call(s.length - max);
  return s.substring(s.length - max);
}

/// Terminal output as plain text: no colors, links or cursor moves.
String _plain(String s) => s
    .replaceAll(RegExp('\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)'), '')
    .replaceAll(RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp('\x1b[@-_]'), '')
    .replaceAll(RegExp('\r\n?'), '\n');

/// The last thing a command said, minus the link and the prompt, for an error line.
String _lastWords(String s) {
  final skip = RegExp(r'https?://|paste code|opening browser|press enter', caseSensitive: false);
  final lines = _plain(s).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !skip.hasMatch(l)).toList();
  final last = lines.isEmpty ? '' : lines.last;
  return last.length > 300 ? last.substring(0, 300) : last;
}

/// Runs a command to the end with exactly [env]; never throws. `last` is the last line it said on
/// stderr (or why it couldn't run).
Future<RunResult> runCommand(String cmd, List<String> args, Map<String, String> env, [String? input]) async {
  Process proc;
  try {
    proc = await Process.start(cmd, args, environment: env, includeParentEnvironment: false);
  } catch (err) {
    return (code: -1, out: '', last: _lastWords('$err'));
  }
  if (input != null) proc.stdin.write(input);
  unawaited(proc.stdin.close().catchError((_) {}));
  final out = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  var killed = false;
  final timer = Timer(_lookTimeout, () {
    killed = true;
    proc.kill();
  });
  final code = await proc.exitCode;
  timer.cancel();
  final stdout = await out, stderr = await err;
  return (
    code: killed ? -1 : code,
    out: stdout.trim(),
    last: _lastWords(stderr.isNotEmpty ? stderr : (killed ? 'timed out' : '')),
  );
}
