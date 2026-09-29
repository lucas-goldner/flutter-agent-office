// The machine the office runs on: how busy its CPU and memory are, and the most workers the office
// runs at once. Port of src/server/machine.ts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

/// How often the CPU and memory are read.
const _sampleEvery = Duration(seconds: 5);

/// How many readings the wall monitor graphs: the last five minutes.
const _history = 60;

/// Memory this full, or the CPU this busy over the last [_cpuWindow] readings (30 s), is a machine under pressure.
const _memPressure = 90;
const _cpuPressure = 90;
const _cpuWindow = 6;

/// The highest worker limit there is: past this it isn't a limit.
const int maxWorkerLimit = 500;

/// What hiring asks of the office's machine: whether it can take one more worker.
abstract interface class Capacity {
  /// Why the office can't take another worker (it's at its worker limit), if it can't.
  String? full();

  /// How many more workers it has room for: infinity with no limit, below 0 once it's over.
  num room();
}

/// A worker limit as given: a whole number from 1 to [maxWorkerLimit], or null when it isn't one.
int? parseWorkerLimit(Object? v) {
  final Object? n = v is String ? (v.trim().isEmpty ? null : num.tryParse(v.trim())) : v;
  if (n is! num || !n.isFinite || n != n.truncateToDouble()) return null;
  final i = n.toInt();
  return i >= 1 && i <= maxWorkerLimit ? i : null;
}

/// Every core's busy and idle time so far; two of these a few seconds apart give how busy it was.
typedef CpuTimes = ({int idle, int total});

/// Reads the machine: stands in for the real one in tests.
class MachineProbe {
  const MachineProbe();

  int cores() => Platform.numberOfProcessors;

  /// Linux's /proc/stat; elsewhere null, and the CPU is read with [cpuPercent].
  CpuTimes? cpuTimes() {
    if (!Platform.isLinux) return null;
    try {
      final line = File('/proc/stat').readAsLinesSync().firstWhere((l) => l.startsWith('cpu '));
      final f = line.split(RegExp(r'\s+')).skip(1).where((x) => x.isNotEmpty).map(int.parse).toList();
      // user nice system idle iowait irq softirq steal
      final idle = f[3] + (f.length > 4 ? f[4] : 0);
      final total = f.take(f.length > 8 ? 8 : f.length).fold<int>(0, (a, b) => a + b);
      return (idle: idle, total: total);
    } catch (_) {
      return null;
    }
  }

  /// How busy every core is right now, where there's no /proc/stat (macOS): `ps`'s CPU column, summed.
  Future<int?> cpuPercent() async {
    try {
      final r = await Process.run('ps', ['-A', '-o', '%cpu=']).timeout(const Duration(seconds: 2));
      if (r.exitCode != 0) return null;
      var sum = 0.0;
      for (final l in '${r.stdout}'.split('\n')) {
        sum += double.tryParse(l.trim().replaceAll(',', '.')) ?? 0;
      }
      return (sum / cores()).round().clamp(0, 100);
    } catch (_) {
      return null;
    }
  }

  /// Memory in all, bytes.
  int totalMem() {
    if (Platform.isLinux) return _meminfo('MemTotal') ?? 0;
    if (Platform.isMacOS) return _sysctl('hw.memsize') ?? 0;
    return 0;
  }

  /// Memory the machine can still hand out, bytes. On macOS the kernel's own "memory free" level
  /// (what `memory_pressure` prints) is the honest figure.
  int availableMem() {
    if (Platform.isLinux) return _meminfo('MemAvailable') ?? _meminfo('MemFree') ?? 0;
    if (Platform.isMacOS) {
      final level = _sysctl('kern.memorystatus_level');
      if (level != null && level >= 0 && level <= 100) return totalMem() * level ~/ 100;
    }
    return 0;
  }

  static int? _meminfo(String key) {
    try {
      final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('$key:'));
      final kb = int.parse(RegExp(r'(\d+)').firstMatch(line)!.group(1)!);
      return kb * 1024;
    } catch (_) {
      return null;
    }
  }

  static int? _sysctl(String name) {
    try {
      final r = Process.runSync('sysctl', ['-n', name]);
      return r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
    } catch (_) {
      return null;
    }
  }
}

/// The machine the office runs on: how busy its CPU and memory are (for the monitor on the wall, and
/// a warning before hiring while it's under pressure), and the most workers the office runs at once,
/// across every floor. That limit comes from --max-workers, or from ⚙️ Settings (kept in
/// .agent-office/machine.json), which can lower it but never raise it past --max-workers.
class Machine implements Capacity {
  Machine(
    String dataDir,

    /// --max-workers.
    this._ceiling,

    /// How many workers the office has now, on every floor.
    this._count,
    this._onState, {
    MachineProbe probe = const MachineProbe(),
  }) : _path = p.join(dataDir, 'machine.json'),
       _probe = probe {
    _restore();
    _memUsed = _probe.totalMem() - _probe.availableMem();
    if (_memUsed < 0) _memUsed = 0;
  }

  final int? _ceiling;
  final int Function() _count;
  final void Function(MachineState state) _onState;
  final String _path;
  final MachineProbe _probe;
  MachineLimitSet? _saved;
  Timer? _timer;
  CpuTimes? _last;
  int _cpu = 0;
  int _memUsed = 0;
  final List<(int, int)> _readings = [];

  /// The worker count everyone was last told.
  int _told = -1;

  void start() {
    // The memory now; the CPU takes two readings a while apart.
    _last = _probe.cpuTimes();
    unawaited(_sample(false));
    _timer = Timer.periodic(_sampleEvery, (_) => unawaited(_sample()));
  }

  void stop() => _timer?.cancel();

  /// The most workers the office takes, or null for no limit.
  int? get limit {
    final set = _saved?.limit;
    if (set == null) return _ceiling;
    return _ceiling == null ? set : (set < _ceiling ? set : _ceiling);
  }

  @override
  num room() {
    final l = limit;
    return l == null ? double.infinity : l - _count();
  }

  @override
  String? full() {
    final l = limit;
    if (l == null || _count() < l) return null;
    return 'The office is at its limit of $l worker${l == 1 ? '' : 's'} on this machine — send one home before hiring another';
  }

  MachineState state() {
    final memTotal = _probe.totalMem();
    return MachineState(
      cpu: _cpu.toDouble(),
      cores: _probe.cores(),
      memUsed: _memUsed,
      memTotal: memTotal,
      history: [for (final (c, m) in _readings) (c.toDouble(), m.toDouble())],
      pressure: _pressure(memTotal),
      workers: _count(),
      limit: limit,
      ceiling: _ceiling,
      set: _saved,
    );
  }

  /// Sets the limit from ⚙️ Settings (null takes it off). Returns why it can't, if it can't.
  String? setLimit(int? limit, String by) {
    final ceiling = _ceiling;
    if (limit != null && ceiling != null && limit > ceiling) {
      return "The office was started with --max-workers $ceiling, so the limit can't go above $ceiling";
    }
    _saved = limit == null ? null : MachineLimitSet(limit: limit, by: by, at: DateTime.now().millisecondsSinceEpoch);
    _persist();
    _emit();
    return null;
  }

  /// A worker came, went or changed: when that moved the count, everyone hears the new one.
  void workersChanged() {
    if (_count() != _told) _emit();
  }

  String? _pressure(int memTotal) {
    final why = <String>[];
    final mem = memTotal > 0 ? (_memUsed / memTotal * 100).round() : 0;
    if (mem >= _memPressure) why.add('memory is $mem% used');
    // Busy for a while, not a single build step.
    if (_readings.length >= _cpuWindow) {
      final recent = _readings.sublist(_readings.length - _cpuWindow);
      final cpu = (recent.fold<int>(0, (n, r) => n + r.$1) / recent.length).round();
      if (cpu >= _cpuPressure) {
        why.add('the CPU has been $cpu% busy for the last ${_cpuWindow * _sampleEvery.inSeconds} seconds');
      }
    }
    return why.isEmpty ? null : why.join(' and ');
  }

  Future<void> _sample([bool cpu = true]) async {
    if (cpu) {
      final now = _probe.cpuTimes();
      final last = _last;
      if (now != null && last != null) {
        final total = now.total - last.total;
        if (total > 0) _cpu = ((1 - (now.idle - last.idle) / total) * 100).round().clamp(0, 100);
      } else if (now == null) {
        _cpu = await _probe.cpuPercent() ?? _cpu;
      }
      _last = now;
    }
    final memTotal = _probe.totalMem();
    _memUsed = memTotal - _probe.availableMem();
    if (_memUsed < 0) _memUsed = 0;
    if (cpu) {
      _readings.add((_cpu, memTotal > 0 ? (_memUsed / memTotal * 100).round() : 0));
      if (_readings.length > _history) _readings.removeAt(0);
    }
    _emit();
  }

  void _emit() {
    final s = state();
    _told = s.workers;
    _onState(s);
  }

  void _restore() {
    try {
      final s = jsonDecode(File(_path).readAsStringSync());
      if (s is! Map) return;
      final limit = parseWorkerLimit(s['limit']);
      if (limit != null) {
        _saved = MachineLimitSet(
          limit: limit,
          by: s['by'] is String ? s['by'] as String : 'someone',
          at: s['at'] is num ? (s['at'] as num).toInt() : 0,
        );
      }
    } catch (_) {
      // never set
    }
  }

  void _persist() {
    try {
      final tmp = '$_path.tmp';
      File(tmp).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_saved?.toJson() ?? const {}));
      chmodSync(tmp, 0x180); // 0600
      File(tmp).renameSync(_path);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}
