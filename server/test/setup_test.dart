import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String root;
  setUp(() => root = Directory.systemTemp.createTempSync('agent-office-setup-').resolveSymbolicLinksSync());
  tearDown(() => Directory(root).deleteSync(recursive: true));

  test('the suggested workspace is a code folder already in the home folder', () {
    expect(suggestedFolder('/fallback', root), '/fallback');
    File(p.join(root, 'code')).writeAsStringSync('not a folder');
    expect(suggestedFolder('/fallback', root), '/fallback');
    Directory(p.join(root, 'projects')).createSync();
    expect(suggestedFolder('/fallback', root), p.join(root, 'projects'));
    Directory(p.join(root, 'Workspace')).createSync();
    expect(suggestedFolder('/fallback', root), p.join(root, 'Workspace'));
  });

  test('setup --projects picks the workspace folder without asking', () async {
    final home = p.join(root, 'office');
    final ws = p.join(root, 'ws');
    expect(await setupCommand(['--home', home, '--projects', ws]), 0);
    final saved = jsonDecode(File(p.join(home, '.agent-office', 'projects-folder.json')).readAsStringSync());
    expect(saved['dir'], ws);
    expect(saved['by'], 'agent-office setup');
    expect(await setupCommand(['--home', home, '--projects', 'relative']), 1);
    expect(await setupCommand(['--home', home, '--bogus']), 2);
    // Nothing to do, and no terminal to ask in.
    expect(await setupCommand(['--home', home]), 2);
  });
}
