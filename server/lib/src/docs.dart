// The bookshelf: every Markdown file in a floor's project, to read in the office. Port of
// src/server/docs.ts. Git says which files are the project's (tracked, or new and not ignored), so
// node_modules, build output and the office's own .agent-office stay off the shelf. A folder that
// isn't a git checkout is walked instead, skipping the usual suspects.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'changes.dart' show insideCheckout;
import 'decor.dart' show ImageData, ImageError, ImageResult;

const _maxDocs = 5000;
const _maxDocBytes = 2 * 1024 * 1024;

/// Pictures a doc shows, served from the project.
const _maxPictureBytes = 10 * 1024 * 1024;

/// How much of each file is read for its title.
const _headBytes = 4096;

/// A listing this fresh is handed out again rather than asking git.
const _freshMs = 3000;

/// Folders the walk (without git) doesn't go into, besides hidden ones.
const _skipDirs = {'node_modules', 'dist', 'build', 'out', 'target', 'vendor', 'coverage', '__pycache__', 'venv'};
const _maxDepth = 12;

/// What reading a doc gives: its text, or why not (an HTTP status and a message).
sealed class DocResult {
  const DocResult();
}

class DocFound extends DocResult {
  const DocFound(this.doc);
  final DocText doc;
}

class DocFailed extends DocResult {
  const DocFailed(this.status, this.error);
  final int status;
  final String error;
}

/// The paths git lists, or null when the folder isn't in a git checkout (or there's no git).
Future<List<String>?> _gitDocs(String dir) async {
  const args = [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    ':(icase)*.md',
    ':(icase)*.markdown',
  ];
  try {
    final r = await Process.run(
      'git',
      args,
      workingDirectory: dir,
      environment: {'GIT_OPTIONAL_LOCKS': '0'},
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 20));
    if (r.exitCode != 0) return null;
    return {...'${r.stdout}'.split('\u0000').where((s) => s.isNotEmpty)}.toList();
  } catch (_) {
    return null;
  }
}

/// Without git: the Markdown under [dir], not following links or going into hidden or build folders.
Future<List<String>> _walkDocs(String dir) async {
  final out = <String>[];
  final queue = <(String, int)>[('', 0)];
  while (queue.isNotEmpty && out.length <= _maxDocs) {
    final (rel, depth) = queue.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = await Directory(p.join(dir, rel)).list(followLinks: false).toList();
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      final path = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        if (depth < _maxDepth && !name.startsWith('.') && !_skipDirs.contains(name)) queue.add((path, depth + 1));
      } else if (e is File && isDocPath(path)) {
        out.add(path);
      }
    }
  }
  return out;
}

final _frontRe = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n');
final _titleRe = RegExp(r'''^title:\s*["']?(.+?)["']?\s*$''', multiLine: true);
final _fenceRe = RegExp(r'^\s*(```|~~~)');
final _atxRe = RegExp(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$');
final _htmlRe = RegExp(r'<h[12][^>]*>([\s\S]*?)</h[12]>', caseSensitive: false);
final _underlineRe = RegExp(r'^ {0,3}(=+|-+)\s*$');
final _listish = RegExp(r'^\s*[-*+>|]');

/// What a doc calls itself, from its first few KB: a `title:` in its front matter, else its first
/// heading (# Title, Title over ===, or an HTML <h1> as some READMEs have).
String? docTitle(String head) {
  var text = head.replaceFirst(RegExp('^﻿'), '');
  final front = _frontRe.firstMatch(text);
  if (front != null) {
    final t = _titleRe.firstMatch(front.group(1)!);
    if (t != null) return _clean(t.group(1)!);
    text = text.substring(front.group(0)!.length);
  }
  var fenced = false;
  final lines = text.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_fenceRe.hasMatch(line)) fenced = !fenced;
    if (fenced) continue;
    final atx = _atxRe.firstMatch(line);
    if (atx != null) return _clean(atx.group(1)!);
    final html = _htmlRe.firstMatch(line);
    if (html != null && _clean(html.group(1)!) != null) return _clean(html.group(1)!);
    final next = i + 1 < lines.length ? lines[i + 1] : '';
    if (line.trim().isNotEmpty && _underlineRe.hasMatch(next) && !_listish.hasMatch(line)) return _clean(line);
  }
  return null;
}

/// A heading's words without markup: tags, images, link targets, emphasis and code ticks.
String? _clean(String s) {
  final t = s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[*_`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;
  return t.length > 120 ? t.substring(0, 120) : t;
}

Future<String> _head(String file) async {
  final f = await File(file).open();
  try {
    final bytes = await f.read(_headBytes);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    await f.close();
  }
}

/// Roughly `String.prototype.localeCompare`, as changes.dart sorts: case-insensitive first.
int _localeCompare(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : b.compareTo(a);
}

/// A floor's bookshelf: its project's Markdown files, and what's in them.
class Docs {
  Docs(this._dir);

  final String _dir;
  ({int at, DocList list})? _last;
  Future<DocList>? _listing;

  /// Titles by path, kept while the file's size and time stay the same.
  var _titles = <String, ({String sig, String? title})>{};

  /// Every Markdown file in the project, by path.
  Future<DocList> list() {
    final last = _last;
    if (last != null && DateTime.now().millisecondsSinceEpoch - last.at < _freshMs) return Future.value(last.list);
    return _listing ??= _scan().whenComplete(() => _listing = null);
  }

  Future<DocList> _scan() async {
    final found =
        ((await _gitDocs(_dir)) ?? (await _walkDocs(_dir)))
            .where(isDocPath)
            .map((f) => f.split(p.separator).join('/'))
            .toList()
          ..sort(_localeCompare);
    final more = found.length > _maxDocs;
    final files = <DocFile>[];
    final titles = <String, ({String sig, String? title})>{};
    // A few at a time: a big project has thousands.
    final paths = found.take(_maxDocs).toList();
    for (var i = 0; i < paths.length; i += 32) {
      final batch = await Future.wait(
        paths.skip(i).take(32).map((f) async {
          try {
            final abs = p.join(_dir, f);
            final s = await FileStat.stat(abs);
            // Tracked but deleted, or a folder called something.md.
            if (s.type != FileSystemEntityType.file) return null;
            final mtime = s.modified.millisecondsSinceEpoch;
            final sig = '${s.size}:$mtime';
            var known = _titles[f];
            if (known?.sig != sig) known = (sig: sig, title: docTitle(await _head(abs)));
            titles[f] = known!;
            return DocFile(path: f, title: known.title, size: s.size, mtime: mtime);
          } catch (_) {
            return null;
          }
        }),
      );
      files.addAll(batch.whereType<DocFile>());
    }
    _titles = titles;
    final list = DocList(files: files, more: more);
    _last = (at: DateTime.now().millisecondsSinceEpoch, list: list);
    return list;
  }

  /// One doc's Markdown. Only Markdown, and only inside the project (not through a link out of it).
  Future<DocResult> read(String file) async {
    if (!isDocPath(file)) return const DocFailed(415, 'Only Markdown files are on the bookshelf');
    final abs = await insideCheckout(_dir, file);
    if (abs == null) return const DocFailed(404, 'That file is not in the project');
    try {
      final s = await FileStat.stat(abs);
      if (s.type == FileSystemEntityType.notFound) return const DocFailed(404, 'That file is gone');
      if (s.type != FileSystemEntityType.file) return const DocFailed(404, 'That is not a file');
      if (s.size > _maxDocBytes) return const DocFailed(413, 'That file is over ${_maxDocBytes ~/ 1024 ~/ 1024} MB');
      final text = utf8.decode(await File(abs).readAsBytes(), allowMalformed: true);
      return DocFound(DocText(path: file, text: text));
    } on PathNotFoundException {
      return const DocFailed(404, 'That file is gone');
    } catch (err) {
      return DocFailed(500, err is FileSystemException ? err.message : '$err');
    }
  }

  /// A picture a doc shows, from the project.
  Future<ImageResult> picture(String file) async {
    final type = changedImageType(file);
    if (type == null) return const ImageError(415, 'Only pictures');
    final abs = await insideCheckout(_dir, file);
    if (abs == null) return const ImageError(404, 'That file is not in the project');
    try {
      final s = await FileStat.stat(abs);
      if (s.type == FileSystemEntityType.notFound) return const ImageError(404, 'That file is gone');
      if (s.type != FileSystemEntityType.file) return const ImageError(404, 'That is not a file');
      if (s.size > _maxPictureBytes) {
        return const ImageError(413, 'That picture is over ${_maxPictureBytes ~/ 1024 ~/ 1024} MB');
      }
      return ImageData(type, await File(abs).readAsBytes());
    } on PathNotFoundException {
      return const ImageError(404, 'That file is gone');
    } catch (err) {
      return ImageError(500, err is FileSystemException ? err.message : '$err');
    }
  }
}
