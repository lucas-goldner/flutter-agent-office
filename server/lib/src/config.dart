import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// PEM text of the certificate and key the office serves HTTPS with.
class TlsFiles {
  TlsFiles({required this.cert, required this.key});
  String cert;
  String key;
}

/// Thrown instead of `process.exit` so whoever called [loadConfig] can flush stdout/stderr first
/// (dart:io's `exit` doesn't wait for piped output). The message is already printed.
class ConfigExit implements Exception {
  ConfigExit(this.code);
  final int code;
  @override
  String toString() => 'ConfigExit($code)';
}

class Config {
  Config({
    required this.dir,
    required this.dataDir,
    required this.projectsDir,
    this.project,
    required this.host,
    required this.port,
    this.password,
    required this.passwordGenerated,
    required this.verifier,
    required this.salt,
    required this.secret,
    this.claimToken,
    required this.claimed,
    required void Function(Config) markClaimed,
    required this.agentCmd,
    required this.agentArgs,
    this.tls,
    required this.trustProxy,
    required this.iceServers,
    this.publicHost,
    this.budget,
    required this.budgetPause,
    this.webhook,
    this.city,
    this.weather,
  }) : _markClaimed = markClaimed;

  /// The office's own folder: the building's data lives in its .agent-office.
  final String dir;
  final String dataDir;

  /// Where new floors are cloned, as `<projectsDir>/<owner>/<repo>`.
  final String projectsDir;

  /// Started as `agent-office <dir>`: that checkout is a floor of its own (it's also `dir`).
  final String? project;
  final String host;
  final int port;

  /// Plaintext password, only when known: from --password, or generated and not yet claimed.
  String? password;
  final bool passwordGenerated;

  /// scrypt(password, salt): what logins are checked against and sessions are keyed on.
  final Uint8List verifier;
  final Uint8List salt;
  final String secret;

  /// One-time token that lets the first visitor see the generated password (then never again).
  final String? claimToken;
  bool claimed;
  final void Function(Config) _markClaimed;

  /// Forget the plaintext password for good once it has been shown.
  void markClaimed() => _markClaimed(this);
  final String agentCmd;
  final List<String> agentArgs;
  TlsFiles? tls;
  final bool trustProxy;
  final List<IceServer> iceServers;

  /// Address teammates SSH-tunnel to (set by deploy/aws.sh); enables invites from the office.
  final String? publicHost;

  /// Daily tracked Claude Code spend budget, USD. OpenCode/Codex spend is excluded.
  final double? budget;

  /// Refuse new hires for the rest of the day once the budget is spent.
  final bool budgetPause;

  /// Slack / Discord webhook to post to when a worker needs input or finishes ('' turns it off).
  final String? webhook;

  /// Where the office is: its sun and live weather follow this city's forecast.
  final String? city;

  /// Weather pinned for good, instead of made up or forecast.
  final Weather? weather;
}

const help = '''agent-office — a 3D office for your team and its Claude Code / OpenCode / Codex workers

Usage:
  agent-office [options]
  agent-office [dir] [options]
  agent-office prune [dir] [--dry-run] [--force]
  agent-office accounts [list|invite|revoke|role|password] ...

Runs the office. Every project is a floor of the building: ride the elevator,
pick one of the repositories your `gh` login can see, and the office clones it
into the projects folder as a new floor. Workers, terminals, boards and the
task queue on a floor all belong to that floor's checkout.

Started from anywhere, the office keeps its data in --home. Given a [dir] (or
started in a project where an office already ran), it keeps its data in
<dir>/.agent-office as it always has, and that project is one of the floors.

Commands:
  prune                   Remove leftover worker worktrees (.agent-office/worktrees/)
                          and their office/* branches. Anything with uncommitted
                          changes or unpushed commits is kept unless --force is given.
  accounts                Invite, list and revoke people's own accounts, and switch
                          the shared password off or on (see accounts --help)

Options:
      --home <dir>        Where the office keeps its data when no [dir] is given
                          (default ~/agent-office, env AGENT_OFFICE_HOME)
      --projects <dir>    Where new floors are cloned, as <dir>/<owner>/<repo>
                          (default ~/agent-office, env AGENT_OFFICE_PROJECTS)
  -p, --port <n>          Port to listen on (default 4600, env PORT)
  -H, --host <addr>       Address to bind (default 0.0.0.0)
      --password <pw>     Office password (env AGENT_OFFICE_PASSWORD).
                          Without one, a random password is generated once and
                          saved in <dir>/.agent-office/config.json
      --claim-token <t>   Show the generated password exactly once, at /claim?t=<t>
                          (env AGENT_OFFICE_CLAIM_TOKEN). After that only a hash
                          is kept and the password is never displayed again.
      --reset-password    Forget the generated password (a new one is made on the
                          next start) and exit
      --agent <cmd>       Default agent command (default "claude", env AGENT_OFFICE_AGENT)
      --agent-args <str>  Extra args for the configured agent, e.g. "--model opus"
                          Workers can also select Claude Code, OpenCode or Codex in the UI
      --tls-cert <file>   Serve HTTPS with this certificate (PEM)
      --tls-key <file>    ...and this private key (PEM)
      --self-signed       Serve HTTPS with a generated self-signed certificate
      --trust-proxy       Trust X-Forwarded-* headers (behind Caddy/nginx)
      --turn <url>        Add a TURN server for voice (repeatable), e.g.
                          turn:user:pass@turn.example.com:3478
      --budget <usd>      Daily budget for tracked Claude Code spend (env
                          AGENT_OFFICE_BUDGET). Everyone is warned when the
                          day's spend passes it. OpenCode/Codex spend is excluded
      --budget-pause      ...and no new workers can be hired until the next
                          day (env AGENT_OFFICE_BUDGET_PAUSE=1)
      --webhook <url>     Post to this Slack or Discord webhook when a worker
                          needs input or finishes (env AGENT_OFFICE_WEBHOOK).
                          Also settable from ⚙️ Settings in the office; "" turns it off
      --city <name>       Put the office in a real city, e.g. "Berlin" or
                          "Portland, Oregon" (env AGENT_OFFICE_CITY): day, night
                          and the weather outside follow its live forecast from
                          open-meteo.com. Without it the sun follows this
                          machine's clock and the weather is made up
      --weather <kind>    Pin the weather: clear, cloudy, rain, storm, snow or
                          fog (env AGENT_OFFICE_WEATHER)
      --version           Print the office's version
  -h, --help              Show this help

Voice and screen sharing need a secure context: use https (a reverse proxy,
--tls-cert/--tls-key or --self-signed) unless everyone is on localhost.
''';

Never _fail(String message, [int code = 2]) {
  stderr.writeln(message);
  throw ConfigExit(code);
}

String _takeValue(List<String> args, int i, String flag) {
  final v = i + 1 < args.length ? args[i + 1] : null;
  if (v == null || v.startsWith('--')) _fail('agent-office: $flag needs a value');
  return v;
}

final _argPart = RegExp(r'''"([^"]*)"|'([^']*)'|(\S+)''');

/// Splits `--agent-args` the way a shell would, near enough: quotes group, spaces separate.
List<String> splitArgs(String s) => [for (final m in _argPart.allMatches(s)) m.group(1) ?? m.group(2) ?? m.group(3)!];

final _turnUrl = RegExp(r'^(turns?):([^:@]+):([^@]+)@(.+)$');

IceServer parseTurn(String url) {
  // turn:user:pass@host:port  ->  { urls: 'turn:host:port', username, credential }
  final m = _turnUrl.firstMatch(url);
  if (m != null) {
    return IceServer(
      urls: ['${m[1]}:${m[4]}'],
      urlsIsList: false,
      username: Uri.decodeComponent(m[2]!),
      credential: Uri.decodeComponent(m[3]!),
    );
  }
  return IceServer(urls: [url], urlsIsList: false);
}

/// JavaScript's `Number(s)` for the strings a flag can hold: '' is 0, junk is NaN.
double _jsNumber(String? s) {
  final t = (s ?? '').trim();
  if (t.isEmpty) return 0;
  return double.tryParse(t) ?? double.nan;
}

String _resolve(String path) => p.normalize(p.absolute(path));

String homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;

String? _env(String name) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? null : v;
}

/// Where the office lives when it isn't started in a project: ~/agent-office, or $AGENT_OFFICE_HOME.
String officeHome() => _resolve(_env('AGENT_OFFICE_HOME') ?? p.join(homeDir(), 'agent-office'));

/// Keep the office's own data out of git without touching the project's .gitignore.
void excludeFromGit(String dir) {
  try {
    final r = Process.runSync('git', ['rev-parse', '--git-common-dir'], workingDirectory: dir);
    if (r.exitCode != 0) return; // not a git repo; nothing to exclude
    final gitDir = (r.stdout as String).trim();
    final exclude = _resolve(p.join(dir, gitDir, 'info', 'exclude'));
    final f = File(exclude);
    final cur = f.existsSync() ? f.readAsStringSync() : '';
    if (!cur.split('\n').any((l) => l.trim() == '.agent-office/' || l.trim() == '.agent-office')) {
      Directory(p.dirname(exclude)).createSync(recursive: true);
      f.writeAsStringSync(
        '${cur.isNotEmpty && !cur.endsWith('\n') ? '\n' : ''}.agent-office/\n',
        mode: FileMode.append,
      );
    }
  } catch (_) {
    // not a git repo (or no git); nothing to exclude
  }
}

/// Reads the flags and the environment, and the office's config.json (made on first run).
/// Where the TS exited, this prints the same thing and throws [ConfigExit].
Config loadConfig(List<String> argv) {
  var project = '';
  var home = officeHome();
  var homeGiven = _env('AGENT_OFFICE_HOME') != null;
  var projects = _env('AGENT_OFFICE_PROJECTS') != null ? _resolve(_env('AGENT_OFFICE_PROJECTS')!) : '';
  final envPort = _jsNumber(_env('PORT'));
  var port = envPort.isNaN || envPort == 0 ? 4600.0 : envPort;
  var host = '0.0.0.0';
  var password = _env('AGENT_OFFICE_PASSWORD') ?? '';
  var agentCmd = _env('AGENT_OFFICE_AGENT') ?? 'claude';
  var agentArgs = splitArgs(_env('AGENT_OFFICE_AGENT_ARGS') ?? '');
  var tlsCert = '';
  var tlsKey = '';
  var selfSigned = false;
  var trustProxy = false;
  var claimToken = _env('AGENT_OFFICE_CLAIM_TOKEN') ?? '';
  var resetPassword = false;
  var budget = _env('AGENT_OFFICE_BUDGET') ?? '';
  final pause = _env('AGENT_OFFICE_BUDGET_PAUSE');
  var budgetPause = pause != null && pause != '0';
  // Unlike the others, an empty AGENT_OFFICE_WEBHOOK counts: it turns the webhook off.
  var webhook = Platform.environment['AGENT_OFFICE_WEBHOOK'];
  var city = _env('AGENT_OFFICE_CITY') ?? '';
  var weather = _env('AGENT_OFFICE_WEATHER') ?? '';
  final iceServers = <IceServer>[
    const IceServer(urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302']),
  ];

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '-h':
      case '--help':
        stdout.write(help);
        throw ConfigExit(0);
      case '-p':
      case '--port':
        port = _jsNumber(_takeValue(argv, i++, a));
      case '-H':
      case '--host':
        host = _takeValue(argv, i++, a);
      case '--password':
        password = _takeValue(argv, i++, a);
      case '--agent':
        agentCmd = _takeValue(argv, i++, a);
      case '--agent-args':
        agentArgs = splitArgs(_takeValue(argv, i++, a));
      case '--tls-cert':
        tlsCert = _takeValue(argv, i++, a);
      case '--tls-key':
        tlsKey = _takeValue(argv, i++, a);
      case '--self-signed':
        selfSigned = true;
      case '--trust-proxy':
        trustProxy = true;
      case '--claim-token':
        claimToken = _takeValue(argv, i++, a);
      case '--reset-password':
        resetPassword = true;
      case '--turn':
        iceServers.add(parseTurn(_takeValue(argv, i++, a)));
      case '--budget':
        budget = _takeValue(argv, i++, a);
      case '--budget-pause':
        budgetPause = true;
      case '--webhook':
        webhook = _takeValue(argv, i++, a);
      case '--home':
        home = _resolve(_takeValue(argv, i++, a));
        homeGiven = true;
      case '--projects':
        projects = _resolve(_takeValue(argv, i++, a));
      case '--city':
        city = _takeValue(argv, i++, a);
      case '--weather':
        weather = _takeValue(argv, i++, a);
      default:
        if (a.startsWith('-')) {
          stderr.writeln('agent-office: unknown option $a\n');
          stderr.write(help);
          throw ConfigExit(2);
        }
        project = _resolve(a);
    }
  }

  // An office already runs in this project (started here before there were floors): carry on with
  // it, its workers and its password, rather than open an empty building somewhere else.
  final cwd = Directory.current.path;
  if (project.isEmpty && !homeGiven && cwd != home && File(p.join(cwd, '.agent-office', 'config.json')).existsSync()) {
    project = cwd;
  }
  if (project.isNotEmpty && FileSystemEntity.typeSync(project) == FileSystemEntityType.notFound) {
    _fail('agent-office: directory not found: $project');
  }
  final dir = project.isNotEmpty ? project : home;
  // New floors go next to the office's data when it has a home of its own, and never into a project.
  final projectsDir = projects.isNotEmpty ? projects : (project.isNotEmpty ? p.join(homeDir(), 'agent-office') : home);
  if (port.isNaN || port != port.truncateToDouble() || port <= 0 || port > 65535) {
    _fail('agent-office: invalid --port');
  }
  final budgetUsd = budget.isNotEmpty ? _jsNumber(budget.replaceFirst(RegExp(r'^\$'), '')) : null;
  if (budgetUsd != null && !(budgetUsd > 0)) {
    _fail('agent-office: --budget needs an amount in dollars, e.g. --budget 20');
  }
  weather = weather.trim().toLowerCase();
  if (weather.isNotEmpty && !weathers.any((w) => w.wire == weather)) {
    _fail('agent-office: --weather is one of ${weathers.map((w) => w.wire).join(', ')}');
  }

  final dataDir = p.join(dir, '.agent-office');
  final data = Directory(dataDir);
  if (!data.existsSync()) {
    data.createSync(recursive: true);
    chmodPrivate(dataDir, '700');
  }
  if (project.isNotEmpty) excludeFromGit(dir);

  final cfgPath = p.join(dataDir, 'config.json');
  var stored = <String, dynamic>{};
  try {
    final v = jsonDecode(File(cfgPath).readAsStringSync());
    if (v is Map) stored = Map<String, dynamic>.from(v);
  } catch (_) {
    // first run
  }
  void save() => writePrivateFile(cfgPath, jsonPretty(stored));
  if (stored['secret'] is! String || (stored['secret'] as String).isEmpty) stored['secret'] = toHex(randomBytes(32));
  if (stored['salt'] is! String || (stored['salt'] as String).isEmpty) stored['salt'] = toHex(randomBytes(16));
  final salt = fromHex(stored['salt'] as String);
  Uint8List hash(String pw) => scryptSync(pw, salt, 32);

  if (resetPassword) {
    stored.remove('password');
    stored.remove('verifier');
    stored.remove('claimedAt');
    save();
    stdout.writeln('agent-office: password forgotten — a new one is generated on the next start');
    throw ConfigExit(0);
  }

  Uint8List verifier;
  var passwordGenerated = false;
  if (password.isNotEmpty) {
    verifier = hash(password);
  } else {
    passwordGenerated = true;
    final storedVerifier = stored['verifier'];
    if (storedVerifier is String && storedVerifier.isNotEmpty) {
      verifier = fromHex(storedVerifier);
      password = stored['password'] is String ? stored['password'] as String : '';
    } else {
      // New password (or a legacy plaintext one): keep the plaintext only until it's been shown.
      password = stored['password'] is String && (stored['password'] as String).isNotEmpty
          ? stored['password'] as String
          : base64UrlNoPad(randomBytes(9));
      stored['password'] = password;
      verifier = hash(password);
      stored['verifier'] = toHex(verifier);
      stored.remove('claimedAt');
    }
  }
  save();

  TlsFiles? tls;
  if (tlsCert.isNotEmpty || tlsKey.isNotEmpty) {
    if (tlsCert.isEmpty || tlsKey.isEmpty) _fail('agent-office: --tls-cert and --tls-key go together');
    tls = TlsFiles(cert: File(tlsCert).readAsStringSync(), key: File(tlsKey).readAsStringSync());
  } else if (selfSigned) {
    tls = TlsFiles(cert: '', key: ''); // filled in by ensureSelfSigned()
  }

  final claimedAt = stored['claimedAt'];
  return Config(
    dir: dir,
    dataDir: dataDir,
    projectsDir: projectsDir,
    project: project.isEmpty ? null : project,
    host: host,
    port: port.toInt(),
    password: password.isEmpty ? null : password,
    passwordGenerated: passwordGenerated,
    verifier: verifier,
    salt: salt,
    secret: stored['secret'] as String,
    claimToken: claimToken.isEmpty ? null : claimToken,
    claimed: claimedAt is num && claimedAt != 0,
    markClaimed: (cfg) {
      stored['claimedAt'] = DateTime.now().millisecondsSinceEpoch;
      stored.remove('password');
      save();
      cfg.claimed = true;
      cfg.password = null;
    },
    agentCmd: agentCmd,
    agentArgs: agentArgs,
    tls: tls,
    trustProxy: trustProxy,
    iceServers: iceServers,
    publicHost: _env('AGENT_OFFICE_PUBLIC_HOST'),
    budget: budgetUsd,
    budgetPause: budgetPause,
    webhook: webhook,
    city: city.trim().isEmpty ? null : city.trim(),
    weather: weather.isEmpty ? null : Weather.parse(weather),
  );
}

/// Fills in `--self-signed`'s certificate: the one made on an earlier start, or a new one from
/// `openssl` (the Node server used the `selfsigned` package: RSA 2048, CN=agent-office, 825 days).
Future<void> ensureSelfSigned(Config cfg) async {
  final tls = cfg.tls;
  if (tls == null || tls.cert.isNotEmpty) return;
  final certPath = p.join(cfg.dataDir, 'tls-cert.pem');
  final keyPath = p.join(cfg.dataDir, 'tls-key.pem');
  if (File(certPath).existsSync() && File(keyPath).existsSync()) {
    cfg.tls = TlsFiles(cert: File(certPath).readAsStringSync(), key: File(keyPath).readAsStringSync());
    return;
  }
  final tmpCert = '$certPath.tmp';
  final tmpKey = '$keyPath.tmp';
  ProcessResult r;
  try {
    r = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '825', //
      '-subj', '/CN=agent-office', '-keyout', tmpKey, '-out', tmpCert,
    ]);
  } on ProcessException {
    throw StateError("--self-signed needs openssl to make a certificate, and it isn't installed");
  }
  if (r.exitCode != 0) {
    throw StateError("openssl couldn't make a self-signed certificate: ${(r.stderr as String).trim()}");
  }
  final cert = File(tmpCert).readAsStringSync();
  final key = File(tmpKey).readAsStringSync();
  File(tmpCert).deleteSync();
  File(tmpKey).deleteSync();
  writePrivateFile(certPath, cert);
  writePrivateFile(keyPath, key);
  cfg.tls = TlsFiles(cert: cert, key: key);
}
