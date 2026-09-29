// The shared half of tests/prompts.test.ts. Keeping and using rewritten prompts (server/prompts.ts,
// the board agents' briefs, the queue) is the server's.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('placeholders are filled in once, unknown ones stay, and a line with nothing to say goes', () {
    expect(fillPrompt('Fix #{{number}}: {{ title }}', {'number': 12, 'title': 'The dog'}), 'Fix #12: The dog');
    expect(fillPrompt('Keep {{this}} as it is', {'number': 1}), 'Keep {{this}} as it is');
    // What goes in isn't looked at again.
    expect(fillPrompt('"{{title}}" by {{who}}', {'title': '{{who}}', 'who': 'Ada'}), '"{{who}}" by Ada');
    expect(
      fillPrompt('About:\n{{about}}\n\n{{pr}}\n\n{{issue}}\n\nHow it runs.\n\n{{where}}', {
        'about': 'X',
        'pr': '',
        'issue': 'Issue #3.',
        'where': '',
      }),
      'About:\nX\n\nIssue #3.\n\nHow it runs.',
    );
    // Empty in the middle of a line is just empty.
    expect(fillPrompt("Don't change it.{{before}} List them.", {'before': ''}), "Don't change it. List them.");
    expect(placeholders('{{a}} {{ b }} {{a}} {{9x}}'), ['a', 'b']);
  });

  test('every default only uses placeholders it says it has, and names the ones the office counts on', () {
    for (final id in promptIds) {
      final def = prompts[id]!;
      for (final name in placeholders(def.text)) {
        expect(def.vars.containsKey(name), isTrue, reason: '$id uses {{$name}}');
      }
      for (final name in def.needs) {
        expect(placeholders(def.text).contains(name), isTrue, reason: '$id needs {{$name}}');
      }
      expect(def.text.trim().isNotEmpty, isTrue, reason: id);
    }
  });

  test('the boards send what they always did', () {
    expect(
      fillPrompt(prompts['issue.work']!.text, {'number': 7, 'title': 'Dog barks', 'url': 'u'}),
      'Work on GitHub issue #7: "Dog barks".\n\nRead it first with `gh issue view 7 --comments`. Create a new branch, implement the change, verify it, then open a pull request that closes #7.',
    );
    final merge = fillPrompt(prompts['pull.fixMerge']!.text, {
      'number': 5,
      'title': 'T',
      'url': 'https://github.com/o/r/pull/5',
      'branch': 'feat',
      'base': 'main',
      'repo': 'o/r',
      'merge': 'gh pr merge 5 --squash --repo o/r',
    });
    expect(
      merge,
      matches(
        RegExp(
          r'^Get pull request #5 "T" \(https://github\.com/o/r/pull/5\) ready and merge it\.\n\n1\. Get onto its branch: `gh pr checkout 5`\. If git says `feat` is already checked out',
        ),
      ),
    );
    expect(merge, matches(RegExp('git push origin HEAD:feat')));
    expect(merge, matches(RegExp(r'gh api repos/o/r/pulls/5/comments')));
    expect(
      merge,
      matches(
        RegExp(r'6\. When the checks pass and no feedback is left, merge it: `gh pr merge 5 --squash --repo o/r`\.'),
      ),
    );
    expect(merge, isNot(contains('{{')));
  });

  test('a rewritten prompt is used, and the default otherwise', () {
    const custom = {'issue.work': PromptCustom(text: 'Do #{{number}}', by: 'ann', at: 1)};
    expect(promptText(custom, 'issue.work'), 'Do #{{number}}');
    expect(promptText(custom, 'pull.review'), prompts['pull.review']!.text);
    expect(promptText(null, 'issue.work'), prompts['issue.work']!.text);
    expect(isPromptId('issue.work') && !isPromptId('nope') && !isPromptId(3), isTrue);
    expect(promptMax, 20000);
  });

  test('each board agent is briefed for its own board', () {
    for (final kind in StationKind.values) {
      final def = prompts['station.${kind.wire}']!;
      expect(def.group, PromptGroup.stations);
      expect(def.text, startsWith("You're the ${stationAgent[kind]!.name} in Agent Office"));
      expect(def.text, endsWith('The request:'));
    }
  });
}
