import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_office_server/src/accounts.dart' show accountsCommand;
import 'package:agent_office_server/src/building.dart' show tildify;
import 'package:agent_office_server/src/config.dart';
import 'package:agent_office_server/src/hook.dart' show runHook;
import 'package:agent_office_server/src/prune.dart' show prune;
import 'package:agent_office_server/src/ptyhost.dart';
import 'package:agent_office_server/src/ptys.dart' show ptyHostCommand;
import 'package:agent_office_server/src/server.dart';
import 'package:agent_office_server/src/setup.dart' show interactive, setupCommand, welcome;
import 'package:agent_office_server/src/upgrade.dart' show Upgrader;

/// The office's one executable: the CLI and the server, plus the PTY host and the hook helper the
/// office runs itself.
Future<void> main(List<String> argv) async {
  final cmd = argv.isNotEmpty ? argv.first : '';
  if (cmd == ptyHostCommand) return runPtyHost(argv.sublist(1));
  if (cmd == 'hook') return _exit(await runHook(argv.sublist(1)));
  if (cmd == 'prune') return _exit(await prune(argv.sublist(1)));
  if (cmd == 'accounts') return _exit(accountsCommand(argv.sublist(1)));
  if (cmd == 'setup') return _exit(await setupCommand(argv.sublist(1)));
  if (cmd == '--version') {
    // Without the environment, the upgrader only works out the version (it never checks GitHub).
    stdout.writeln(
      Upgrader((_) {}, () {}, environment: const {}, exeDir: officeExeDir()).version.replaceFirst(RegExp('^v'), ''),
    );
    return _exit(0);
  }

  final Config cfg;
  try {
    cfg = loadConfig(argv);
    await ensureSelfSigned(cfg);
  } on ConfigExit catch (e) {
    return _exit(e.code);
  } on StateError catch (e) {
    stderr.writeln('agent-office: ${e.message}');
    return _exit(1);
  }

  final atTerminal = interactive();
  // A new office started in a terminal: where projects go, GitHub, and the first floor, before it opens.
  if (cfg.project == null && atTerminal) await welcome(cfg);

  // Last line of defense: one bad request must never take down every running worker.
  runZonedGuarded(
    () => _serve(cfg, atTerminal),
    (err, st) => stderr.writeln('agent-office: unhandled error $err\n$st'),
  );
}

Future<void> _serve(Config cfg, bool atTerminal) async {
  var closing = false;
  late final Office office;

  // SIGTERM is a restart (an upgrade, a plain `kill`): workers keep running in their terminal host
  // and the next office picks them back up. Ctrl+C closes the office and stops them. (A systemd
  // restart stops the whole service, host included.)
  Future<void> stop(ProcessSignal signal) async {
    if (closing) return _exit(1);
    closing = true;
    final keep = signal == ProcessSignal.sigterm;
    stdout.writeln(
      keep ? '\n  closing the office — workers keep running for the next one…' : '\n  closing the office…',
    );
    try {
      await office.shutdown(keep: keep).timeout(const Duration(seconds: 10));
    } catch (err) {
      stderr.writeln('agent-office: $err');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _exit(0);
  }

  try {
    // An upgrade restarts the office the way SIGTERM does; systemd (Restart=always) then starts the
    // new version, which wakes every worker.
    office = await startServer(cfg, restart: () => unawaited(stop(ProcessSignal.sigterm)));
  } on SocketException catch (e) {
    final inUse = const {48, 98, 10048}.contains(e.osError?.errorCode);
    stderr.writeln(
      inUse ? 'agent-office: port ${cfg.port} is already in use (try --port)' : 'agent-office: ${e.message}',
    );
    return _exit(1);
  } catch (e) {
    stderr.writeln('agent-office: ${e is StateError ? e.message : e}');
    return _exit(1);
  }

  final scheme = cfg.tls != null ? 'https' : 'http';
  final everywhere = cfg.host == '0.0.0.0' || cfg.host == '::';
  final loopback = cfg.host == 'localhost' || cfg.host == '::1' || cfg.host.startsWith('127.');
  // Where this machine's browser finds the office: localhost, unless it's bound to one other address.
  final here = '$scheme://${everywhere || loopback ? 'localhost' : cfg.host}:${cfg.port}';
  final urls = <String>{here};
  if (everywhere) {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) urls.add('$scheme://${a.address}:${cfg.port}');
      }
    }
  }

  String floorsLine() {
    final floors = office.floors();
    final where = 'new ones are cloned into ${tildify(office.projectsDir())}';
    if (floors.isEmpty) return '🛗 no floors yet — ride the elevator in the office to add a project ($where)';
    return '🛗 ${floors.length} floor${floors.length == 1 ? '' : 's'}: ${floors.map((f) => f.def.name).join(', ')} ($where)';
  }

  String passwordLine() {
    if (!office.accounts.sharedPassword) {
      return 'off — everyone signs in with their own account (agent-office accounts)';
    }
    if (!cfg.passwordGenerated) return '(from --password / AGENT_OFFICE_PASSWORD)';
    if ((cfg.claimToken ?? '').isNotEmpty && !cfg.claimed) {
      return 'shown exactly once to whoever opens the claim link (/claim?t=…)';
    }
    if (cfg.claimed || (cfg.password ?? '').isEmpty) {
      return '(already claimed — never shown again; reset with --reset-password)';
    }
    return cfg.password!;
  }

  // Someone started it in a terminal: a link that signs them in once, opened in their browser, so
  // there's no password to copy. Not for an office that's claimed from a link (deploy/provision.sh)
  // or signed in to with accounts only.
  var signIn = '';
  var opened = false;
  if (atTerminal && office.accounts.sharedPassword && (cfg.claimToken ?? '').isEmpty) {
    signIn = here + office.signInLink();
    if (cfg.open) opened = _openBrowser(signIn);
  }

  final agent = office.resolvedAgent;
  // Started in a project that's still one of the floors (it can be taken off like any other).
  final local = cfg.project != null && office.floors().any((f) => p.normalize(p.absolute(f.def.dir)) == cfg.project);
  stdout.writeln(
    '''

  🏢  agent-office is open${local ? ' for ${cfg.project}' : ''}

  ${floorsLine()}

  ${urls.join('\n  ')}${loopback ? '\n  (only this computer can open it: --host 0.0.0.0 lets your network in)' : ''}
${signIn.isNotEmpty ? '\n  sign in: $signIn\n           ${opened ? 'opened in your browser; ' : ''}the link works once\n' : ''}
  password: ${passwordLine()}
  default agent: ${[agent ?? '${cfg.agentCmd} (via login shell)', ...cfg.agentArgs].join(' ')}
  choose Claude Code or OpenCode when hiring or queueing a task
${cfg.tls != null || loopback ? '' : '\n  tip: voice & screen share need https off localhost — use a reverse proxy or --self-signed\n'}''',
  );

  ProcessSignal.sigint.watch().listen((s) => unawaited(stop(s)));
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((s) => unawaited(stop(s)));
}

/// Opens the office in this computer's browser. Not over SSH, in CI, or on a Linux box without a
/// desktop: nobody would see it there.
bool _openBrowser(String url) {
  final env = Platform.environment;
  bool set(String k) => (env[k] ?? '').isNotEmpty;
  if (set('SSH_CONNECTION') || set('SSH_TTY') || set('CI')) return false;
  if (Platform.isLinux && !set('DISPLAY') && !set('WAYLAND_DISPLAY')) return false;
  final (cmd, args) = Platform.isMacOS
      ? ('open', [url])
      : Platform.isWindows
      ? ('rundll32', ['url.dll,FileProtocolHandler', url])
      : ('xdg-open', [url]);
  unawaited(Process.start(cmd, args, mode: ProcessStartMode.detached).then((_) {}, onError: (Object _) {}));
  return true;
}

/// Exits once what was printed is out: dart:io's `exit` doesn't wait for piped output.
Future<void> _exit(int code) async {
  try {
    await Future.wait([stdout.flush(), stderr.flush()]).timeout(const Duration(seconds: 2));
  } catch (_) {
    // a closed pipe: nothing more to say
  }
  exit(code);
}
