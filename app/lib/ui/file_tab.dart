// A worker's Markdown and text files beside its terminal: "+ File" picks one (the newest first, as the
// one it just wrote is usually the one you want) and its 📄 tab shows it, Markdown drawn as on the
// bookshelf and .txt as it is. The tab looks again every few seconds, so a file the worker is still
// writing keeps up.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:office_shared/docs.dart';

import '../net/api.dart';
import 'markdown.dart';
import 'modal.dart' show timeAgo;
import 'theme.dart';
import 'window_parts.dart' show BoxInput;

/// Stands in for the office in tests: the worker's files, and one's text.
@visibleForTesting
Future<ApiResult> Function(String path) workerFilesGet = Api.getJson;

String _q(String floor, String worker, [Map<String, String> more = const {}]) =>
    Uri(queryParameters: {'floor': floor, 'worker': worker, ...more}).query;

/// The file's name, without its folders.
String fileName(String path) => path.split('/').last;

/// The files to offer, newest first, those matching [filter] (in their path or title).
List<DocFile> pickableFiles(List<DocFile> files, String filter) {
  final f = filter.trim().toLowerCase();
  return [
    for (final d in files)
      if (f.isEmpty || d.path.toLowerCase().contains(f) || (d.title?.toLowerCase().contains(f) ?? false)) d,
  ]..sort((a, b) => b.mtime.compareTo(a.mtime));
}

/// The list to pick a file from, over the terminal until one's picked or it's closed.
class WorkerFilePicker extends StatefulWidget {
  const WorkerFilePicker({
    super.key,
    required this.floor,
    required this.worker,
    required this.onPick,
    required this.onClose,
  });
  final String floor;
  final String worker;
  final ValueChanged<String> onPick;
  final VoidCallback onClose;

  @override
  State<WorkerFilePicker> createState() => _WorkerFilePickerState();
}

class _WorkerFilePickerState extends State<WorkerFilePicker> {
  final _filter = TextEditingController();
  List<DocFile>? _files;
  bool _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await workerFilesGet('/api/worker/files?${_q(widget.floor, widget.worker)}')
        .catchError((Object e) => ApiResult(0, {'error': '$e'}));
    if (!mounted) return;
    if (!r.ok) return setState(() => _error = r.error('HTTP ${r.status}'));
    final list = DocList.fromJson(r.body);
    setState(() {
      _files = list.files;
      _more = list.more;
    });
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final shown = files == null ? const <DocFile>[] : pickableFiles(files, _filter.text);
    final dim = heavy(12, color: Swatch.muted, weight: FontWeight.w700);
    return Semantics(
      label: 'Pick a file to open',
      child: Container(
        decoration: BoxDecoration(
          color: Swatch.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Swatch.ink, width: 2),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('📄 Open a file from the worker\'s folder', style: heavy(15))),
                OfficeButton(
                  key: const ValueKey('file-pick-close'),
                  label: 'Cancel',
                  dense: true,
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 8),
            BoxInput(
              key: const ValueKey('file-pick-filter'),
              controller: _filter,
              hint: 'Filter: name or folder (.md and .txt files, newest first)',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (shown.isNotEmpty) widget.onPick(shown.first.path);
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _error != null
                  ? Text("Couldn't list the files: $_error", style: dim)
                  : files == null
                  ? Text('Looking…', style: dim)
                  : shown.isEmpty
                  ? Text(
                      files.isEmpty ? 'No .md or .txt files in this worker\'s folder yet.' : 'Nothing matches.',
                      style: dim,
                    )
                  : ListView.builder(
                      itemCount: shown.length + (_more ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == shown.length) return Text('…and more: filter to find one.', style: dim);
                        final f = shown[i];
                        return InkWell(
                          key: ValueKey('file-pick-${f.path}'),
                          onTap: () => widget.onPick(f.path),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${f.path.endsWith('.txt') ? '📝' : '📄'} ${fileName(f.path)}', style: heavy(14)),
                                Text(
                                  [if (f.title != null) f.title!, f.path, timeAgo(f.mtime)].join(' · '),
                                  style: dim,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the worker's files: Markdown drawn, text as it is. Looks again every few seconds.
class WorkerFileView extends StatefulWidget {
  const WorkerFileView({super.key, required this.floor, required this.worker, required this.path});
  final String floor;
  final String worker;
  final String path;

  @override
  State<WorkerFileView> createState() => _WorkerFileViewState();
}

class _WorkerFileViewState extends State<WorkerFileView> {
  String? _text;
  String? _error;
  Timer? _timer;

  bool get _markdown => !widget.path.toLowerCase().endsWith('.txt');

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await workerFilesGet('/api/worker/file?${_q(widget.floor, widget.worker, {'path': widget.path})}')
        .catchError((Object e) => ApiResult(0, {'error': '$e'}));
    if (!mounted) return;
    if (!r.ok) return setState(() => _error = r.error('HTTP ${r.status}'));
    final text = DocText.fromJson(r.body).text;
    if (text != _text || _error != null) {
      setState(() {
        _text = text;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Container(
      decoration: BoxDecoration(color: Swatch.paper, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error != null ? '${widget.path} · ⚠️ $_error' : widget.path,
                    style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                OfficeButton(key: const ValueKey('file-reload'), label: '⟳', dense: true, onPressed: _load),
              ],
            ),
          ),
          Expanded(
            child: text == null
                ? Center(
                    child: Text(_error ?? 'Opening…', style: heavy(13, color: Swatch.muted)),
                  )
                : SingleChildScrollView(
                    child: _markdown
                        ? MarkdownView(text, file: true)
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: SelectableText(text, style: mono(13.5, height: 1.45)),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
