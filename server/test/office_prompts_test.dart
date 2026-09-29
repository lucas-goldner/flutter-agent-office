// Port of tests/prompts.test.ts (the server's side: OfficePrompts, the board agents' briefs; the
// queue's parts are in queue_test.dart) and tests/stations.test.ts.
import 'dart:io';

import 'package:agent_office_server/src/prompts.dart';
import 'package:agent_office_server/src/stations.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String scratch() {
  final dir = Directory.systemTemp.createTempSync('office-prompts-').path;
  addTearDown(() => Directory(dir).deleteSync(recursive: true));
  return dir;
}

const OfficeProviders claudeOffice = (
  list: [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex],
  configured: AgentProvider.claude,
);

class _Source implements PromptSource {
  _Source(this._text);
  final String Function(PromptId id) _text;
  @override
  String text(PromptId id) => _text(id);
  @override
  AgentChoice? agent() => null;
}

List<Object?> choice(AgentChoice? c) => [c?.provider, c?.model, c?.effort];

void main() {
  test('a rewritten prompt is kept, used, and put back to the default', () {
    final dir = scratch();
    final told = <PromptsState>[];
    final book = OfficePrompts(dir, claudeOffice, told.add);
    expect(book.setPrompt('issue.work', 'Just do #{{number}}\r\n', 'Ada'), isNull);
    expect(book.text('issue.work'), 'Just do #{{number}}');
    expect(book.state().custom['issue.work']?.by, 'Ada');
    expect(told.length, 1);

    // It's there after a restart.
    final again = OfficePrompts(dir, claudeOffice, (_) {});
    expect(officePrompt(again, 'issue.work', {'number': 4}), 'Just do #4');

    // The default's own text, or null, puts the default back.
    expect(book.setPrompt('issue.work', prompts['issue.work']!.text, 'Ada'), isNull);
    expect(book.state().custom['issue.work'], isNull);
    book.setPrompt('pull.review', 'Look at it', 'Ada');
    expect(book.setPrompt('pull.review', null, 'Grace'), isNull);
    expect(book.text('pull.review'), prompts['pull.review']!.text);

    // Empty only where empty means "send nothing"; never too long, never an unknown prompt.
    expect(book.setPrompt('issue.work', '  ', 'Ada'), contains('can’t be empty'));
    expect(book.setPrompt('queue.worktree', '', 'Ada'), isNull);
    expect(book.text('queue.worktree'), '');
    expect(book.setPrompt('issue.work', 'x' * (promptMax + 1), 'Ada'), contains('at most'));
    expect(book.setPrompt('nope', 'x', 'Ada'), contains('Unknown prompt'));
    expect(promptText(book.state().custom, 'office.namer'), prompts['office.namer']!.text);
  });

  test('the default worker is checked before it is kept, and one the office can no longer start is forgotten', () {
    final dir = scratch();
    final book = OfficePrompts(dir, claudeOffice, (_) {});
    expect(book.agent(), isNull);
    expect(book.setAgent(const AgentChoice(provider: AgentProvider.custom), 'Ada'), contains('Unknown agent provider'));
    expect(
      book.setAgent(const AgentChoice(provider: AgentProvider.claude, model: 'gpt-9'), 'Ada'),
      contains('Invalid Claude model'),
    );
    expect(
      book.setAgent(const AgentChoice(provider: AgentProvider.codex, effort: AgentEffort.high), 'Ada'),
      contains('only be selected for Claude'),
    );
    expect(
      book.setAgent(const AgentChoice(provider: AgentProvider.opencode, model: 'no slash'), 'Ada'),
      contains('Invalid OpenCode model'),
    );
    expect(
      book.setAgent(const AgentChoice(provider: AgentProvider.claude, model: 'opus', effort: AgentEffort.high), 'Ada'),
      isNull,
    );
    expect(choice(book.agent()), [AgentProvider.claude, 'opus', AgentEffort.high]);
    expect(book.state().agent?.by, 'Ada');
    expect(choice(OfficePrompts(dir, claudeOffice, (_) {}).agent()), [AgentProvider.claude, 'opus', AgentEffort.high]);
    expect(book.setAgent(null, 'Ada'), isNull);
    expect(book.agent(), isNull);

    // Custom, then the office comes back with another --agent: custom is gone.
    final file = File(p.join(dir, 'prompts.json'));
    file.writeAsStringSync('{"custom": {}, "agent": {"provider": "custom", "by": "Ada", "at": 1}}');
    const customOffice = (
      list: [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex, AgentProvider.custom],
      configured: AgentProvider.custom,
    );
    expect(choice(OfficePrompts(dir, customOffice, (_) {}).agent()), [AgentProvider.custom, null, null]);
    expect(OfficePrompts(dir, claudeOffice, (_) {}).agent(), isNull);
    // A broken file is the defaults.
    file.writeAsStringSync('{nope');
    const claudeOnly = (list: [AgentProvider.claude], configured: AgentProvider.claude);
    expect(OfficePrompts(dir, claudeOnly, (_) {}).state().toJson(), {'custom': <String, Object?>{}});
    expect(file.readAsStringSync(), isNotEmpty);
    // What comes off the wire is checked as it is: a provider that isn't one, an effort that isn't one.
    expect(book.problem('bad', null, null), contains('Unknown agent provider'));
    expect(book.problem('claude', null, 'overdrive'), contains('Invalid effort'));
  });

  test('a board agent is told its rewritten brief', () {
    final source = _Source((id) => id == 'station.pulls' ? 'You review PRs. The request:' : prompts[id]!.text);
    expect(stationBrief(StationKind.pulls, source), 'You review PRs. The request:');
    expect(stationBrief(StationKind.issues, source), stationBrief(StationKind.issues));
  });

  // tests/stations.test.ts, with `agent-office queue` in office-queue's place.
  test('every board agent reaches the queue with agent-office queue, not its own curl calls', () {
    for (final kind in StationKind.values) {
      final brief = stationBrief(kind);
      expect(brief, contains('agent-office queue list'), reason: '$kind');
      expect(brief, matches(RegExp(r'agent-office queue add --title "[^"]+"')), reason: '$kind');
      expect(brief, contains("<<'EOF'"), reason: '$kind: the prompt goes in a quoted heredoc');
      expect(brief, contains('agent-office queue remove <id>'), reason: '$kind');
      expect(brief, isNot(matches(RegExp(r'curl|/office/queue|AGENT_OFFICE_HOOK_TOKEN|Authorization|office-queue'))));
      // The request is typed in right after it.
      expect(brief.endsWith('The request:'), isTrue, reason: '$kind');
    }
  });

  test('the queue agent only ever queues work, however small, and says what it queued', () {
    final brief = stationBrief(StationKind.queue);
    for (final said in [
      'Queue agent',
      'even a one-line fix',
      'even when someone asks you to do it yourself',
      "don't edit, create or delete files",
      "don't run builds, tests or installs",
      "don't write code",
      'goes on the task queue, always',
      "say in a few lines what you queued: each task's id and title",
    ]) {
      expect(brief, contains(said));
    }
    expect(brief, isNot(contains('unless the person asks you for something else')));
  });

  test('the issues and PR agents keep their jobs, and may still be asked for something else', () {
    final issues = stationBrief(StationKind.issues);
    expect(issues, contains('Issues agent'));
    expect(issues, contains('GitHub issues with the gh CLI'));
    final pulls = stationBrief(StationKind.pulls);
    expect(pulls, contains('PR agent'));
    expect(pulls, contains('gh pr diff'));
    for (final brief in [issues, pulls]) {
      expect(brief, contains('goes on the task queue, unless the person asks you for something else'));
      expect(brief, contains('say in a few lines what you did, with links'));
      expect(brief, isNot(contains('one-line fix')));
    }
  });

  test('the queue agent is launched without the file-editing tools', () {
    expect(queueAgentDisallowedTools, ['Edit', 'Write', 'NotebookEdit']);
  });
}
