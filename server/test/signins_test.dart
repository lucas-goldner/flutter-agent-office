import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/ptys.dart';
import 'package:agent_office_server/src/signins.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Everyone's own Claude and GitHub (signins.dart): there's no upstream test, so these cover what
// matters most — the folders each account gets, what's taken out of the environment, pasted tokens,
// and that revoking deletes only what's under homes/.

class FakePty implements Pty {
  FakePty(this.opts);
  final SpawnOpts opts;
  final typed = <String>[];
  void Function(String data)? _data;
  void Function(PtyExit e)? _exit;
  bool killed = false;

  void say(String s) => _data?.call(s);
  void end(int code) => _exit?.call(PtyExit(code));

  @override
  String? get id => null;
  @override
  int get pid => 1;
  @override
  void write(String data) => typed.add(data);
  @override
  void resize(int cols, int rows) {}
  @override
  void kill() => killed = true;
  @override
  void onData(void Function(String data) cb) => _data = cb;
  @override
  void onExit(void Function(PtyExit e) cb) => _exit = cb;
}

typedef Call = ({String cmd, List<String> args, Map<String, String> env, String? input});

class Fixture {
  Fixture() {
    dir = Directory.systemTemp.createTempSync('ao-signins-');
    home = Directory(p.join(dir.path, 'user'))..createSync();
    signins = SignIns(
      p.join(dir.path, 'data'),
      '/bin/claude',
      '/bin/gh',
      () => Map.of(base),
      (id) => admins.contains(id),
      changed.add,
      run: (cmd, args, env, [input]) async {
        calls.add((cmd: cmd, args: args, env: env, input: input));
        return answer(cmd, args, env);
      },
      spawn: (opts) => pty = FakePty(opts),
      home: home.path,
    );
  }

  late final Directory dir;
  late final Directory home;
  late final SignIns signins;
  final base = <String, String>{
    'PATH': '/usr/bin',
    'HOME': '/home/office',
    'ANTHROPIC_API_KEY': 'sk-ant-api03-office',
    'CLAUDE_CODE_OAUTH_TOKEN': 'office-oauth',
    'GH_TOKEN': 'ghp_office',
    'GITHUB_TOKEN': 'ghp_office2',
    'GIT_CONFIG_GLOBAL': '/home/office/.gitconfig',
  };
  final admins = <String>{};
  final changed = <String>[];
  final calls = <Call>[];
  FakePty? pty;
  RunResult Function(String cmd, List<String> args, Map<String, String> env) answer = (_, _, _) =>
      (code: 1, out: '', last: '');

  String get homes => p.join(dir.path, 'data', 'homes');
  void close() => dir.deleteSync(recursive: true);
}

Fixture fixture() {
  final f = Fixture();
  addTearDown(f.close);
  return f;
}

const ada = 'acct0ada';

void main() {
  test('pasted tokens: only what claude setup-token, an API key or GitHub gives out', () {
    expect(claudeToken.hasMatch('sk-ant-oat01-${'a' * 40}'), isTrue);
    expect(claudeToken.hasMatch('sk-ant-api03-${'B_-9' * 10}'), isTrue);
    expect(claudeToken.hasMatch('sk-ant-oat01-short'), isFalse);
    expect(claudeToken.hasMatch('sk-ant-oat01-${'a' * 40} --rm'), isFalse);
    expect(claudeToken.hasMatch('ghp_${'a' * 36}'), isFalse);
    expect(githubToken.hasMatch('ghp_${'a' * 36}'), isTrue);
    expect(githubToken.hasMatch('github_pat_${'A1' * 30}'), isTrue);
    expect(githubToken.hasMatch('ghp_ abc'), isFalse);
    expect(githubToken.hasMatch('short'), isFalse);
  });

  test("an account's own folder: Claude, gh and git config, private to the office", () {
    final f = fixture();
    final env = f.signins.apply(ada, Map.of(f.base));
    final home = p.join(f.homes, ada);
    expect(env['CLAUDE_CONFIG_DIR'], p.join(home, 'claude'));
    expect(env['GH_CONFIG_DIR'], p.join(home, 'gh'));
    expect(env['GIT_CONFIG_GLOBAL'], p.join(home, 'gitconfig'));
    // The machine's own credentials never reach anything run as someone else.
    for (final k in ['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN']) {
      expect(env.containsKey(k), isFalse, reason: k);
    }
    expect(env['PATH'], '/usr/bin');
    if (!Platform.isWindows) {
      expect(Directory(home).statSync().mode & 0x1ff, 0x1c0); // 0700
      expect(File(p.join(home, 'gitconfig')).statSync().mode & 0x1ff, 0x180); // 0600
    }
    final claudeJson = jsonDecode(File(p.join(home, 'claude', '.claude.json')).readAsStringSync());
    expect(claudeJson['hasCompletedOnboarding'], isTrue);
    final git = File(p.join(home, 'gitconfig')).readAsStringSync();
    expect(git, contains('[include]\n\tpath = "/home/office/.gitconfig"'));
    expect(
      git,
      contains('[credential "https://github.com"]\n\thelper =\n\thelper = "!\'/bin/gh\' auth git-credential"'),
    );
    // Only one kind: the other is left as the office has it.
    final onlyClaude = f.signins.apply(ada, Map.of(f.base), const [], SignInKind.claude);
    expect(onlyClaude['GH_TOKEN'], 'ghp_office');
    expect(onlyClaude.containsKey('ANTHROPIC_API_KEY'), isFalse);
  });

  test('a pasted Claude token goes in the environment, never argv, and counts as signed in', () async {
    final f = fixture();
    expect(f.signins.claudeReady(ada), isFalse);
    expect(await f.signins.token(ada, SignInKind.claude, 'nope'), contains("isn't a token"));
    final token = 'sk-ant-oat01-${'x' * 40}';
    expect(await f.signins.token(ada, SignInKind.claude, ' $token\n'), isNull);
    expect(f.signins.claudeReady(ada), isTrue);
    final env = f.signins.apply(ada, Map.of(f.base));
    expect(env['CLAUDE_CODE_OAUTH_TOKEN'], token);
    expect(env.containsKey('ANTHROPIC_API_KEY'), isFalse);
    expect(f.calls.every((c) => !c.args.any((a) => a.contains(token))), isTrue);
    final saved = File(p.join(f.homes, ada, 'signins.json'));
    if (!Platform.isWindows) expect(saved.statSync().mode & 0x1ff, 0x180);
    expect(f.signins.state(ada).claude.how, SignInHow.token);
    expect(f.signins.state(ada).claude.who, 'a token from claude setup-token');

    // An API key goes in as one, and Claude is told it's approved.
    final key = 'sk-ant-api03-${'k' * 40}';
    expect(await f.signins.token(ada, SignInKind.claude, key), isNull);
    expect(f.signins.apply(ada, Map.of(f.base))['ANTHROPIC_API_KEY'], key);
    final claudeJson = jsonDecode(File(p.join(f.homes, ada, 'claude', '.claude.json')).readAsStringSync());
    expect(claudeJson['customApiKeyResponses']['approved'], [key.substring(key.length - 20)]);
  });

  test('a pasted GitHub token goes to gh on stdin, and the look finds who it is', () async {
    final f = fixture();
    f.answer = (cmd, args, env) => args.first == 'api'
        ? (code: 0, out: '{"login":"ada","id":42,"name":"Ada L"}', last: '')
        : (code: 0, out: '', last: '');
    expect(await f.signins.token(ada, SignInKind.github, 'not a token!'), contains("doesn't look like"));
    final token = 'ghp_${'t' * 36}';
    expect(await f.signins.token(ada, SignInKind.github, token), isNull);
    final login = f.calls.firstWhere((c) => c.args.take(2).join(' ') == 'auth login');
    expect(login.input, '$token\n');
    expect(login.args, isNot(contains(token)));
    expect(login.env['GH_CONFIG_DIR'], p.join(f.homes, ada, 'gh'));
    expect(login.env.containsKey('GH_TOKEN'), isFalse);
    expect(f.signins.state(ada).github.who, '@ada');
    expect(f.signins.githubReady(ada), isTrue);
    expect(f.signins.githubLogin(ada), 'ada');
    // Their name and private email on commits.
    final git = File(p.join(f.homes, ada, 'gitconfig')).readAsStringSync();
    expect(git, contains('[user]\n\tname = "Ada L"\n\temail = "42+ada@users.noreply.github.com"'));
    final as = f.signins.ghAs(ada);
    expect(as.refused, isNull);
    expect(as.as?.env['GH_CONFIG_DIR'], p.join(f.homes, ada, 'gh'));
  });

  test("gh runs as the office only for admins who chose it; without a sign-in it's refused", () {
    final f = fixture();
    expect(f.signins.ghAs(ada).refused, contains('Sign in to GitHub first'));
    expect(f.signins.useOffice(ada, SignInKind.github), contains('Only admins'));
    f.admins.add(ada);
    expect(f.signins.useOffice(ada, SignInKind.github), isNull);
    final as = f.signins.ghAs(ada);
    expect((as.as, as.refused), (null, null));
    expect(f.signins.githubReady(ada), isTrue);
    // Demoted: back on their own.
    f.admins.clear();
    expect(f.signins.ghAs(ada).refused, isNotNull);
  });

  test("signing in with Claude: the page to open, then the code typed back where it's asked for", () {
    final f = fixture();
    expect(f.signins.start(ada, SignInKind.claude), isNull);
    final pty = f.pty!;
    expect(pty.opts.args, ['auth', 'login', '--claudeai']);
    expect(pty.opts.env['BROWSER'], 'true');
    expect(pty.opts.env['CLAUDE_CONFIG_DIR'], p.join(f.homes, ada, 'claude'));
    expect(pty.opts.env.containsKey('ANTHROPIC_API_KEY'), isFalse);
    expect(f.signins.state(ada).claude.status, SignInStatus.busy);
    pty.say('\x1b[1mBrowser didn\'t open? Use the url below:\x1b[0m\r\n');
    pty.say('https://claude.ai/oauth/authorize?code=true&client_id=abc\r\nPaste code here if prompted > ');
    expect(f.signins.state(ada).claude.pending?.url, 'https://claude.ai/oauth/authorize?code=true&client_id=abc');
    expect(f.signins.code(ada, 'bad code!'), contains("doesn't look like"));
    expect(f.signins.code(ada, 'abcdEFGH1234#state'), isNull);
    expect(pty.typed, ['abcdEFGH1234#state\r']);
    expect(f.signins.state(ada).claude.pending?.sent, isTrue);
    pty.say('\r\nOAuth error: Invalid code\r\n');
    expect(f.signins.state(ada).claude.error, 'OAuth error: Invalid code');
    f.signins.cancel(ada, SignInKind.claude);
    expect(pty.killed, isTrue);
    expect(f.signins.code(ada, 'abcdEFGH1234'), 'Start signing in to Claude first');
  });

  test('revoking deletes the account folder, and only folders of accounts that are gone', () async {
    final f = fixture();
    f.signins.apply(ada, Map.of(f.base));
    f.signins.apply('acct0bob', Map.of(f.base));
    final outside = Directory(p.join(f.dir.path, 'data', 'keep'))..createSync();
    await f.signins.forget('../keep');
    await f.signins.forget('..');
    expect(outside.existsSync(), isTrue);
    await f.signins.forget(ada);
    expect(Directory(p.join(f.homes, ada)).existsSync(), isFalse);
    expect(f.calls.last.args, ['auth', 'logout']);
    f.signins.prune({'someone'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(Directory(p.join(f.homes, 'acct0bob')).existsSync(), isFalse);
    expect(outside.existsSync(), isTrue);
  });

  test('git config values are quoted and stripped of control characters', () {
    expect(gitQuote('Ada "the" \\ L\n[evil]'), r'"Ada \"the\" \\ L[evil]"');
  });
}
