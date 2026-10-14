// Pull requests for a worker's branch: reading the one a worker opened itself off its shell
// command, finding and opening them, drafting their title and body, and listing the pull requests of
// one change across repositories in each of them. Upstream's server/workers/pr.ts (the parts that
// don't need the worker manager; those are in worker_trees.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:office_shared/shared.dart';

import 'github.dart' show gh;
import 'worker_handle.dart' show LiveInfo;

const _prTitleMax = 72;
const _prTaskMax = 2500;

/// Around the list of a change's pull requests in each of their descriptions, so it can be brought up to date.
const relatedStart = '<!-- agent-office:related -->';
const relatedEnd = '<!-- /agent-office:related -->';

/// `gh pr create` being run, alone or in a longer line: not one that only names it (a grep for it, a quoted string).
final _createsPr = RegExp(r'(?:^|[\s;&|(])gh\s+pr\s+create\b');

/// How many of the pull requests a worker opened before its latest are remembered.
const maxPastPrs = 20;
final _prUrl = RegExp(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)');

/// The pull request a worker opened itself, read off a shell command it ran and what that printed:
/// `gh pr create` prints the new pull request's URL, or the one its branch already had. The last one
/// printed is it.
({String repo, int number, String url})? ownPr(Object? command, String output) {
  if (command is! String || !_createsPr.hasMatch(command)) return null;
  final all = _prUrl.allMatches(output);
  if (all.isEmpty) return null;
  final last = all.last;
  return (repo: last.group(1)!, number: int.parse(last.group(2)!), url: last.group(0)!);
}

/// Another floor's repository for a worker to work in too (see WorkerInfo.repos).
class RepoSource {
  const RepoSource({required this.floor, required this.name, this.repo, required this.dir});

  final String floor;

  /// The floor's name, for messages.
  final String name;

  /// owner/name on GitHub, when known.
  final String? repo;

  /// Its checkout.
  final String dir;
}

/// A pull request [WorkerManager.openPr] opened, or found already open, for a worker's branch.
class OpenedPr {
  const OpenedPr({this.repo, required this.number, required this.url, required this.existed, required this.dirty});

  /// For a worker across repositories: which of its repositories (the folder in its workspace).
  final String? repo;
  final int number;
  final String url;

  /// It was already open (a second press, or one opened by hand).
  final bool existed;

  /// The worktree has uncommitted changes that aren't in it.
  final bool dirty;
}

/// The open pull request whose head is [branch], if any.
Future<PrRef?> findOpenPr(String branch, String cwd) async {
  final out = await gh([
    'pr',
    'list',
    '--head',
    branch,
    '--state',
    'open',
    '--limit',
    '1',
    '--json',
    'number,url',
  ], cwd);
  final list = jsonDecode(out.trim().isEmpty ? '[]' : out);
  if (list is! List || list.isEmpty || list.first is! Map) return null;
  final found = list.first as Map;
  return PrRef(number: (found['number'] as num).toInt(), url: '${found['url']}');
}

/// `gh pr create` for a pushed branch; resolves to the new pull request.
/// With [env], as whoever pressed the button (see signins.dart).
Future<PrRef> createPr(
  String branch,
  String? base,
  String title,
  String body,
  String cwd, [
  Map<String, String>? env,
]) async {
  final out = await gh(
    [
      'pr',
      'create',
      '--head',
      branch,
      if (base != null) ...['--base', base],
      '--title',
      title,
      '--body',
      body,
    ],
    cwd,
    60000,
    env,
  );
  final url = out.trim().split('\n').last;
  final number = int.tryParse(RegExp(r'/pull/(\d+)').firstMatch(url)?.group(1) ?? '') ?? 0;
  if (number == 0) throw PrError('gh did not return a pull request URL (${truncateLine(out, 120)})');
  return PrRef(number: number, url: url);
}

/// Why a pull request couldn't be opened.
class PrError implements Exception {
  PrError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// owner/name#12 for a pull request on GitHub (which links it with its title), else its URL.
String prRef(String url) {
  final m = RegExp(r'github\.com/([^/]+/[^/]+)/pull/(\d+)').firstMatch(url);
  return m != null ? '${m.group(1)}#${m.group(2)}' : url;
}

/// The list of a change's pull requests across repositories, for the description of the one at [self].
String relatedBlock(List<({String? repo, String url})> prs, String self, String branch) {
  final lines = [
    for (final pr in prs)
      '- ${pr.repo != null ? '**${pr.repo}**: ' : ''}${prRef(pr.url)}${pr.url == self ? ' (this one)' : ''}',
  ];
  return [
    relatedStart,
    '**One change across ${prs.length} repositories**, each on `$branch`: review and merge them together.',
    '',
    ...lines,
    relatedEnd,
  ].join('\n');
}

/// A description with its list of related pull requests put in, or brought up to date.
String withRelated(String body, String block) {
  final at = body.indexOf(relatedStart);
  final end = at < 0 ? -1 : body.indexOf(relatedEnd, at);
  if (end >= 0) return body.substring(0, at) + block + body.substring(end + relatedEnd.length);
  return body.trim().isNotEmpty ? '${body.trimRight()}\n\n$block' : block;
}

/// A pull request title and body from what the worker was asked to do. The title is the issue's
/// title when the task came off the issues board, else the task's first line; the body carries the
/// task, the commits, a "Closes #n" when the task asked for one, and which desk it came from. With
/// [other], it's for one of the other repositories of a worker across repositories: the issue is its
/// own floor's (`home`), so this one only mentions it.
({String title, String body}) draftPr(LiveInfo info, List<String> commits, String by, {({String? home})? other}) {
  final task = (info.prompt ?? '').replaceAll(RegExp(r'\r\n?'), '\n').trim();
  final firstLine = task.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  // The issues board hands work over as: Work on GitHub issue #12: "Title".
  final issue = RegExp(r'\bissue #(\d+):\s*["“](.+?)["”]\.?\s*$', caseSensitive: false).firstMatch(firstLine);
  String? nonEmpty(String? s) => s != null && s.isNotEmpty ? s : null;
  final title = truncateLine(
    nonEmpty(issue?.group(2)) ??
        nonEmpty(firstLine.replaceFirst(RegExp(r'[.:;,]+$'), '')) ??
        nonEmpty(commits.isNotEmpty ? commits.first.replaceFirst(RegExp(r'^\S+\s+'), '') : null) ??
        nonEmpty(info.worktree?.branch) ??
        info.name,
    _prTitleMax,
  );
  final closes =
      RegExp(
        r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[^\n]{0,40}?#(\d+)',
        caseSensitive: false,
      ).firstMatch(task)?.group(1) ??
      issue?.group(1);
  final parts = <String>[];
  if (task.isNotEmpty) parts.add('## Task\n\n${task.length > _prTaskMax ? '${task.substring(0, _prTaskMax)}…' : task}');
  String commitLine(String c) {
    final i = c.indexOf(' ');
    final hash = i < 0 ? c.substring(0, max(0, c.length - 1)) : c.substring(0, i);
    return '- `$hash` ${c.substring(i + 1)}';
  }

  parts.add('## Commits\n\n${commits.map(commitLine).join('\n')}');
  if (closes != null && other == null) {
    parts.add('Closes #$closes');
  } else if (closes != null && other?.home != null) {
    parts.add('Part of ${other!.home}#$closes');
  }
  parts.add('_Opened from Agent Office by $by · ${info.name} at ${deskById[info.deskId]?.label ?? info.deskId}_');
  return (title: title, body: parts.join('\n\n'));
}

/// owner/name of a checkout's origin on GitHub, when it has one.
String? originRepo(String dir) {
  try {
    final r = Process.runSync('git', ['remote', 'get-url', 'origin'], workingDirectory: dir);
    if (r.exitCode != 0) return null;
    return normalizeRepo('${r.stdout}'.trim());
  } catch (_) {
    return null;
  }
}

/// [s] on one line, cut to [n] characters with an ellipsis.
String truncateLine(String s, int n) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > n ? '${one.substring(0, n - 1)}…' : one;
}
