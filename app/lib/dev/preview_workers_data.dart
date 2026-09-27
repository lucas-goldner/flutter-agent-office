// Realistic fake office data for the worker windows preview.

import '../shared/protocol.dart';
import '../state/store.dart';

int _ago(int minutes) => DateTime.now().millisecondsSinceEpoch - minutes * 60000;

const _project = {
  'name': 'acme-app',
  'dir': '/home/ada/acme-app',
  'branch': 'main',
  'remote': 'git@github.com:acme/app.git',
  'agentCmd': 'claude',
  'defaultProvider': 'claude',
  'agentProviders': ['claude', 'opencode', 'codex'],
};

void fillStore(Store store) {
  store.you = 'p1';
  store.floor = 'f1';
  store.project = ProjectInfo.fromJson(_project);
  final workers = [
    {
      'id': 'w-claude',
      'kind': 'agent',
      'provider': 'claude',
      'deskId': 'desk-3',
      'name': 'Nova',
      'color': '#ff8a5b',
      'status': 'working',
      'acked': true,
      'createdBy': 'Ada',
      'createdAt': _ago(40),
      'title': 'Fix the Safari login button',
      'worktree': {'path': '.agent-office/worktrees/nova', 'branch': 'nova/fix-login', 'base': 'main'},
      'cols': 100,
      'rows': 30,
      'viewers': ['Ada', 'Grace'],
      'usage': {'input': 18200, 'output': 9100, 'cacheWrite': 42000, 'cacheRead': 310000, 'cost': 0.84, 'calls': 23},
      'lastInput': {'by': 'Grace', 'at': _ago(3)},
    },
    {
      'id': 'w-open',
      'kind': 'agent',
      'provider': 'opencode',
      'model': 'anthropic/claude-sonnet-4',
      'deskId': 'desk-4',
      'name': 'Pixel',
      'color': '#06d6a0',
      'status': 'needs_input',
      'acked': false,
      'createdBy': 'Grace',
      'createdAt': _ago(12),
      'cols': 120,
      'rows': 36,
      'viewers': ['Grace'],
    },
    {
      'id': 'w-shell',
      'kind': 'shell',
      'deskId': 'desk-5',
      'name': 'Shell',
      'color': '#4f86f7',
      'status': 'idle',
      'acked': true,
      'createdBy': 'Ada',
      'createdAt': _ago(90),
      'cols': 80,
      'rows': 24,
      'viewers': [],
    },
    {
      'id': 'w-codex',
      'kind': 'agent',
      'provider': 'codex',
      'deskId': 'desk-6',
      'name': 'Quill',
      'color': '#9d4edd',
      'status': 'done',
      'acked': true,
      'createdBy': 'Linus',
      'createdAt': _ago(200),
      'cols': 80,
      'rows': 24,
      'viewers': [],
    },
  ];
  store.workers = {for (final w in workers) w['id'] as String: WorkerInfo.fromJson(w)};
  store.queue = QueueState.fromJson({
    'maxWorkers': 2,
    'tasks': [
      {
        'id': 't1',
        'provider': 'claude',
        'issue': 42,
        'title': 'Login button does nothing on Safari',
        'prompt': 'Fix #42',
        'addedBy': 'Ada',
        'addedAt': _ago(50),
        'status': 'running',
        'workerId': 'w-claude',
        'workerName': 'Nova',
        'branch': 'nova/fix-login',
        'startedAt': _ago(40),
      },
      {
        'id': 't2',
        'provider': 'opencode',
        'model': 'anthropic/claude-sonnet-4',
        'title': 'Add dark mode to the settings page',
        'prompt': 'Dark mode',
        'addedBy': 'Grace',
        'addedAt': _ago(20),
        'status': 'queued',
      },
      {
        'id': 't3',
        'issue': 57,
        'title': '#57 Flaky upload test on CI',
        'prompt': 'Fix #57',
        'addedBy': 'Linus',
        'addedAt': _ago(8),
        'status': 'queued',
      },
      {
        'id': 't4',
        'provider': 'codex',
        'title': 'Bump the image library and fix the deprecations',
        'prompt': 'Bump',
        'addedBy': 'Ada',
        'addedAt': _ago(300),
        'status': 'done',
        'workerId': 'w-codex',
        'workerName': 'Quill',
        'branch': 'quill/bump-images',
        'startedAt': _ago(280),
        'finishedAt': _ago(190),
        'outcome': 'done',
        'pr': {'number': 61, 'url': 'https://github.com/acme/app/pull/61', 'state': 'MERGED', 'title': 'Bump image library'},
      },
      {
        'id': 't5',
        'title': 'Try the new bundler',
        'prompt': 'bundler',
        'addedBy': 'Grace',
        'addedAt': _ago(400),
        'status': 'done',
        'workerName': 'Echo',
        'finishedAt': _ago(350),
        'outcome': 'failed',
        'error': 'no free desk',
      },
    ],
  });
  store.issues = GhState.fromJson({
    'items': [
      {
        'number': 42,
        'title': 'Login button does nothing on Safari',
        'url': 'https://github.com/acme/app/issues/42',
        'labels': [],
        'assignees': [],
        'author': 'ada',
        'createdAt': '2026-09-20T10:00:00Z',
        'updatedAt': '2026-09-26T10:00:00Z',
        'comments': 2,
      },
    ],
    'fetchedAt': _ago(1),
    'loading': false,
  }, GhIssue.fromJson);
}

Map<String, dynamic> demoChanges(String workerId) => {
  'workerId': workerId,
  'dir': '.agent-office/worktrees/nova',
  'branch': 'nova/fix-login',
  'base': 'main',
  'ahead': 2,
  'subject': 'Fix the login button on Safari',
  'more': 0,
  'prBase': 'main',
  'at': DateTime.now().millisecondsSinceEpoch,
  'files': [
    {'path': 'src/client/ui/login.ts', 'status': 'M', 'additions': 14, 'deletions': 6, 'binary': false, 'uncommitted': true, 'sig': 'a1'},
    {'path': 'src/client/ui/login.css', 'status': 'M', 'additions': 3, 'deletions': 1, 'binary': false, 'uncommitted': false, 'sig': 'a2'},
    {'path': 'tests/login.test.ts', 'status': '?', 'additions': 42, 'deletions': 0, 'binary': false, 'uncommitted': true, 'sig': 'a3'},
    {'path': 'docs/old-login.md', 'status': 'D', 'additions': 0, 'deletions': 18, 'binary': false, 'uncommitted': true, 'sig': 'a4'},
    {'path': 'src/client/assets/button.png', 'status': 'A', 'additions': 0, 'deletions': 0, 'binary': true, 'uncommitted': false, 'sig': 'a5'},
    {
      'path': 'src/client/ui/auth.ts',
      'from': 'src/client/ui/session.ts',
      'status': 'R',
      'additions': 2,
      'deletions': 2,
      'binary': false,
      'uncommitted': false,
      'sig': 'a6',
    },
  ],
};

const demoDiff = '''diff --git a/src/client/ui/login.ts b/src/client/ui/login.ts
index 3b18e51..a9c0d2f 100644
--- a/src/client/ui/login.ts
+++ b/src/client/ui/login.ts
@@ -12,11 +12,19 @@ export function mountLogin(form: HTMLFormElement) {
   const button = form.querySelector('button')!;
   const input = form.querySelector('input')!;
-  button.addEventListener('click', () => submit());
+  // Safari fires no click on a disabled button that gets enabled while pressed:
+  // listen for the form's submit instead, which every browser sends.
+  form.addEventListener('submit', (e) => {
+    e.preventDefault();
+    submit();
+  });
   input.addEventListener('input', () => {
-    button.disabled = !input.value;
+    button.disabled = input.value.trim() === '';
   });

   async function submit() {
-    const r = await fetch('/api/login', { method: 'POST', body: input.value });
+    const r = await fetch('/api/login', {
+      method: 'POST',
+      headers: { 'content-type': 'application/json' },
+      body: JSON.stringify({ password: input.value }),
+    });
     if (!r.ok) return showError(await r.text());
     location.replace('/');
   }
\\ No newline at end of file
''';

Map<String, dynamic> demoSearch(String q) => {
  'q': q,
  'more': false,
  'chat': [
    {'from': 'p2', 'name': 'Grace', 'color': '#06d6a0', 'text': 'Nova is on the login bug, the Safari one', 'at': _ago(14)},
    {'from': 'p1', 'name': 'Ada', 'color': '#4f86f7', 'text': 'did anyone check login on iOS?', 'at': _ago(52)},
  ],
  'terminals': [
    {
      'workerId': 'w-claude',
      'text': '⏺ Update(src/client/ui/login.ts) — listen for the form submit so the login works on Safari',
      'row': 18,
      'rows': 30,
    },
    {'workerId': 'w-claude', 'text': '> fix the login button on Safari', 'row': 3, 'rows': 30},
    {'workerId': 'w-shell', 'text': r'$ git log --oneline | grep login', 'row': 10, 'rows': 24},
  ],
};

/// A Claude Code-ish screen in ANSI, for the terminal window.
final String demoAnsi = () {
  const e = '\x1b[';
  final b = StringBuffer()
    ..write('${e}38;5;209m╭───────────────────────────────────────────────────╮${e}0m\r\n')
    ..write('${e}38;5;209m│${e}0m ${e}1m✻ Welcome to Claude Code!${e}0m                         ${e}38;5;209m│${e}0m\r\n')
    ..write('${e}38;5;209m│${e}0m   ${e}2m/help for help, /status for your current setup${e}0m ${e}38;5;209m│${e}0m\r\n')
    ..write('${e}38;5;209m╰───────────────────────────────────────────────────╯${e}0m\r\n\r\n')
    ..write('${e}90m>${e}0m fix the login button on Safari\r\n\r\n')
    ..write('${e}37m⏺${e}0m I\'ll look at how the login form handles the click.\r\n\r\n')
    ..write('${e}32m⏺${e}0m ${e}1mRead${e}0m(src/client/ui/login.ts)\r\n')
    ..write('  ⎿  Read 48 lines (ctrl+r to expand)\r\n\r\n')
    ..write('${e}32m⏺${e}0m ${e}1mUpdate${e}0m(src/client/ui/login.ts)\r\n')
    ..write('  ⎿  Updated src/client/ui/login.ts with 8 additions and 2 removals\r\n')
    ..write('     ${e}48;5;52m${e}38;5;217m 14 -  button.addEventListener(\'click\', () => submit());           ${e}0m\r\n')
    ..write('     ${e}48;5;22m${e}38;5;157m 14 +  form.addEventListener(\'submit\', (e) => {                    ${e}0m\r\n')
    ..write('     ${e}48;5;22m${e}38;5;157m 15 +    e.preventDefault();                                          ${e}0m\r\n\r\n')
    ..write('${e}32m⏺${e}0m ${e}1mBash${e}0m(npm test -- login)\r\n')
    ..write('  ⎿  ${e}32m✓${e}0m tests/login.test.ts (4 tests) 212ms\r\n')
    ..write('     See https://github.com/acme/app/issues/42 for the report\r\n\r\n')
    ..write('${e}33m✢${e}0m ${e}38;2;255;138;91mRunning the tests…${e}0m ${e}2m(12s · ↑ 1.2k tokens · esc to interrupt)${e}0m\r\n\r\n')
    ..write('${e}90m╭──────────────────────────────────────────────────────────────────────────────────────────────────╮${e}0m\r\n')
    ..write(
      '${e}90m│${e}0m > ${e}7m ${e}0m                                                                                              ${e}90m│${e}0m\r\n',
    )
    ..write('${e}90m╰──────────────────────────────────────────────────────────────────────────────────────────────────╯${e}0m\r\n')
    ..write('  ${e}2m? for shortcuts${e}0m                                                          ${e}36m◯ IDE disconnected${e}0m');
  return b.toString();
}();

ScreenState demoScreen() {
  final s = ScreenState(cols: 100, rows: 30, cursor: (4, 22), version: 1);
  const bold = flagBold;
  final rows = <int, List<Run>>{
    0: [const Run('╭───────────────────────────────────────────────────╮', 209, -1, 0)],
    1: [const Run('│', 209, -1, 0), const Run(' ✻ Welcome to Claude Code!                         ', -1, -1, bold), const Run('│', 209, -1, 0)],
    2: [const Run('╰───────────────────────────────────────────────────╯', 209, -1, 0)],
    4: [const Run('> ', 8, -1, 0), const Run('fix the login button on Safari', -1, -1, 0)],
    6: [const Run('⏺ ', 2, -1, 0), const Run('Read', -1, -1, bold), const Run('(src/client/ui/login.ts)', -1, -1, 0)],
    7: [const Run('  ⎿  Read 48 lines (ctrl+r to expand)', -1, -1, flagDim)],
    9: [const Run('⏺ ', 2, -1, 0), const Run('Update', -1, -1, bold), const Run('(src/client/ui/login.ts)', -1, -1, 0)],
    10: [const Run('     ', -1, -1, 0), Run(' 14 -  button.addEventListener(\'click\', () => submit());   ', 217, 52, 0)],
    11: [const Run('     ', -1, -1, 0), Run(' 14 +  form.addEventListener(\'submit\', (e) => {            ', 157, 22, 0)],
    13: [const Run('✢ ', 3, -1, 0), Run('Running the tests…', rgbFlag | 0xff8a5b, -1, 0), const Run(' (12s · esc to interrupt)', -1, -1, flagDim)],
    15: [const Run('╭──────────────────────────────────────────────────────────────╮', 8, -1, 0)],
    16: [
      const Run('│ > ', 8, -1, 0),
      const Run(' ', -1, -1, flagInverse),
      const Run('                                                           │', 8, -1, 0),
    ],
    17: [const Run('╰──────────────────────────────────────────────────────────────╯', 8, -1, 0)],
  };
  s.lines.addAll(rows);
  return s;
}

ScreenState sparseScreen() {
  final s = ScreenState(cols: 160, rows: 45, cursor: (0, 3), version: 1);
  s.lines[0] = [
    const Run('ada@office', 2, -1, flagBold),
    const Run(':', -1, -1, 0),
    const Run('~/acme-app', 4, -1, flagBold),
    const Run(r'$ ls --color', -1, -1, 0),
  ];
  s.lines[1] = [
    const Run('README.md  ', -1, -1, 0),
    const Run('src', 4, -1, flagBold),
    const Run('  ', -1, -1, 0),
    const Run('tests', 4, -1, flagBold),
    const Run('  package.json  ', -1, -1, 0),
    const Run('run.sh', 2, -1, flagBold),
  ];
  s.lines[2] = [
    const Run('ada@office', 2, -1, flagBold),
    const Run(':', -1, -1, 0),
    const Run('~/acme-app', 4, -1, flagBold),
    const Run(r'$ ', -1, -1, 0),
  ];
  return s;
}
