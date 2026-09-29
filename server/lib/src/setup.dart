// Setting up an office from its terminal: where projects are cloned, signing the GitHub CLI in, and
// picking the first repositories to clone as floors. Port of src/server/setup.ts. A new office walks
// you through it the first time it starts in a terminal, so it opens on projects of your own instead
// of an empty building (or whatever folder it happened to be started in). `agent-office setup` runs it
// again, or does it without asking when given --projects / --project (deploy/provision.sh does).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'building.dart';
import 'config.dart' show Config, homeDir, officeHome;

/// How many repositories a list shows; typing a word narrows it down.
const _shown = 12;

/// Folders people keep their code in, in the home folder: the first one that's there is the suggestion.
const _codeFolders = [
  'Workspace',
  'workspace',
  'Developer',
  'code',
  'Code',
  'projects',
  'Projects',
  'repos',
  'src',
  'dev',
  'git',
  'GitHub',
  'github',
];

const setupHelp = '''agent-office setup — pick where projects are cloned and which ones are floors

Usage:
  agent-office setup [--projects <dir>] [--project <owner/repo>]... [--home <dir>]

In a terminal it walks you through it: the workspace folder new projects are cloned
into, signing the GitHub CLI in, and picking repositories to clone as floors. Given
--projects or --project it does just that and asks nothing, for scripts.

A new office runs this by itself the first time it starts in a terminal. Run it
while the office is stopped; while it runs, use its elevator and ⚙️ Settings.

Options:
      --home <dir>        The office to set up (default ~/agent-office, env AGENT_OFFICE_HOME)
      --projects <dir>    Clone new projects into <dir>/<owner>/<repo> from now on
      --project <repo>    Clone this repository (owner/name or a GitHub URL) as a floor.
                          Repeat it for more than one
  -h, --help              Show this help
''';

/// Someone's at a terminal to answer questions.
bool interactive() {
  final ci = Platform.environment['CI'];
  return stdin.hasTerminal && stdout.hasTerminal && (ci == null || ci.isEmpty);
}

/// The office starting in a terminal with no floors yet: walk through the workspace folder, GitHub
/// sign-in and the first projects before it opens. Enter skips any of it; the elevator does the same.
Future<void> welcome(Config cfg) async {
  final building = Building(cfg.dataDir, cfg.projectsDir);
  if (building.list().isNotEmpty) return;
  // --projects is the answer to the first question (the office applies it again as it starts).
  final folderGiven = cfg.projects != null && building.setProjectsDir(cfg.projects!, 'the command line') == null;
  stdout.writeln('''

  👋 Welcome to Agent Office!

  Every project is a floor of the building, and this one doesn't have any yet.
  Let's add your first: pick one of your GitHub repositories and the office
  clones it. Press Enter to skip any question and do it from the office's
  elevator instead.''');
  await _walkthrough(building, cfg.dataDir, !folderGiven && !building.projectsDirState().custom);
  stdout.writeln(
    building.list().isNotEmpty
        ? '\n  All set. Opening the office…'
        : '\n  Opening the office: its elevator asks for your first project.',
  );
}

/// `agent-office setup …`: returns the exit code.
Future<int> setupCommand(List<String> argv) async {
  var home = '';
  var projects = '';
  final repos = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    String? value() {
      final v = i + 1 < argv.length ? argv[++i] : null;
      if (v == null || v.startsWith('-')) {
        stderr.writeln('agent-office setup: $a needs a value');
        return null;
      }
      return v;
    }

    switch (a) {
      case '-h' || '--help':
        stdout.write(setupHelp);
        return 0;
      case '--home':
        final v = value();
        if (v == null) return 2;
        home = p.normalize(p.absolute(v));
      case '--projects':
        final v = value();
        if (v == null) return 2;
        projects = v;
      case '--project':
        final v = value();
        if (v == null) return 2;
        repos.add(v);
      default:
        stderr.writeln('agent-office setup: unknown option $a\n');
        stderr.write(setupHelp);
        return 2;
    }
  }

  // The same office `agent-office` would start from here (see loadConfig).
  final cwd = Directory.current.path;
  var dir = home.isNotEmpty ? home : officeHome();
  var inProject = false;
  final envHome = Platform.environment['AGENT_OFFICE_HOME'];
  if (home.isEmpty &&
      (envHome == null || envHome.isEmpty) &&
      cwd != dir &&
      File(p.join(cwd, '.agent-office', 'config.json')).existsSync()) {
    dir = cwd;
    inProject = true;
  }
  final dataDir = p.join(dir, '.agent-office');
  if (!Directory(dataDir).existsSync()) {
    Directory(dataDir).createSync(recursive: true);
    if (!Platform.isWindows) Process.runSync('chmod', ['700', dataDir]);
  }
  if (await _officeRunning(dataDir)) {
    stderr.writeln(
      'agent-office setup: the office in ${tildify(dir)} is running. Add projects from its elevator, and pick '
      'the workspace folder in ⚙️ Settings.',
    );
    return 1;
  }
  final building = Building(dataDir, inProject ? p.join(homeDir(), 'agent-office') : dir);

  if (projects.isNotEmpty || repos.isNotEmpty || !interactive()) {
    if (projects.isEmpty && repos.isEmpty) {
      stderr.writeln(
        'agent-office setup: nothing to do without a terminal to ask in. Pass --projects <dir> and/or '
        '--project <owner/repo>.',
      );
      return 2;
    }
    var code = 0;
    if (projects.isNotEmpty) {
      final err = building.setProjectsDir(projects, 'agent-office setup');
      if (err != null) {
        stderr.writeln('agent-office setup: --projects: $err');
        return 1;
      }
      stdout.writeln('  📁 New projects are cloned into ${building.projectsDirState().dir}/<owner>/<repo>');
    }
    for (final repo in repos) {
      if (!await _addFloor(building, repo, 'agent-office setup')) code = 1;
    }
    return code;
  }

  final floors = building.list();
  stdout.writeln(
    floors.isNotEmpty
        ? '\n  🏢 The office in ${tildify(dir)} has ${floors.length} floor${floors.length == 1 ? '' : 's'}: '
              '${floors.map((f) => f.name).join(', ')}.'
        : '\n  🏢 The office in ${tildify(dir)} has no floors yet: every project is a floor of the building.',
  );
  await _walkthrough(building, dataDir, true);
  return 0;
}

/// The questions: the workspace folder (when [askFolder]), GitHub, then repositories to add.
Future<void> _walkthrough(Building building, String dataDir, bool askFolder) async {
  if (askFolder) _pickFolder(building);
  final login = await _githubLogin(dataDir);
  if (login == null) {
    stdout.writeln(
      '\n  Add projects from the elevator in the office once gh is ready (or run `agent-office setup` again).',
    );
    return;
  }
  await _pickProjects(building, login);
}

void _pickFolder(Building building) {
  final now = building.projectsDirState();
  final suggestion = now.custom ? now.dir : tildify(suggestedFolder(building.projectsDir));
  stdout.writeln('\n  📁 Where should the office clone your projects? Each one goes in <folder>/<owner>/<repo>.');
  for (;;) {
    final typed = _ask('     Folder [$suggestion]: ');
    final err = building.setProjectsDir(typed.isEmpty ? suggestion : typed, _whoAmI());
    if (err == null) break;
    stdout.writeln('     ✗ $err');
  }
  stdout.writeln('     ✓ ${building.projectsDirState().dir}/<owner>/<repo> (admins can change it in ⚙️ Settings)');
}

/// Where to suggest cloning projects: a code folder that's already in the home folder, else [fallback].
String suggestedFolder(String fallback, [String? home]) {
  final h = home ?? homeDir();
  Set<String> names;
  try {
    // By their exact names: on a case-insensitive disk, 'code' would otherwise find 'Code'.
    names = {for (final e in Directory(h).listSync()) p.basename(e.path)};
  } catch (_) {
    return fallback;
  }
  for (final name in _codeFolders) {
    final dir = p.join(h, name);
    if (names.contains(name) && FileSystemEntity.isDirectorySync(dir)) return dir;
  }
  return fallback;
}

/// Who `gh` is signed in to GitHub as, after offering to sign it in. Null when there's no GitHub to use.
Future<String?> _githubLogin(String cwd) async {
  for (var tried = false; ; tried = true) {
    final me = await _ghUser(cwd);
    if (me.login != null) {
      stdout.writeln('\n  🐙 Signed in to GitHub as ${me.login}');
      return me.login;
    }
    if (me.missing) {
      final how = Platform.isMacOS
          ? 'brew install gh'
          : Platform.isWindows
          ? 'winget install GitHub.cli'
          : 'sudo apt install gh';
      stdout.writeln(
        "\n  🐙 The office clones projects with the GitHub CLI (gh), which isn't installed.\n"
        '     Install it ($how, or see https://cli.github.com), then run `gh auth login`.',
      );
      return null;
    }
    if (!me.signedOut || tried) {
      stdout.writeln("\n  🐙 Couldn't reach GitHub with gh: ${me.error}");
      return null;
    }
    stdout.writeln("\n  🐙 The office clones projects with the GitHub CLI (gh), and it isn't signed in.");
    if (RegExp('^n', caseSensitive: false).hasMatch(_ask('     Sign in to GitHub now? [Y/n] '))) return null;
    try {
      final proc = await Process.start('gh', ['auth', 'login'], mode: ProcessStartMode.inheritStdio);
      await proc.exitCode;
    } catch (_) {
      // it says why itself, or the next look does
    }
  }
}

final _signedOutRe = RegExp(r'auth login|not logged in|authentication|bad credentials|HTTP 401', caseSensitive: false);

Future<({String? login, bool missing, bool signedOut, String? error})> _ghUser(String cwd) async {
  try {
    final r = await Process.run('gh', [
      'api',
      'user',
      '--jq',
      '.login',
    ], workingDirectory: cwd).timeout(const Duration(seconds: 30));
    final out = '${r.stdout}'.trim();
    if (r.exitCode == 0 && out.isNotEmpty) return (login: out, missing: false, signedOut: false, error: null);
    final why = '${r.stderr}'.trim();
    final lines = why.split('\n').where((l) => l.isNotEmpty).toList();
    return (
      login: null,
      missing: false,
      signedOut: _signedOutRe.hasMatch(why),
      error: lines.isEmpty ? 'gh failed' : lines.last,
    );
  } on ProcessException catch (e) {
    if (e.errorCode == 2) return (login: null, missing: true, signedOut: false, error: null);
    return (login: null, missing: false, signedOut: false, error: e.message);
  } on TimeoutException {
    return (login: null, missing: false, signedOut: false, error: 'gh took too long');
  }
}

Future<void> _pickProjects(Building building, String login) async {
  stdout.write('     Asking GitHub for your repositories…');
  var repos = <RepoChoice>[];
  try {
    repos = await building.repos();
    _clearLine();
  } catch (err) {
    _clearLine();
    stdout.writeln("     ✗ Couldn't list your repositories: $err");
  }
  var shown = repos.take(_shown).toList();
  if (shown.isNotEmpty) {
    stdout.writeln(
      '\n  🛗 Your repositories, most recently pushed first'
      '${repos.length > _shown ? ' ($_shown of ${repos.length}; type a word to search)' : ''}:\n',
    );
    _printRepos(shown, building);
  } else if (repos.isEmpty) {
    stdout.writeln('\n  🛗 No repositories to list. Type owner/name to clone any repository you can see.');
  }
  var added = 0;
  for (;;) {
    final answer = _ask(
      added > 0
          ? '\n  Add another? A number, owner/name or a word to search. Enter opens the office: '
          : '\n  Pick a number, type owner/name or a word to search. Enter skips: ',
    );
    if (answer.isEmpty) return;
    String? pick;
    if (RegExp(r'^\d+$').hasMatch(answer)) {
      final n = int.parse(answer);
      pick = n >= 1 && n <= shown.length ? shown[n - 1].name : null;
      if (pick == null) {
        stdout.writeln("     ✗ There's no $answer in the list");
        continue;
      }
    } else {
      pick = normalizeRepo(answer);
    }
    if (pick == null) {
      final q = answer.toLowerCase();
      final matches = repos
          .where((r) => r.name.toLowerCase().contains(q) || (r.description ?? '').toLowerCase().contains(q))
          .toList();
      if (matches.isEmpty) {
        stdout.writeln('     Nothing matches “$answer”. Type owner/name to clone any repository.');
        continue;
      }
      shown = matches.take(_shown).toList();
      stdout.writeln(
        '\n     ${matches.length} repositor${matches.length == 1 ? 'y matches' : 'ies match'} “$answer”'
        '${matches.length > _shown ? ' (the first $_shown here)' : ''}:\n',
      );
      _printRepos(shown, building);
      continue;
    }
    if (await _addFloor(building, pick, login)) added++;
  }
}

/// Clones [repo] as a new floor, saying how it went.
Future<bool> _addFloor(Building building, String repo, String by) async {
  final r = await building.add(repo, by, (def) {
    stdout.writeln('     ⏳ Cloning ${def.repo ?? repo} into ${tildify(def.dir)}… (a big repository can take a minute)');
  });
  final def = r.floor;
  if (def == null) {
    stdout.writeln('     ✗ ${r.error}');
    return false;
  }
  stdout.writeln('     ✓ ${def.repo ?? def.name} is floor ${building.list().indexOf(def) + 1}');
  return true;
}

void _printRepos(List<RepoChoice> list, Building building) {
  final columns = stdout.hasTerminal ? stdout.terminalColumns : 100;
  final width = columns - 1 < 40 ? 40 : columns - 1;
  final longest = list.map((r) => r.name.length).fold(0, (a, b) => a > b ? a : b);
  final nameWidth = longest > 40 ? 40 : longest;
  final floors = building.list();
  for (var i = 0; i < list.length; i++) {
    final r = list[i];
    final note = floors.any((f) => sameRepo(f.repo, r.name))
        ? '(a floor already)'
        : [if (r.private) 'private', if ((r.description ?? '').isNotEmpty) r.description!].join(' · ');
    final line = '    ${'${i + 1}'.padLeft(2)}. ${r.name.padRight(nameWidth)}  $note'.trimRight();
    stdout.writeln(line.length > width ? '${line.substring(0, width - 1)}…' : line);
  }
}

/// One question, answered with a line: '' when skipped with Enter or Ctrl+D. Ctrl+C quits.
String _ask(String question) {
  stdout.write(question);
  final line = stdin.readLineSync(encoding: utf8);
  if (line == null) stdout.writeln();
  return (line ?? '').trim();
}

void _clearLine() => stdout.write('\r\x1b[2K');

String _whoAmI() {
  final user = Platform.environment['USER'] ?? Platform.environment['USERNAME'];
  return user != null && user.isNotEmpty ? user : 'agent-office setup';
}

/// An office is running from this data folder: its hook server is listening where it said it would.
Future<bool> _officeRunning(String dataDir) async {
  var port = 0;
  try {
    port = int.tryParse(File(p.join(dataDir, 'hook-port')).readAsStringSync().trim()) ?? 0;
  } catch (_) {
    // never started
  }
  if (port == 0) return false;
  try {
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 800));
    sock.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
