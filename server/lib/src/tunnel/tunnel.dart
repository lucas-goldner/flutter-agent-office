import 'dart:async';
import 'dart:io';

import '../browser.dart';
import 'forwarder.dart';
import 'office.dart';
import 'session.dart';
import 'ssh.dart';
import 'wire.dart';

// `agent-office tunnel`, run on your own computer: every web server a worker starts in an office
// somewhere else opens on the same port here, by itself, and closes when the worker stops it. It
// asks the office which servers there are every couple of seconds (wire.dart), and listens on each
// one's port (forwarder.dart). Given an SSH address it opens the tunnel to the office too (ssh.dart).
// Ported from src/server/tunnel/index.ts.

const _defaultPort = 4600;

/// How often the office is asked which servers the workers run. It looks itself every 4 seconds.
const _pollMs = 2000;

const tunnelHelp =
    '''agent-office tunnel — open every worker's web server on this computer, by itself

Usage:
  agent-office tunnel [where] [options] [-- <ssh options>]

Run it on your own computer and leave it running. Whenever a worker in the office
starts a web server (npm run dev, a preview build), the same port opens here:
http://localhost:5173 on this computer is the worker's localhost:5173. It closes
again when the worker stops the server. No command per server, nothing to restart.

Where the office is:
  office@203.0.113.7      An SSH address (the one 👥 Invite teammates shows, also
  ssh://office@host:2222  as ssh://, or a Host from your ssh config). Opens the
                          tunnel to the office as well, and the office in your
                          browser, and opens the tunnel again when it drops
  http://localhost:4600   An office you can already open in a browser: through a
  https://office.example  tunnel that's running, on a domain, or on your tailnet.
                          The default is http://localhost:4600

It signs in like a browser does. The first time it asks for the office password
(or your name and your own) and keeps the session for next time.

Options:
  -p, --port <n>          With an SSH address: the port the office gets on this
                          computer (default: the same as --office-port)
      --office-port <n>   With an SSH address: the office's port on its own
                          machine (default $_defaultPort)
      --name <name>       Sign in with this account (env AGENT_OFFICE_NAME)
      --password <pw>     The password, instead of being asked for it
                          (env AGENT_OFFICE_PASSWORD)
      --no-open           With an SSH address: don't open the office in a browser
      --insecure          Accept a certificate nobody vouches for (--self-signed)
  -h, --help              Show this help

Everything after -- goes to ssh, e.g.  agent-office tunnel office@host -- -i ~/.ssh/office
''';

/// The command line, read.
class TunnelOptions {
  TunnelOptions({
    this.where = '',
    this.port,
    this.officePort = _defaultPort,
    required this.credentials,
    this.open = true,
    this.insecure = false,
    this.ssh = const [],
  });

  String where;

  /// The port the office gets on this computer, over SSH.
  int? port;
  int officePort;
  Credentials credentials;
  bool open;
  bool insecure;
  List<String> ssh;
}

/// What's wrong with the command line.
class TunnelUsageError implements Exception {
  TunnelUsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

int _parsePort(String v, String flag) {
  final n = int.tryParse(v);
  if (n == null || n < 1 || n > 65535) throw TunnelUsageError('$flag needs a port number');
  return n;
}

String? _nonEmpty(String? v) => v == null || v.isEmpty ? null : v;

/// Reads the command line; throws [TunnelUsageError]. Null for --help.
TunnelOptions? parseTunnelArgs(List<String> argv, [Map<String, String>? env]) {
  env ??= Platform.environment;
  var name = _nonEmpty(env['AGENT_OFFICE_NAME']);
  var password = _nonEmpty(env['AGENT_OFFICE_PASSWORD']);
  final o = TunnelOptions(
    credentials: (name: name, password: password),
    open: _nonEmpty(env['AGENT_OFFICE_NO_OPEN']) == null,
  );
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    String value() {
      if (++i >= argv.length) throw TunnelUsageError('$a needs a value');
      return argv[i];
    }

    if (a == '-h' || a == '--help') return null;
    if (a == '--') {
      o.ssh = argv.sublist(i + 1);
      break;
    } else if (a == '-p' || a == '--port') {
      o.port = _parsePort(value(), a);
    } else if (a == '--office-port') {
      o.officePort = _parsePort(value(), a);
    } else if (a == '--name') {
      name = value();
    } else if (a == '--password') {
      password = value();
    } else if (a == '--no-open') {
      o.open = false;
    } else if (a == '--insecure') {
      o.insecure = true;
    } else if (a.startsWith('-')) {
      throw TunnelUsageError('unknown option $a');
    } else if (o.where.isNotEmpty) {
      throw TunnelUsageError('one office at a time: ${o.where} or $a?');
    } else {
      o.where = a;
    }
  }
  o.credentials = (name: name, password: password);
  return o;
}

/// The office's address, when [where] is one a browser could open; an SSH address isn't.
Uri? officeUrl(String where) {
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(where)) return null;
  final u = Uri.tryParse(where);
  if (u == null || u.host.isEmpty) throw TunnelUsageError("$where isn't an address");
  return u;
}

void _say([String line = '']) => stdout.writeln(line);

String _describe(Forward f) {
  final what = f.title == f.command ? f.title : '${f.title} — ${f.command}';
  final who = [f.worker, f.floor].whereType<String>().where((s) => s.isNotEmpty).join(' on ');
  return who.isNotEmpty ? '$what ($who)' : what;
}

/// Runs until Ctrl-C; returns an exit code only when it can't go on.
Future<int> tunnelCommand(List<String> argv) async {
  TunnelOptions? parsed;
  Uri? url;
  try {
    parsed = parseTunnelArgs(argv);
    if (parsed != null) url = officeUrl(parsed.where.isNotEmpty ? parsed.where : 'http://localhost:$_defaultPort');
  } on TunnelUsageError catch (e) {
    stderr.writeln('agent-office tunnel: ${e.message} (see agent-office tunnel --help)');
    return 2;
  }
  if (parsed == null) {
    stdout.writeln(tunnelHelp);
    return 0;
  }
  final o = parsed;
  int fail(String why) {
    stderr.writeln('agent-office tunnel: $why');
    return 1;
  }

  final overSsh = url == null;
  final office = TunnelOffice(url ?? Uri.parse('http://localhost:${o.port ?? o.officePort}'), insecure: o.insecure);
  final forwarder = Forwarder(
    office,
    ForwardEvents(
      opened: (f) => _say('  + http://localhost:${f.port}  ${_describe(f)}'),
      closed: (f) => _say('  - localhost:${f.port} closed: ${f.worker ?? 'the worker'} stopped the server'),
      busy: (f, why) => _say(
        why == PortBusy.denied
            ? "  ! localhost:${f.port} can't be opened on this computer without root: ${_describe(f)}"
            : "  ! localhost:${f.port} is already in use on this computer, so it isn't opened: ${_describe(f)}\n"
                  "    Stop what's running there and it opens by itself.",
      ),
    ),
    // The office's own port here is the office, whatever a worker runs on that port over there.
    skip: office.local ? {office.port} : const {},
  );

  SshTunnel? ssh;
  Future<void> close() async {
    ssh?.stop();
    await forwarder.close();
    office.close();
  }

  final stopped = Completer<int>();
  void stop(ProcessSignal _) {
    if (stopped.isCompleted) return;
    _say('\n  closed');
    stopped.complete(0);
  }

  final subs = [
    ProcessSignal.sigint.watch().listen(stop),
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop),
  ];

  Future<int> run() async {
    _say('\n  🔌 agent-office tunnel\n');
    if (overSsh) {
      // A tunnel that's already open (this command running twice, or the one from 👥 Invite teammates) will do.
      if (await office.up()) {
        _say('  the office is already open at ${office.origin}: using that tunnel');
      } else {
        _say('  opening the tunnel to ${o.where}…');
        ssh = SshTunnel(
          sshArgs(o.where, office.port, o.officePort, o.ssh),
          office,
          dropped: () => _say('  … the tunnel dropped: opening it again'),
          back: () => _say('  ✓ the tunnel is open again'),
        );
        final err = await ssh!.open();
        if (err.isNotEmpty) {
          return fail(
            '$err. Is localhost:${office.port} free on this computer (--port picks another), and is your SSH key '
            'invited to the office?',
          );
        }
      }
    } else if (!await office.up()) {
      return fail(
        'no office answers at ${office.origin}. Open the tunnel to it first, or give its SSH address: '
        'agent-office tunnel office@<address>',
      );
    }
    _say('  the office: ${office.origin}${overSsh ? ' (over SSH to ${o.where})' : ''}');
    if (ssh != null && o.open) openBrowser(office.origin);

    final key = overSsh ? 'ssh:${o.where}:${o.officePort}' : office.origin;
    try {
      final err = await tunnelSignIn(office, key, o.credentials, _say);
      if (err.isNotEmpty) return fail(err);
    } catch (e) {
      return fail("couldn't sign in: $e");
    }

    _say(
      '\n  Every web server a worker starts opens on the same port here. Leave this running; Ctrl-C closes them all.\n',
    );
    var reachable = true;
    var first = true;
    while (!stopped.isCompleted) {
      Object? list;
      try {
        list = await office.forwards();
      } catch (_) {
        list = null;
      }
      if (list == null) {
        if (reachable) _say("  … the office isn't answering: still trying");
        reachable = false;
      } else if (list == ForwardsRefused.old) {
        return fail(
          "this office is a version from before it could list its workers' servers. Upgrade it (⬆️ Upgrade the "
          "office in its ☰ menu, or the deploy script's update), then run this again.",
        );
      } else if (list == ForwardsRefused.signedOut) {
        forgetSession(office, key);
        _say('  … signed out of the office (the password changed, or the session ran out)');
        String err;
        try {
          err = await tunnelSignIn(office, key, o.credentials, _say);
        } catch (e) {
          err = '$e';
        }
        if (err.isNotEmpty) return fail(err);
        continue;
      } else if (list is ForwardList) {
        if (!reachable) _say('  ✓ the office is answering again');
        reachable = true;
        await forwarder.sync(list.items);
        if (first && list.items.isEmpty) {
          _say('  No worker is running a web server yet. Ask one to start its dev server and it shows up here.');
        } else if (first && !overSsh && office.local && forwarder.ports().isEmpty) {
          // Every port taken, at an office on localhost that this command didn't tunnel to itself.
          _say(
            "  If this office runs on this computer, there's nothing to tunnel: its workers' servers are on localhost already.",
          );
        }
        first = false;
      }
      await Future.any([Future<void>.delayed(const Duration(milliseconds: _pollMs)), stopped.future]);
    }
    return 0;
  }

  try {
    return await Future.any([run(), stopped.future]);
  } finally {
    for (final s in subs) {
      await s.cancel();
    }
    await close();
  }
}
