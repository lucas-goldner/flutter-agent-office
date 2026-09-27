import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:agent_office_server/src/upgrade.dart';
import 'package:crypto/crypto.dart';
import 'package:office_shared/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('compareVersions', () {
    test('orders by number, not by text', () {
      expect(compareVersions('v0.1.68', 'v0.1.100'), lessThan(0));
      expect(compareVersions('v0.2.1', 'v0.1.100'), greaterThan(0));
      expect(compareVersions('v1.0.0', 'v0.99.999'), greaterThan(0));
    });
    test('ignores the v and fills missing parts with 0', () {
      expect(compareVersions('0.1.68', 'v0.1.68'), 0);
      expect(compareVersions('v0.2', 'v0.2.0'), 0);
    });
    test('puts a pre-release before its release', () {
      expect(compareVersions('v0.2.0-rc1', 'v0.2.0'), lessThan(0));
      expect(compareVersions('v0.2.0', 'v0.2.0-rc1'), greaterThan(0));
    });
  });

  test('validTag matches install.sh', () {
    expect(validTag('v0.1.68'), isTrue);
    expect(validTag('0.1.68'), isFalse);
    expect(validTag('v0.1.68; rm -rf /'), isFalse);
    expect(validTag('v0/../x'), isFalse); // a tag names a folder, so it's one path segment
  });

  group('assets', () {
    test('are named after the platform', () {
      expect(currentPlatform(Abi.linuxX64), (os: 'linux', arch: 'x64'));
      expect(currentPlatform(Abi.linuxArm64), (os: 'linux', arch: 'arm64'));
      expect(currentPlatform(Abi.macosX64), (os: 'darwin', arch: 'x64'));
      expect(currentPlatform(Abi.macosArm64), (os: 'darwin', arch: 'arm64'));
      expect(currentPlatform(Abi.windowsX64), isNull);
      expect(assetName('darwin', 'arm64'), 'agent-office-darwin-arm64.tar.gz');
    });
    test("pickAsset finds this platform's tarball", () {
      final assets = [
        {'name': 'agent-office-linux-x64.tar.gz', 'browser_download_url': 'https://x/linux-x64'},
        {'name': 'agent-office-darwin-arm64.tar.gz', 'browser_download_url': 'https://x/darwin-arm64'},
        {'name': 'SHA256SUMS', 'browser_download_url': 'https://x/sums'},
      ];
      expect(pickAsset(assets, assetName('darwin', 'arm64')), 'https://x/darwin-arm64');
      expect(pickAsset(assets, checksumsAsset), 'https://x/sums');
      expect(pickAsset(assets, assetName('linux', 'arm64')), isNull);
      expect(pickAsset(null, checksumsAsset), isNull);
    });
  });

  group('checksums', () {
    final a = 'a' * 64, b = 'B' * 64;
    test('parses sha256sum output, text and binary mode', () {
      final sums = parseChecksums(
        '$a  agent-office-linux-x64.tar.gz\n$b *agent-office-darwin-x64.tar.gz\n\nnot a line\n',
      );
      expect(sums, {'agent-office-linux-x64.tar.gz': a, 'agent-office-darwin-x64.tar.gz': 'b' * 64});
    });
    test('verifySha256 accepts the right file and rejects a changed one', () async {
      final dir = Directory.systemTemp.createTempSync('upgrade-sum');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File(p.join(dir.path, 'x.tar.gz'))..writeAsStringSync('hello');
      final good = sha256.convert(utf8.encode('hello')).toString();
      await verifySha256(f, good.toUpperCase());
      f.writeAsStringSync('hellO');
      expect(verifySha256(f, good), throwsA(isA<StateError>()));
    });
  });

  group('InstallLayout', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('upgrade-layout'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String release(String tag) {
      final d = Directory(p.join(tmp.path, 'staged-$tag', 'agent-office'))..createSync(recursive: true);
      File(p.join(d.path, 'agent-office')).writeAsStringSync(tag);
      return d.path;
    }

    test('versions layout: unpacks next to the others and swings current over', () {
      final root = p.join(tmp.path, 'share');
      final v1 = Directory(p.join(root, 'versions', 'v0.1.1'))..createSync(recursive: true);
      File(p.join(v1.path, 'agent-office')).writeAsStringSync('v0.1.1');
      Link(p.join(root, 'current')).createSync(p.join('versions', 'v0.1.1'));

      final layout = InstallLayout.of(v1.path);
      expect(layout.versioned, isTrue);
      expect(layout.root, root);
      expect(p.isWithin(p.join(root, 'versions'), layout.stage), isTrue);

      final dest = layout.swapIn(release('v0.1.2'), 'v0.1.2');
      expect(dest, p.join(root, 'versions', 'v0.1.2'));
      expect(Link(p.join(root, 'current')).targetSync(), p.join('versions', 'v0.1.2'));
      expect(File(p.join(root, 'current', 'agent-office')).readAsStringSync(), 'v0.1.2');
      expect(File(p.join(v1.path, 'agent-office')).existsSync(), isTrue, reason: 'the running version stays');
      expect(File(p.join(root, 'current.next')).existsSync(), isFalse);

      // Again over a leftover copy of the same version.
      Directory(layout.stage).createSync(recursive: true);
      layout.swapIn(release('v0.1.2'), 'v0.1.2');
      expect(File(p.join(root, 'current', 'agent-office')).readAsStringSync(), 'v0.1.2');
    });

    test('standalone folder: trades places with the new version', () {
      final dir = Directory(p.join(tmp.path, 'opt', 'agent-office'))..createSync(recursive: true);
      File(p.join(dir.path, 'agent-office')).writeAsStringSync('v0.1.1');
      final layout = InstallLayout.of(dir.path);
      expect(layout.versioned, isFalse);
      Directory(layout.stage).createSync(recursive: true);
      expect(layout.swapIn(release('v0.1.2'), 'v0.1.2'), dir.path);
      expect(File(p.join(dir.path, 'agent-office')).readAsStringSync(), 'v0.1.2');
      expect(File(p.join(layout.stage, 'old', 'agent-office')).readAsStringSync(), 'v0.1.1');
    });

    test('standalone folder: puts the old one back when the new one cannot move in', () {
      final dir = Directory(p.join(tmp.path, 'opt', 'agent-office'))..createSync(recursive: true);
      File(p.join(dir.path, 'agent-office')).writeAsStringSync('v0.1.1');
      final layout = InstallLayout.of(dir.path);
      Directory(layout.stage).createSync(recursive: true);
      expect(() => layout.swapIn(p.join(tmp.path, 'missing'), 'v0.1.2'), throwsA(isA<FileSystemException>()));
      expect(File(p.join(dir.path, 'agent-office')).readAsStringSync(), 'v0.1.1');
    });
  });

  group('Upgrader', () {
    test('is off without AGENT_OFFICE_SELF_UPDATE or an install.json', () async {
      final tmp = Directory.systemTemp.createTempSync('upgrade-off');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final u = Upgrader((_) {}, () {}, exeDir: tmp.path, environment: const {});
      expect(u.state.available, isFalse);
      expect(await u.start('amy'), contains("can't upgrade itself"));
      u.stop();
    });

    // A whole upgrade against a fake GitHub: check, download, verify, unpack, swap, restart.
    test('upgrades a versions install from the latest release', () async {
      final tmp = Directory.systemTemp.createTempSync('upgrade-e2e');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final platform = currentPlatform()!;
      final asset = assetName(platform.os, platform.arch);

      final root = p.join(tmp.path, 'share');
      final v1 = Directory(p.join(root, 'versions', 'v0.1.1'))..createSync(recursive: true);
      File(p.join(v1.path, 'install.json')).writeAsStringSync(
        jsonEncode({'repo': 'acme/office', 'tag': 'v0.1.1', 'subject': 'First', 'date': '2026-01-01T00:00:00Z'}),
      );
      Link(p.join(root, 'current')).createSync(p.join('versions', 'v0.1.1'));

      // The new release's tarball: a stand-in binary that answers --version.
      final build = Directory(p.join(tmp.path, 'build', 'agent-office'))..createSync(recursive: true);
      File(p.join(build.path, 'agent-office')).writeAsStringSync('#!/bin/sh\necho 0.1.3\n');
      Process.runSync('chmod', ['755', p.join(build.path, 'agent-office')]);
      Directory(p.join(build.path, 'web')).createSync();
      File(p.join(build.path, 'web', 'index.html')).writeAsStringSync('<html>');
      File(
        p.join(build.path, 'install.json'),
      ).writeAsStringSync(jsonEncode({'repo': 'someone/else', 'tag': 'v0.1.3', 'subject': 'Third'}));
      final tarball = p.join(tmp.path, asset);
      expect(Process.runSync('tar', ['-czf', tarball, '-C', p.dirname(build.path), 'agent-office']).exitCode, 0);
      final bytes = File(tarball).readAsBytesSync();
      var sums = '${sha256.convert(bytes)}  $asset\n';

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((req) {
        final res = req.response;
        switch (req.uri.path) {
          case '/repos/acme/office/releases/latest':
            res.write(
              jsonEncode({
                'tag_name': 'v0.1.3',
                'name': 'v0.1.3',
                'published_at': '2026-02-01T00:00:00Z',
                'assets': [
                  {'name': asset, 'browser_download_url': '$base/dl/$asset'},
                  {'name': 'SHA256SUMS', 'browser_download_url': '$base/dl/SHA256SUMS'},
                ],
              }),
            );
          case '/repos/acme/office/compare/v0.1.1...v0.1.3':
            res.write(
              jsonEncode({
                'total_commits': 2,
                'commits': [
                  {
                    'sha': '1111111aaaa',
                    'commit': {
                      'message': 'Second\n\nbody',
                      'committer': {'date': '2026-01-15T00:00:00Z'},
                    },
                  },
                  {
                    'sha': '2222222bbbb',
                    'commit': {
                      'message': 'Third',
                      'committer': {'date': '2026-01-31T00:00:00Z'},
                    },
                  },
                ],
              }),
            );
          case final path when path == '/dl/$asset':
            res.add(bytes);
          case '/dl/SHA256SUMS':
            res.write(sums);
          default:
            res.statusCode = 404;
        }
        res.close();
      });

      final states = <UpgradeState>[];
      final restarted = Completer<void>();
      final u = Upgrader(
        states.add,
        restarted.complete,
        exeDir: v1.path,
        environment: {'AGENT_OFFICE_SELF_UPDATE': '1'},
        apiBase: base,
        firstCheck: const Duration(hours: 1),
        restartDelay: Duration.zero,
      );
      addTearDown(u.stop);
      expect(u.state.available, isTrue);
      expect(u.version, '0.1.1');
      expect(u.state.current?.sha, 'v0.1.1');

      await u.check();
      expect(u.state.latest?.sha, 'v0.1.3');
      expect(u.state.latest?.subject, 'Third');
      expect(u.state.behind, 2);
      expect(u.state.changes?.map((c) => '${c.sha} ${c.subject}'), ['2222222 Third', '1111111 Second']);
      expect(u.state.error, isNull);

      // A tampered download is refused and changes nothing.
      sums = '${'0' * 64}  $asset\n';
      expect(await u.start('amy'), isNull);
      await _until(() => u.state.phase == UpgradePhase.failed);
      expect(u.state.error, contains('corrupt'));
      expect(Link(p.join(root, 'current')).targetSync(), p.join('versions', 'v0.1.1'));
      expect(Directory(p.join(root, 'versions', 'v0.1.3')).existsSync(), isFalse);

      sums = '${sha256.convert(bytes)}  $asset\n';
      expect(await u.start('amy'), isNull);
      expect(u.state.by, 'amy');
      await restarted.future.timeout(const Duration(seconds: 20));
      expect(u.state.phase, UpgradePhase.restarting);
      expect(states.map((s) => s.phase), contains(UpgradePhase.building));
      expect(Link(p.join(root, 'current')).targetSync(), p.join('versions', 'v0.1.3'));
      final installed = InstallInfo.read(p.join(root, 'current'))!;
      expect(installed.repo, 'acme/office', reason: 'keeps following the repo it was installed from');
      expect(installed.tag, 'v0.1.3');
      expect(File(p.join(root, 'current', '.installed')).existsSync(), isTrue);
      expect(Directory(p.join(root, 'versions', '.upgrade', 'next', 'agent-office')).existsSync(), isFalse);
      expect(await u.start('bob'), 'An upgrade is already running');
    });

    test('says so when it is up to date', () async {
      final tmp = Directory.systemTemp.createTempSync('upgrade-uptodate');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'install.json')).writeAsStringSync(jsonEncode({'repo': 'acme/office', 'tag': 'v0.1.3'}));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(
        (req) => req.response
          ..write(jsonEncode({'tag_name': 'v0.1.3', 'assets': []}))
          ..close(),
      );
      final u = Upgrader(
        (_) {},
        () {},
        exeDir: tmp.path,
        environment: {'AGENT_OFFICE_SELF_UPDATE': '1'},
        apiBase: 'http://127.0.0.1:${server.port}',
        firstCheck: const Duration(hours: 1),
      );
      addTearDown(u.stop);
      await u.check();
      expect(u.state.latest, isNull);
      expect(u.state.checkedAt, isNotNull);
      expect(await u.start('amy'), 'The office is already up to date');
    });
  });
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
}
