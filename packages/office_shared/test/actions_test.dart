// Port of tests/actions.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('tool calls map to what a worker acts out, across providers', () {
    for (final (tool, action) in const [
      ('Read', WorkerAction.read),
      ('Grep', WorkerAction.read),
      ('Glob', WorkerAction.read),
      ('read_file', WorkerAction.read),
      ('Edit', WorkerAction.edit),
      ('Write', WorkerAction.edit),
      ('MultiEdit', WorkerAction.edit),
      ('apply_patch', WorkerAction.edit),
      ('WebSearch', WorkerAction.web),
      ('WebFetch', WorkerAction.web),
      ('webfetch', WorkerAction.web),
      ('mcp__fetch__fetch', WorkerAction.web),
      ('mcp__github__create_issue', null),
      ('TodoWrite', null),
      ('Task', null),
      ('exec_command', null),
    ]) {
      expect(toolAction(tool), action, reason: tool);
    }
    expect(toolAction('Bash', {'command': 'npm test'}), WorkerAction.test);
    expect(toolAction('Bash', {'command': 'git commit -m "wip"'}), isNull);
    expect(toolAction(null), isNull);
  });

  test('shell commands that run tests or builds', () {
    for (final cmd in [
      'npm test',
      'npm run build',
      'npm run test:unit -- --watch=false',
      'pnpm --silent typecheck',
      'yarn lint',
      'bun test',
      'cd web && npm run build 2>&1 | tail -20',
      'npx vitest run src/foo.test.ts',
      'NODE_ENV=test node --import tsx --test tests/*.test.ts',
      './node_modules/.bin/jest --ci',
      'python -m pytest -x tests/',
      'uv run pytest',
      'go test ./...',
      'cargo clippy --all-targets',
      'timeout 300 make -j8',
      './gradlew assemble',
      'npx tsc --noEmit',
    ]) {
      expect(commandAction(cmd), WorkerAction.test, reason: cmd);
    }
  });

  test('shell commands that only look at things', () {
    for (final cmd in [
      'cat src/main.ts',
      'rg -n "setStatus" src',
      'grep -r foo . | head',
      'cd src && ls -la',
      'git --no-pager log --oneline -5',
      'git -C ../other diff HEAD~1',
      'sed -n 1,40p README.md',
      'gh pr view 12 --comments',
    ]) {
      expect(commandAction(cmd), WorkerAction.read, reason: cmd);
    }
  });

  test('other shell commands are just typing', () {
    // A test file named in a read, a script called "test" echoed: neither runs tests.
    for (final cmd in [
      'git add -A && git commit -m "Add tests"',
      'npm install',
      'mkdir -p tests',
      'echo "npm test"',
      'rm -f build.log',
      'git push origin HEAD',
    ]) {
      expect(commandAction(cmd), isNull, reason: cmd);
    }
    expect(commandAction('cat tests/actions.test.ts'), WorkerAction.read);
  });

  test('a failed run is told apart from a passing one by its summary', () {
    for (final out in [
      'Tests:       2 failed, 14 passed, 16 total',
      ' Test Files  1 failed | 3 passed (4)',
      '# tests 40\n# pass 38\n# fail 2',
      '============ 3 failed, 10 passed in 1.20s ============',
      '  12 passing (40ms)\n  1 failing',
      '--- FAIL: TestLogin (0.00s)\nFAIL\tgithub.com/x/y\t0.01s',
      'test result: FAILED. 3 passed; 1 failed',
      "src/a.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.",
      'npm ERR! Test failed.  See above for more details.',
    ]) {
      expect(outputFailed(out), isTrue, reason: out);
    }
    for (final out in [
      'Tests:       16 passed, 16 total',
      '# tests 40\n# pass 40\n# fail 0',
      '============ 10 passed in 1.20s ============',
      '  ✓ reports 3 errors when the input is empty',
      'Found 0 errors. Watching for file changes.',
      'ok  \tgithub.com/x/y\t0.01s',
    ]) {
      expect(outputFailed(out), isFalse, reason: out);
    }
  });
}
