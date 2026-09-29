// Port of tests/machine.test.ts.
import 'dart:io';

import 'package:agent_office_server/src/machine.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

class MachineFixture {
  MachineFixture([this.ceiling]) : dir = Directory.systemTemp.createTempSync('office-machine-').path;

  final String dir;
  final int? ceiling;
  int workers = 0;
  final told = <MachineState>[];

  Machine open() => Machine(dir, ceiling, () => workers, told.add);
  void hire([int n = 1]) => workers += n;
}

MachineFixture fixture([int? ceiling]) {
  final f = MachineFixture(ceiling);
  addTearDown(() => Directory(f.dir).deleteSync(recursive: true));
  return f;
}

void main() {
  test('worker limits are whole numbers from 1 up', () {
    expect(parseWorkerLimit('6'), 6);
    expect(parseWorkerLimit(' 12 '), 12);
    for (final bad in ['0', '-1', '2.5', 'six', '', 0, 1.5, null, 10000]) {
      expect(parseWorkerLimit(bad), isNull, reason: '$bad');
    }
  });

  test('no limit until one is set; then hiring past it is refused, across restarts', () {
    final f = fixture();
    final m = f.open();
    f.hire(5);
    expect(m.limit, isNull);
    expect(m.full(), isNull);
    expect(m.room(), double.infinity);
    expect(m.setLimit(5, 'Ada'), isNull);
    expect(m.full(), contains('limit of 5 workers'));
    expect(m.room(), 0);
    expect(f.told.last.set?.limit, 5);
    // Kept on disk.
    final again = f.open();
    expect(again.limit, 5);
    expect(again.state().set?.by, 'Ada');
    expect(again.setLimit(null, 'Ada'), isNull);
    expect(again.full(), isNull);
  });

  test('--max-workers is a ceiling the office can go under but not over', () {
    final f = fixture(4);
    final m = f.open();
    expect(m.limit, 4);
    f.hire(3);
    expect(m.room(), 1);
    expect(m.setLimit(6, 'Ada'), contains('--max-workers 4'));
    expect(m.limit, 4);
    expect(m.setLimit(2, 'Ada'), isNull);
    expect(m.limit, 2);
    expect(m.room(), -1);
    expect(m.full(), isNotNull);
    // Taking the office's own limit off goes back to the ceiling.
    m.setLimit(null, 'Ada');
    expect(m.limit, 4);
    expect(m.state().ceiling, 4);
  });

  test('everyone hears when the worker count moves, and only then', () {
    final f = fixture();
    final m = f.open();
    m.workersChanged();
    final n = f.told.length;
    m.workersChanged();
    expect(f.told.length, n);
    f.hire();
    m.workersChanged();
    expect(f.told.length, n + 1);
    expect(f.told.last.workers, 1);
  });

  test('the machine is read: cores, memory and a first sample', () async {
    final f = fixture();
    final m = f.open()..start();
    addTearDown(m.stop);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final s = f.told.last;
    expect(s.cores, greaterThan(0));
    if (Platform.isLinux) {
      expect(s.memTotal, greaterThan(0));
      expect(s.memUsed, inInclusiveRange(1, s.memTotal));
    }
    expect(s.cpu, inInclusiveRange(0, 100));
  });
}
