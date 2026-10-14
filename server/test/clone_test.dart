// Port of tests/clone.test.ts (upstream #195): a new floor's clone, watched as it comes down,
// stopped when it stalls or someone stops it, and picked back up by the next office.
@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/building.dart';
import 'package:agent_office_server/src/clone.dart';
import 'package:agent_office_server/src/github.dart' show ghCommand;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A stand-in for gh: `repo view` and `repo clone` from bare repositories in [repos]. It says how far
/// along it is the way git does, can wait first ([delay]), hang ([hang]) or fail the way ssh does
/// ([fail]). A clone runs detached, without the test's environment, so all of it is in the script.
String fakeGh(String repos, {String delay = '', bool hang = false, String fail = ''}) =>
    '''#!/bin/sh
FAKE_GH_REPOS='$repos'
FAKE_GH_DELAY='$delay'
FAKE_GH_HANG='${hang ? '1' : ''}'
FAKE_GH_FAIL='$fail'
case "\$1 \$2" in
  "repo view")
    [ -d "\$FAKE_GH_REPOS/\$3.git" ] || { echo "GraphQL: Could not resolve to a Repository with the name '\$3'." >&2; exit 1; }
    echo "{\\"nameWithOwner\\":\\"\$3\\",\\"isEmpty\\":false}"
    ;;
  "repo clone")
    name="\$3"; dest="\$4"
    printf "Cloning into '%s'...\\n" "\$dest" >&2
    [ -n "\$FAKE_GH_FAIL" ] && { echo "\$FAKE_GH_FAIL" >&2; echo "fatal: Could not read from remote repository." >&2; exit 128; }
    [ -n "\$FAKE_GH_HANG" ] && exec sleep 600
    printf "Receiving objects:  42%% (42/100), 1.00 MiB | 512.00 KiB/s\\r" >&2
    [ -n "\$FAKE_GH_DELAY" ] && sleep "\$FAKE_GH_DELAY"
    git clone -q "\$FAKE_GH_REPOS/\$name.git" "\$dest" || exit 1
    git -C "\$dest" remote set-url origin "https://github.com/\$name.git"
    ;;
esac
''';

const _fastTick = Duration(milliseconds: 50);

class Office {
  Office() : root = Directory.systemTemp.createTempSync('agent-office-clone-').resolveSymbolicLinksSync() {
    dataDir = p.join(root, '.agent-office');
    Directory(dataDir).createSync();
    bin = p.join(root, 'bin');
    Directory(bin).createSync();
    repos = p.join(root, 'github');
    // acme/game on "GitHub", with a commit.
    final work = p.join(root, 'work');
    _git(['init', '-q', work]);
    File(p.join(work, 'index.html')).writeAsStringSync('<h1>game</h1>');
    _git(['-C', work, 'add', '.']);
    _git(['-C', work, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'first']);
    _git(['clone', '-q', '--bare', work, p.join(repos, 'acme', 'game.git')]);
    projects = p.join(root, 'projects');
    gh();
  }

  final String root;
  late final String dataDir, bin, repos, projects;
  final pids = <int>[];

  /// Puts a gh that behaves so in place.
  void gh({String delay = '', bool hang = false, String fail = ''}) {
    final file = p.join(bin, 'gh');
    File(file).writeAsStringSync(fakeGh(repos, delay: delay, hang: hang, fail: fail));
    Process.runSync('chmod', ['755', file]);
    ghCommand = file;
  }

  /// The clones under way, as the office keeps them for the next one.
  List<Map> saved() {
    final f = File(p.join(dataDir, 'cloning.json'));
    return f.existsSync() ? [for (final x in jsonDecode(f.readAsStringSync()) as List) x as Map] : [];
  }

  Future<int> running() async {
    for (var i = 0; i < 200 && saved().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final pid = saved().firstOrNull?['pid'] as int?;
    expect(pid, isNotNull, reason: 'the clone is in cloning.json');
    pids.add(saved().first['group'] as int? ?? pid!);
    return pid!;
  }

  void close() {
    ghCommand = 'gh';
    for (final g in pids) {
      Process.runSync('kill', ['-KILL', '--', '-$g']);
    }
    try {
      Directory(root).deleteSync(recursive: true);
    } catch (_) {
      // a clone winding down
    }
  }
}

void _git(List<String> args) {
  final r = Process.runSync('git', args);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}

/// Still running (a zombie nobody reaped yet has gone).
bool alive(int pid) {
  final r = Process.runSync('ps', ['-o', 'stat=', '-p', '$pid']);
  final stat = '${r.stdout}'.trim();
  return r.exitCode == 0 && stat.isNotEmpty && !stat.startsWith('Z');
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Building building(Office o, {Duration stall = const Duration(milliseconds: 1500)}) =>
    Building(o.dataDir, o.projects, cloneTick: _fastTick, cloneStall: stall);

void main() {
  late Office o;
  setUp(() => o = Office());
  tearDown(() => o.close());

  test("git's progress reads as a step, how far and how fast", () {
    const out =
        "Cloning into '/x/acme/game'...\nremote: Enumerating objects: 2742, done.\nremote: Counting objects: 100% (5/5), done.\nReceiving objects:  12% (330/2742), 40.12 MiB | 1.52 MiB/s\rReceiving objects:  64% (1755/2742), 231.40 MiB | 1.50 MiB/s\r";
    Map<String, dynamic>? read(String s) => parseProgress(s)?.toJson();
    expect(read(out), {'step': 'Downloading', 'percent': 64, 'detail': '231.40 MiB · 1.50 MiB/s'});
    expect(
      read(
        '${out}Receiving objects: 100% (2742/2742), 362.00 MiB | 1.50 MiB/s, done.\nResolving deltas:  30% (3/10)\r',
      ),
      {'step': 'Unpacking', 'percent': 30},
    );
    expect(read('remote: Compressing objects:  50% (1/2)\r'), {'step': 'GitHub is packing it up', 'percent': 50});
    expect(read('Updating files:  99% (990/1000)\r'), {'step': 'Checking out files', 'percent': 99});
    expect(read("Cloning into '/x'...\n"), {'step': 'Connecting to GitHub'});
    expect(parseProgress(''), isNull);
  });

  test('a failed clone says what to do about it', () {
    expect(
      whyCloneFailed(
        "Cloning into 'x'...\nHost key verification failed.\nfatal: Could not read from remote repository.\n",
      ),
      contains('ssh -T git@github.com'),
    );
    expect(whyCloneFailed('git@github.com: Permission denied (publickey).\n'), contains('gh ssh-key add'));
    expect(
      whyCloneFailed("fatal: could not read Username for 'https://github.com': terminal prompts disabled\n"),
      contains('gh auth setup-git'),
    );
    expect(
      whyCloneFailed('Receiving objects:  1% (1/100)\rerror: RPC failed\nfatal: early EOF\n'),
      'error: RPC failed fatal: early EOF',
    );
  });

  test('a clone shows how far along it is, then becomes a floor', () async {
    o.gh(delay: '0.6');
    final b = building(o);
    final seen = <CloneProgress?>[];
    var id = '';
    b.watchClones(() => seen.add(b.cloneProgress(id)));
    final r = await b.add('acme/game', 'Sam', (def) => id = def.id);
    expect(r.error, isNull);
    expect(seen.last?.toJson(), {'step': 'Downloading', 'percent': 42, 'detail': '1.00 MiB · 512.00 KiB/s'});
    expect(File(p.join(o.projects, 'acme', 'game', 'index.html')).existsSync(), isTrue);
    expect(b.list().map((d) => d.repo), ['acme/game']);
    expect(b.pending(), isEmpty);
    expect(o.saved(), isEmpty, reason: "cloning.json is gone once it's done");
    expect(Directory(p.join(o.dataDir, 'clones')).listSync(), isEmpty, reason: 'and so is its log');
  });

  test("a clone that goes quiet is stopped as stalled, and one that can't sign in says why", () async {
    o.gh(hang: true);
    final b = building(o);
    final r = b.add('acme/game', 'Sam', (_) {});
    final pid = await o.running();
    expect((await r).error, contains('stalled'));
    await until(() => !alive(pid));
    expect(alive(pid), isFalse, reason: 'the clone was stopped');
    expect(b.pending(), isEmpty);

    o.gh(fail: 'Host key verification failed.');
    expect(
      (await b.add('acme/game', 'Sam', (_) {})).error,
      matches(RegExp(r"^Couldn't clone acme/game: ssh .*host key")),
    );
    expect(b.list(), isEmpty);
  });

  test('a clone can be stopped by an admin or whoever added it', () async {
    o.gh(hang: true);
    final b = building(o, stall: const Duration(minutes: 3));
    var id = '';
    final r = b.add('acme/game', 'Sam', (def) => id = def.id, 'sam-account');
    final pid = await o.running();
    expect(b.cancel(id, 'Ann stopped the clone', (owner) => owner == 'ann-account'), contains('Only admins'));
    expect(b.cancel(id, 'Sam stopped the clone', (owner) => owner == 'sam-account'), isNull);
    expect((await r).error, 'Sam stopped the clone');
    await until(() => !alive(pid));
    expect(alive(pid), isFalse);
    expect(b.list(), isEmpty);
    expect(b.cancel(id, 'again', (_) => true), 'No such floor');
  });

  test('a restart mid-clone picks the clone back up, and it becomes its floor', () async {
    o.gh(delay: '1');
    final first = building(o);
    // ignore: unawaited_futures
    first.add('acme/game', 'Sam', (_) {});
    await o.running();
    // The office restarts: the clone carries on without it.
    first.shutdown(true);
    final second = building(o);
    final done = <({FloorDef? floor, String? error})>[];
    second.resumeClones((floor, error) => done.add((floor: floor, error: error)));
    expect(second.pending().map((d) => d.repo), ['acme/game'], reason: "it's on its way again");
    await until(() => done.isNotEmpty);
    expect(done.first.error, isNull);
    expect(second.list().map((d) => d.repo), ['acme/game']);
    expect(o.saved(), isEmpty);
    // Saved, so the next office has it too.
    expect(Building(o.dataDir, o.projects).list().map((d) => d.repo), ['acme/game']);
  });

  test('a clone that finished while no office was watching becomes its floor at the next start', () async {
    o.gh(delay: '0.3');
    final first = building(o);
    // ignore: unawaited_futures
    first.add('acme/game', 'Sam', (_) {});
    final pid = await o.running();
    first.shutdown(true);
    await until(() => !alive(pid));
    final done = <FloorDef?>[];
    building(o).resumeClones((floor, _) => done.add(floor));
    expect(done.length, 1);
    expect(done.first?.repo, 'acme/game');
  });

  test("a clone that was cut off isn't taken for a checkout", () async {
    final dest = p.join(o.projects, 'acme', 'game');
    _git(['init', '-q', dest]);
    _git(['-C', dest, 'remote', 'add', 'origin', 'https://github.com/acme/game.git']);
    final b = building(o);
    expect((await b.add('acme/game', 'Sam', (_) {})).error, contains("didn't finish"));
    expect(b.list(), isEmpty);
  });
}
