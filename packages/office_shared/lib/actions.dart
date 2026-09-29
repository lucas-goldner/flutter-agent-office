// What a worker is doing, read off its latest tool call, so the office can act it out: flipping
// through papers while it reads, typing fast while it edits, leaning back while its tests run, a
// globe spinning over the desk while it's on the web. Port of src/shared/actions.ts.

import 'protocol.dart' show WorkerAction;

/// Test runs or builds that fail in a row before a worker puts its head in its hands.
const int failsToDespair = 2;

/// Tool names, lowercased, across Claude Code, Codex and OpenCode.
const Set<String> _readTools = {
  'read',
  'read_file',
  'view',
  'view_file',
  'grep',
  'grep_files',
  'glob',
  'ls',
  'list',
  'list_dir',
  'list_files',
  'find',
  'codesearch',
  'search_files',
  'notebookread',
};
const Set<String> _editTools = {
  'edit',
  'multiedit',
  'write',
  'write_file',
  'create_file',
  'notebookedit',
  'apply_patch',
  'patch',
  'str_replace',
  'str_replace_editor',
  'str_replace_based_edit_tool',
};
const Set<String> _webTools = {'websearch', 'webfetch', 'web_search', 'web_fetch', 'fetch', 'browse', 'search_web'};
const Set<String> _shellTools = {'bash', 'shell', 'exec_command', 'local_shell', 'run_command', 'terminal'};

final RegExp _toolPrefix = RegExp(r'^.*[.:/]');
final RegExp _mcpWeb = RegExp(r'web|fetch|brows|url|http');

/// The action for a tool call: [tool] is its name (e.g. "Bash", "read_file", "mcp__fetch__fetch") and
/// [input] its arguments when the provider sends them, which is how a shell command gets told apart.
WorkerAction? toolAction(Object? tool, [Object? input]) {
  if (tool is! String) return null;
  final name = tool.toLowerCase().replaceFirst(_toolPrefix, '');
  if (_readTools.contains(name)) return WorkerAction.read;
  if (_editTools.contains(name)) return WorkerAction.edit;
  if (_webTools.contains(name)) return WorkerAction.web;
  // An MCP server's own tools: mcp__<server>__<tool>.
  if (name.startsWith('mcp__')) return _mcpWeb.hasMatch(name) ? WorkerAction.web : null;
  if (_shellTools.contains(name)) {
    final command = input is Map ? input['command'] : null;
    return command is String ? commandAction(command) : null;
  }
  return null;
}

/// Runs tests, a build, a type check or a linter: the programs that always do, and the subcommands that do.
final RegExp _check = RegExp(
  r'^(?:tsc|vue-tsc|svelte-check|jest|vitest|mocha|ava|pytest|py\.test|tox|nox|rspec|phpunit|karma|mypy|pyright|eslint|make|cmake|ninja|gradlew?|mvnw?|xcodebuild|ctest|bazel|bazelisk|webpack|rollup|turbo|nx|sbt)$|^(?:go (?:test|build|vet)|cargo (?:test|build|check|clippy|nextest)|dotnet (?:test|build)|swift (?:test|build)|mix (?:test|compile)|zig (?:build|test)|deno (?:test|check)|bun test|(?:flutter|dart) test|playwright test|cypress run|ruff check|(?:next|vite|nuxt|astro|ng) build|rake (?:test|spec))\b',
);

/// A package.json script that tests or builds (`npm test`, `pnpm run build:web`, `yarn typecheck`).
final RegExp _checkScript = RegExp(
  r'^(?:t|test|tests|build|check|lint|typecheck|type-check|tsc|compile|e2e|spec|verify|ci)(?:[:-]\S*)?$',
);

/// Looks at code or history without changing it: the programs, and the subcommands.
final RegExp _read = RegExp(
  r'^(?:cat|bat|head|tail|less|more|grep|egrep|fgrep|rg|ag|ack|find|fd|ls|tree|wc|stat|file|du|jq|diff|nl|awk)$',
);
final RegExp _readSub = RegExp(
  r'^sed -n\b|^git(?: (?:-C \S+|--?[\w-]+(?:=\S+)?))* (?:log|show|diff|status|blame|grep|ls-files|shortlog)\b|^gh (?:issue|pr|repo|run) (?:view|list|diff)\b',
);

/// Leading `FOO=bar` assignments and the wrappers in front of the program that really runs.
final RegExp _prefix = RegExp(
  r'''^(?:\w+=(?:'[^']*'|"[^"]*"|\S*)\s+|(?:sudo|time|nice|nohup|command|exec|env|npx|bunx|pnpx|caffeinate|xvfb-run)\s+|(?:bundle exec|poetry run|uv run|pipenv run|pdm run|pnpm exec|yarn exec|python3? -m)\s+|timeout\s+\S+\s+)''',
);

final RegExp _split = RegExp(r'&&|\|\||[;|\n]');
final RegExp _moving = RegExp(r'^(?:cd|pushd|export|source|set|\.)$');

/// [WorkerAction.test] for a command that runs tests or a build, [WorkerAction.read] for one that only
/// looks at things, null for anything else.
WorkerAction? commandAction(String command) {
  WorkerAction? first;
  var leading = true;
  for (final part in command.split(_split)) {
    final words = _normalize(part);
    if (words.isEmpty) continue;
    if (_isCheck(words)) return WorkerAction.test;
    // Moving around first (`cd app && grep …`) doesn't decide it; the first real command does.
    if (!leading || _moving.hasMatch(words[0])) continue;
    leading = false;
    if (_read.hasMatch(words[0]) || _readSub.hasMatch(words.join(' '))) first = WorkerAction.read;
  }
  return first;
}

final RegExp _lead = RegExp(r'^[\s({]+');
final RegExp _space = RegExp(r'\s+');
final RegExp _dir = RegExp(r'^.*[/\\]');
final RegExp _winExt = RegExp(r'\.(?:cmd|exe|bat)$', caseSensitive: false);

List<String> _normalize(String part) {
  var s = part.replaceFirst(_lead, '').trim();
  for (var prev = ''; prev != s;) {
    prev = s;
    s = s.replaceFirst(_prefix, '');
  }
  final words = [
    for (final w in s.split(_space))
      if (w.isNotEmpty) w,
  ];
  // ./node_modules/.bin/vitest, ./gradlew, jest.cmd: the program's own name.
  if (words.isNotEmpty) words[0] = words[0].replaceFirst(_dir, '').replaceFirst(_winExt, '');
  return words;
}

final RegExp _jsRuntime = RegExp(r'^(?:node|tsx|bun|deno)$');
final RegExp _packageManager = RegExp(r'^(?:npm|pnpm|yarn|bun)$');

bool _isCheck(List<String> words) {
  final prog = words[0];
  final rest = words.sublist(1);
  if (_check.hasMatch(prog) || _check.hasMatch('$prog ${rest.isNotEmpty ? rest[0] : ''}')) return true;
  if (_jsRuntime.hasMatch(prog) && rest.contains('--test')) return true;
  if (_packageManager.hasMatch(prog)) {
    final script = rest.where((w) => !w.startsWith('-') && w != 'run' && w != 'run-script').firstOrNull;
    return script != null && _checkScript.hasMatch(script);
  }
  return false;
}

/// Summary lines test runners and compilers print when something failed, for a run whose exit code
/// the agent piped away (`npm test 2>&1 | tail`). Only the summary formats, so a passing test that
/// happens to be named "reports 3 errors" doesn't count.
final List<RegExp> _failed = [
  RegExp(r'^Tests:\s.*\b[1-9]\d* failed', multiLine: true), // jest
  RegExp(r'^\s*(?:Test Files|Tests)\s+[1-9]\d* failed', multiLine: true), // vitest
  RegExp(r'^(?:#|ℹ) fail [1-9]', multiLine: true), // node --test
  RegExp(r'^=+ .*\b[1-9]\d* (?:failed|errors?)\b', multiLine: true), // pytest
  RegExp(r'^\s+[1-9]\d* failing$', multiLine: true), // mocha
  RegExp(r'^[1-9]\d* examples?, [1-9]\d* failures?', multiLine: true), // rspec
  RegExp(r'^(?:FAIL|--- FAIL)\b', multiLine: true), // go
  RegExp(r'^test result: FAILED', multiLine: true), // cargo
  RegExp(r'^error(?:\[E\d{4}\])?: ', multiLine: true), // rustc
  RegExp(r'\berror TS\d{4}:|^Found [1-9]\d* errors?\b', multiLine: true), // tsc
  RegExp(r'^npm (?:ERR!|error) ', multiLine: true),
  RegExp(r'^make: \*\*\*|\bBUILD FAILED\b', multiLine: true),
];

bool outputFailed(String output) {
  final tail = output.length > 8000 ? output.substring(output.length - 8000) : output;
  return _failed.any((re) => re.hasMatch(tail));
}
