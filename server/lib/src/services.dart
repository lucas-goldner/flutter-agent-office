import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

// Finds the web servers workers start (npm run dev, python -m http.server, ...) so teammates can
// reach them through the office: every few seconds, list the TCP ports this user's processes
// listen on, and credit each one to the worker whose terminal started it. Servers no worker
// started (yours, from your own terminal) aren't listed.

const _scanInterval = Duration(milliseconds: 4000);

/// A port that stopped listening this recently still gets a "stopped" page instead of the office.
const _goneMs = 24 * 60 * 60000;

/// Listeners that aren't something to review: browsers driven by tests, their helpers.
final _noise = RegExp(r'--remote-debugging-port|--type=(?:renderer|gpu-process|utility|zygote)|crashpad');

class ServiceOwner {
  const ServiceOwner({required this.workerId, this.pid, required this.agent, required this.cwd, required this.root});

  final String workerId;

  /// The worker's PTY process, when it's running.
  final int? pid;

  /// Claude itself, as opposed to a shell: its own ports (IDE, OAuth callbacks) aren't services.
  final bool agent;

  /// Its working directory: the project, or its own worktree.
  final String cwd;

  /// Its floor's checkout, which everyone on that floor shares.
  final String root;
}

class _Listener {
  _Listener(this.pid, this.host, this.port);

  final int pid;
  final String host;
  final int port;
}

class _Proc {
  _Proc(this.ppid, this.args);

  final int ppid;
  final String args;
}

class _Tracked {
  _Tracked({
    required this.port,
    required this.workerId,
    required this.host,
    required this.pid,
    required this.command,
    required this.cwd,
    required this.since,
  });

  final int port;
  String workerId;
  String host;
  int pid;
  String command;
  String? cwd;
  int since;
  String? title;

  /// Whether it answered HTTP; only those are published.
  bool http = false;
  int probedAt = 0;
  int probes = 0;
  bool probing = false;

  ServiceInfo get info => ServiceInfo(
    port: port,
    host: host,
    pid: pid,
    command: command,
    workerId: workerId,
    cwd: cwd,
    title: title,
    since: since,
  );
}

Future<String> _run(String cmd, List<String> args) async {
  try {
    final proc = await Process.start(cmd, args);
    proc.stdin.close().ignore();
    proc.stderr.drain<void>().ignore();
    final timer = Timer(const Duration(seconds: 5), proc.kill);
    final out = await proc.stdout.transform(utf8.decoder).join();
    await proc.exitCode;
    timer.cancel();
    return out;
  } catch (_) {
    return '';
  }
}

final _addrPattern = RegExp(r'^(.*):(\d+)$');

/// "127.0.0.1:5173", "[::1]:5173", "*:5173" -> host + port.
(String, int)? _splitAddr(String addr) {
  final m = _addrPattern.firstMatch(addr.trim());
  if (m == null) return null;
  var host = m[1]!.replaceAll(RegExp(r'^\[|\]$'), '').replaceFirst(RegExp(r'%.*$'), '');
  if (host == '*' || host == '0.0.0.0' || host == '::' || host == '') host = '127.0.0.1';
  return (host, int.parse(m[2]!));
}

String? _uid;

Future<String> _currentUid() async => _uid ??= (await _run('id', ['-u'])).trim();

Future<List<_Listener>> _listeners() async {
  final out = <_Listener>[];
  if (Platform.isLinux) {
    // `ss -p` shows the owning process for this user's sockets without root.
    final text = await _run('ss', ['-H', '-l', '-t', '-n', '-p']);
    if (text.isNotEmpty) {
      for (final line in text.split('\n')) {
        final cols = line.trim().split(RegExp(r'\s+'));
        final addr = cols.length > 3 ? _splitAddr(cols[3]) : null;
        if (addr == null) continue;
        for (final m in RegExp(r'pid=(\d+)').allMatches(line)) {
          out.add(_Listener(int.parse(m[1]!), addr.$1, addr.$2));
        }
      }
      return out;
    }
  }
  final text = await _run('lsof', ['-nP', '-a', '-iTCP', '-sTCP:LISTEN', '-u', await _currentUid(), '-Fpn']);
  var pid = 0;
  for (final line in text.split('\n')) {
    if (line.startsWith('p')) {
      pid = int.tryParse(line.substring(1)) ?? 0;
    } else if (line.startsWith('n') && pid != 0) {
      final addr = _splitAddr(line.substring(1));
      if (addr != null) out.add(_Listener(pid, addr.$1, addr.$2));
    }
  }
  return out;
}

final _psLine = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$');

Future<Map<int, _Proc>> _processes() async {
  final procs = <int, _Proc>{};
  final text = await _run('ps', ['-A', '-ww', '-o', 'pid=', '-o', 'ppid=', '-o', 'args=']);
  for (final line in text.split('\n')) {
    final m = _psLine.firstMatch(line);
    if (m != null) procs[int.parse(m[1]!)] = _Proc(int.parse(m[2]!), m[3]!);
  }
  return procs;
}

/// Working directories of processes (Linux: /proc; macOS: one lsof call).
Future<Map<int, String>> _cwds(List<int> pids) async {
  final out = <int, String>{};
  if (pids.isEmpty) return out;
  if (Platform.isLinux) {
    await Future.wait(
      pids.map((pid) async {
        try {
          out[pid] = await Link('/proc/$pid/cwd').target();
        } catch (_) {
          out[pid] = '';
        }
      }),
    );
    return out;
  }
  final text = await _run('lsof', ['-a', '-d', 'cwd', '-p', pids.join(','), '-Fpn']);
  var pid = 0;
  for (final line in text.split('\n')) {
    if (line.startsWith('p')) {
      pid = int.tryParse(line.substring(1)) ?? 0;
    } else if (line.startsWith('n') && pid != 0) {
      out[pid] = line.substring(1);
    }
  }
  return out;
}

final _workerEnv = RegExp('(?:^|\x00)AGENT_OFFICE_WORKER_ID=([^\x00]+)');

/// The worker a process was started by, from the env var every worker's processes inherit (Linux).
Future<String?> _workerFromEnv(int pid) async {
  if (!Platform.isLinux) return null;
  String env;
  try {
    env = latin1.decode(await File('/proc/$pid/environ').readAsBytes());
  } catch (_) {
    env = '';
  }
  return _workerEnv.firstMatch(env)?[1];
}

final _runtime = RegExp(r'^(node|nodejs|bun|deno|tsx|ts-node)$');

/// "node /x/node_modules/.bin/vite --port 5173" -> "vite --port 5173"
String shortCommand(String args) {
  final parts = args.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  final words = [
    for (var i = 0; i < parts.length; i++)
      parts[i].contains('/') && !parts[i].startsWith('--') && (i == 0 || !parts[i].contains('='))
          ? p.posix.basename(parts[i])
          : parts[i],
  ];
  if (words.length > 1 && _runtime.hasMatch(words[0])) words.removeAt(0);
  final s = words.join(' ');
  return s.length > 80 ? '${s.substring(0, 79)}…' : s;
}

bool _inside(String dir, String child) {
  final rel = p.relative(child, from: dir);
  return rel == '.' || (rel.isNotEmpty && !rel.startsWith('..') && !p.isAbsolute(rel));
}

final _titlePattern = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false);
final _titleEnd = RegExp(r'</title>', caseSensitive: false);

/// Does it speak HTTP? And what's the `<title>` of its front page?
Future<({bool ok, String? title})> _probe(String host, int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 2500);
  try {
    return await () async {
      final req = await client.getUrl(Uri(scheme: 'http', host: host, port: port, path: '/'));
      req.headers.set(HttpHeaders.hostHeader, 'localhost:$port');
      req.headers.set(HttpHeaders.acceptHeader, 'text/html,*/*');
      req.headers.set(HttpHeaders.userAgentHeader, 'agent-office');
      final res = await req.close();
      final type = res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      if (!RegExp('text/html', caseSensitive: false).hasMatch(type)) {
        res.drain<void>().ignore();
        return (ok: true, title: null);
      }
      var body = '';
      try {
        await for (final chunk in res.transform(const Utf8Decoder(allowMalformed: true))) {
          body += chunk;
          if (body.length > 64 * 1024 || _titleEnd.hasMatch(body)) break;
        }
      } catch (_) {
        // A connection cut mid-page still tells what arrived.
      }
      final t = _titlePattern.firstMatch(body)?[1];
      final title = t == null ? null : _decodeEntities(t).replaceAll(RegExp(r'\s+'), ' ').trim();
      final clipped = title == null || title.isEmpty ? null : (title.length > 100 ? title.substring(0, 100) : title);
      return (ok: true, title: clipped);
    }().timeout(const Duration(milliseconds: 2500));
  } catch (_) {
    return (ok: false, title: null);
  } finally {
    client.close(force: true);
  }
}

const _entities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', '#39': "'", '#x27': "'", 'nbsp': ' '};

String _decodeEntities(String s) =>
    s.replaceAllMapped(RegExp(r'&(amp|lt|gt|quot|#39|#x27|nbsp);'), (m) => _entities[m[1]] ?? '');

/// The service on a port, or [ServiceLookupGone] when one was there recently.
sealed class ServiceLookup {}

class ServiceLookupFound extends ServiceLookup {
  ServiceLookupFound(this.info);
  final ServiceInfo info;
}

class ServiceLookupGone extends ServiceLookup {}

class Services {
  /// [owners] lists the workers with, for each, its PTY's pid when it's running.
  Services(this._owners, this._onChange);

  final List<ServiceOwner> Function() _owners;
  final void Function(List<ServiceInfo> items) _onChange;
  final _tracked = <int, _Tracked>{};
  final _gone = <int, int>{};
  Timer? _timer;
  bool _scanning = false;
  String _published = '[]';

  void start() {
    scan();
    _timer = Timer.periodic(_scanInterval, (_) => scan());
  }

  void stop() => _timer?.cancel();

  /// The web servers (listeners that answered HTTP), by port.
  List<ServiceInfo> list() {
    final items = [
      for (final t in _tracked.values)
        if (t.http) t.info,
    ]..sort((a, b) => a.port - b.port);
    return items;
  }

  /// The service on this port, [ServiceLookupGone] if one was there recently, or null.
  ServiceLookup? lookup(int port) {
    final t = _tracked[port];
    if (t != null && t.http) return ServiceLookupFound(t.info);
    final at = _gone[port];
    return at != null && at != 0 && DateTime.now().millisecondsSinceEpoch - at < _goneMs ? ServiceLookupGone() : null;
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      await _scanOnce();
    } catch (err) {
      stderr.writeln('services scan failed: $err');
    } finally {
      _scanning = false;
    }
  }

  Future<void> _scanOnce() async {
    final owners = _owners();
    final (ls, procs) = await (_listeners(), _processes()).wait;
    final byPty = {
      for (final o in owners)
        if (o.pid != null && o.pid != 0) o.pid!: o,
    };
    final byId = {for (final o in owners) o.workerId: o};

    // One entry per port; prefer a loopback address to connect to.
    final ports = <int, _Listener>{};
    for (final l in ls) {
      if (l.pid == pid) continue; // the office itself
      final cur = ports[l.port];
      if (cur == null || (l.host == '127.0.0.1' && cur.host != '127.0.0.1')) ports[l.port] = l;
    }

    final found = <int, ({_Listener l, String workerId, String? cwd})>{};
    final unresolved = <_Listener>[];
    for (final l in ports.values) {
      final args = procs[l.pid]?.args ?? '';
      if (_noise.hasMatch(args)) continue;
      // Walk up to the worker terminal that started it.
      ServiceOwner? owner;
      var underOffice = false;
      for (var q = l.pid, i = 0; q > 1 && i < 64; q = procs[q]?.ppid ?? 0, i++) {
        owner = byPty[q];
        if (owner != null) {
          if (q == l.pid && owner.agent) {
            owner = null; // Claude's own port
          } else {
            break;
          }
        }
        if (q == pid) {
          underOffice = true;
          break;
        }
      }
      if (owner != null) {
        found[l.port] = (l: l, workerId: owner.workerId, cwd: null);
      } else if (!underOffice) {
        unresolved.add(l);
      }
    }
    // Detached (nohup, daemonized) servers lost their parent: go by env, then working directory.
    final dirs = await _cwds([for (final l in unresolved) l.pid]);
    for (final l in unresolved) {
      final fromEnv = await _workerFromEnv(l.pid);
      if (fromEnv != null && byId.containsKey(fromEnv)) {
        found[l.port] = (l: l, workerId: fromEnv, cwd: null);
        continue;
      }
      // Only a worktree says whose it is: the project root is everyone's (and yours, from your own terminal).
      final cwd = dirs[l.pid];
      if (cwd == null || cwd.isEmpty) continue;
      final candidates = owners.where((o) => o.cwd != o.root && _inside(o.cwd, cwd)).toList()
        ..sort((a, b) => b.cwd.length - a.cwd.length);
      if (candidates.isNotEmpty) found[l.port] = (l: l, workerId: candidates.first.workerId, cwd: cwd);
    }
    // Working directories for the board, for servers that are new since the last scan.
    final need = [
      for (final MapEntry(key: port, value: f) in found.entries)
        if (f.cwd == null && _tracked[port]?.pid != f.l.pid) f.l.pid,
    ];
    final more = await _cwds(need);

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final MapEntry(key: port, value: t) in _tracked.entries.toList()) {
      if (found.containsKey(port)) continue;
      _tracked.remove(port);
      if (t.http) _gone[port] = now;
    }
    for (final MapEntry(key: port, value: f) in found.entries) {
      final cwd = f.cwd ?? more[f.l.pid];
      final root = byId[f.workerId]?.root;
      final rel = cwd != null && cwd.isNotEmpty && root != null && root.isNotEmpty && _inside(root, cwd)
          ? _relative(root, cwd)
          : null;
      final command = shortCommand(procs[f.l.pid]?.args ?? '?');
      var t = _tracked[port];
      if (t == null) {
        t = _Tracked(
          port: port,
          workerId: f.workerId,
          host: f.l.host,
          pid: f.l.pid,
          command: command,
          cwd: rel,
          since: now,
        );
        _tracked[port] = t;
        _gone.remove(port);
      } else if (t.pid != f.l.pid) {
        // Restarted on the same port (a dev server reloading its config): same row, fresh look.
        t
          ..host = f.l.host
          ..pid = f.l.pid
          ..command = command
          ..cwd = rel
          ..since = now
          ..probedAt = 0
          ..probes = 0;
      }
      t.workerId = f.workerId;
      _maybeProbe(t, now);
    }
    _publish();
  }

  /// New servers get probed right away and again while they boot; known web servers now and then for their title.
  void _maybeProbe(_Tracked t, int now) {
    if (t.probing) return;
    final wait = t.http
        ? 60000
        : t.probes < 8
        ? 3000 * (1 << (t.probes - 2 < 0 ? 0 : t.probes - 2))
        : 5 * 60000;
    if (now - t.probedAt < wait) return;
    t.probing = true;
    t.probedAt = now;
    t.probes++;
    _probe(t.host, t.port).then((r) {
      t.probing = false;
      if (!identical(_tracked[t.port], t)) return;
      t.http = r.ok;
      if (r.ok) t.title = r.title;
      _publish();
    });
  }

  void _publish() {
    final items = list();
    final json = jsonEncode(items);
    if (json == _published) return;
    _published = json;
    _onChange(items);
  }
}

/// path.relative, but '' (not '.') for the same directory, as Node's is.
String _relative(String from, String to) {
  final rel = p.relative(to, from: from);
  return rel == '.' ? '' : rel;
}
