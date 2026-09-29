// The windows behind the board cards: a port of pull.ts. A PR opens on its conversation
// (description, comments, reviews, line comments, checks) with a Files tab for the diff, where you
// tick files off as reviewed; from here you comment, merge or close it, or hand it to a worker to
// review, fix up and merge.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../interop/browser.dart';
import '../interop/open_url.dart';
import '../net/server.dart';
import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'gh_logic.dart';
import 'markdown.dart';
import 'modal.dart';
import 'pull_diff.dart';
import 'theme.dart';
import 'window_parts.dart' show BoxInput;

// ---- REST ---------------------------------------------------------------------------------------

class GhApiError implements Exception {
  GhApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The REST calls the GitHub windows make. A seam: the preview swaps in fakes.
abstract final class GhApi {
  static Future<Map<String, dynamic>> Function(String url) getJson = _getJson;
  static Future<String> Function(String url) getText = _getText;

  static Future<http.Response> _get(String url) async {
    final r = await http.get(serverUri(url), headers: {'cache-control': 'no-store', ...serverHeaders()});
    if (r.statusCode < 200 || r.statusCode >= 300) {
      String? error;
      try {
        final j = jsonDecode(r.body);
        if (j is Map && j['error'] is String) error = j['error'] as String;
      } catch (_) {
        // not JSON
      }
      throw GhApiError(error ?? 'HTTP ${r.statusCode}');
    }
    return r;
  }

  static Future<Map<String, dynamic>> _getJson(String url) async {
    final v = jsonDecode((await _get(url)).body);
    return v is Map<String, dynamic> ? v : {};
  }

  static Future<String> _getText(String url) async => (await _get(url)).body;
}

/// The board windows ask about the floor you're on.
String onFloor(Store store, String url) =>
    store.floor != null ? '$url${url.contains('?') ? '&' : '?'}floor=${Uri.encodeComponent(store.floor!)}' : url;

// ---- Preferences --------------------------------------------------------------------------------

Object? _pref(String key) {
  try {
    return jsonDecode(storageGet(key) ?? 'null');
  } catch (_) {
    return null;
  }
}

void _savePref(String key, Object? v) => storageSet(key, jsonEncode(v));

const _mergeKey = 'agent-office.merge';
const _filesKey = 'agent-office.pr-files';
const _tabKey = 'agent-office.pr-tab';

/// Followed by the issue or PR's URL: the comment you were writing there.
const _draftKey = 'agent-office.comment:';

({GhMergeMethod method, bool deleteBranch}) _mergePref(List<GhMergeMethod> methods) => mergePrefFrom(_pref(_mergeKey), methods);

final _reviewStore = KeyValueStore(get: storageGet, set: storageSet);

// ---- Small pieces ---------------------------------------------------------------------------------

const _ghBg = Color(0xFFF3EBE0);
const _blueLink = Color(0xFF1D6FD6);
const _addFg = Color(0xFF2A9D4B);
const _delFg = Color(0xFFC3423F);

/// A GitHub label in its own color, with text that stays readable on dark ones.
class LabelChip extends StatelessWidget {
  const LabelChip(this.label, {super.key});
  final GhLabel label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: parseHex(label.color),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Swatch.ink, width: 1.5),
        ),
        child: Text(label.name, style: heavy(10, color: labelIsDark(label.color) ? Colors.white : Swatch.ink)),
      );
}

class GhAvatar extends StatelessWidget {
  const GhAvatar(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    var x = 0;
    for (final r in name.runes) {
      x = (x * 31 + String.fromCharCode(r).codeUnitAt(0)).toSigned(32);
    }
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: parseHex(kAvatarColors[x.abs() % kAvatarColors.length]),
        shape: BoxShape.circle,
        border: Border.all(color: Swatch.ink, width: 2),
      ),
      child: Text(name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase(), style: heavy(12, color: Colors.white, weight: FontWeight.w900)),
    );
  }
}

/// A link that opens in a new tab.
class _Link extends StatelessWidget {
  const _Link(this.text, this.url, {this.style, this.tooltip});
  final String text;
  final String url;
  final TextStyle? style;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget w = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => openUrl(url), child: Text(text, style: style)),
    );
    if (tooltip != null && tooltip!.isNotEmpty) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

String _localTime(String iso) => DateTime.tryParse(iso)?.toLocal().toString().split('.').first ?? '';

Widget _when(String iso, [String? url]) {
  final style = heavy(13, color: Swatch.muted, weight: FontWeight.w700);
  return url != null && url.isNotEmpty
      ? _Link(timeAgo(iso), url, style: style, tooltip: _localTime(iso))
      : Tooltip(message: _localTime(iso), child: Text(timeAgo(iso), style: style));
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.tone);
  final String text;

  /// 'ok', 'bad', 'muted' or ''.
  final String tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      'ok' => (Swatch.good, Colors.white),
      'bad' => (Swatch.bad, Colors.white),
      'muted' => (const Color(0xFFDEE2E6), Swatch.ink),
      _ => (Colors.white, Swatch.ink),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
      child: Text(text, style: heavy(11, color: fg, weight: FontWeight.w900)),
    );
  }
}

/// A white card with a header strip (`.gh-card`).
class _GhCard extends StatelessWidget {
  const _GhCard({required this.header, this.child, this.tone = ''});
  final List<Widget> header;
  final Widget? child;
  final String tone;

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Swatch.ink, width: 2),
          boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: switch (tone) { 'ok' => const Color(0xFFD8F5E3), 'bad' => const Color(0xFFFFE3EA), _ => Swatch.paper2 },
                border: child == null ? null : const Border(bottom: BorderSide(color: Color(0x262B2D42), width: 2)),
              ),
              child: DefaultTextStyle(
                style: heavy(13, color: Swatch.muted, weight: FontWeight.w700),
                child: Row(children: _gap(header, 8)),
              ),
            ),
            ?child,
          ],
        ),
      );
}

List<Widget> _gap(List<Widget> ws, double g) => [
      for (var i = 0; i < ws.length; i++) ...[if (i > 0 && ws[i] is! Spacer) SizedBox(width: g), ws[i]],
    ];

Widget _commentCard(GhComment c, String itemUrl, String verb, [(String, String)? badge]) => _GhCard(
      tone: badge?.$2 ?? '',
      header: [
        GhAvatar(c.author),
        Text(c.author, style: heavy(13, weight: FontWeight.w900)),
        if (verb.isNotEmpty) Text(verb),
        _when(c.createdAt, c.url),
        if (badge != null) _Badge(badge.$1, badge.$2),
      ],
      child: c.body.trim().isNotEmpty || badge == null ? MarkdownView(c.body, itemUrl: itemUrl) : null,
    );

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 3, color: Swatch.ink, backgroundColor: Color(0x332B2D42)),
      );
}

Widget _spinnerRow(String text) => Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [const _Spinner(), const SizedBox(width: 10), Text(text, style: heavy(14, color: Swatch.muted))],
      ),
    );

Widget _errorBox(String text, [VoidCallback? retry]) => Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(color: const Color(0xFFFFD6E0), borderRadius: BorderRadius.circular(14), border: Border.all(color: Swatch.ink, width: 3)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load from GitHub: $text", style: heavy(14), textAlign: TextAlign.center),
            if (retry != null) ...[const SizedBox(height: 10), OfficeButton(label: 'Try again', onPressed: retry)],
          ],
        ),
      ),
    );

Widget _quiet(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text, textAlign: TextAlign.center, style: heavy(14, color: Swatch.muted, weight: FontWeight.w700)),
    );

Widget _checksList(List<GhCheck> checks) => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 190),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in sortedChecks(checks))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Semantics(label: c.state.wire, child: Text(checkStateIcon[c.state]!, style: heavy(13))),
                    const SizedBox(width: 8),
                    Flexible(
                      child: c.url != null
                          ? _Link(c.name, c.url!, style: heavy(13, weight: FontWeight.w700))
                          : Text(c.name, style: heavy(13, weight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

Color _toneBg(Tone t) => switch (t) {
      Tone.ok => const Color(0xFFD8F5E3),
      Tone.warn => const Color(0xFFFFF3C4),
      Tone.bad => const Color(0xFFFFD6E0),
      Tone.muted => const Color(0xFFEEF0F2),
    };

Widget _status(String icon, String text, Tone tone) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: _toneBg(tone), borderRadius: BorderRadius.circular(10), border: Border.all(color: Swatch.ink, width: 2)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(icon, style: heavy(14)), const SizedBox(width: 8), Expanded(child: Text(text, style: heavy(14).copyWith(height: 1.4)))],
      ),
    );

/// The result line under a dialog: a spinner while it works, the error when it didn't.
Widget _result(String? busyText, String? error) {
  if (error != null) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: const Color(0xFFFFD6E0), borderRadius: BorderRadius.circular(10), border: Border.all(color: Swatch.ink, width: 2)),
      child: SelectableText(error, style: heavy(13, weight: FontWeight.w700)),
    );
  }
  if (busyText == null) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(10), border: Border.all(color: Swatch.ink, width: 2)),
    child: Row(children: [const _Spinner(), const SizedBox(width: 8), Expanded(child: Text(busyText, style: heavy(14)))]),
  );
}

/// A checkbox with its label (`label.gh-check`).
class _Check extends StatelessWidget {
  const _Check({required this.value, required this.onChanged, required this.label, this.tooltip});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget w = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            _TickBox(value, color: Swatch.accent),
            const SizedBox(width: 8),
            Flexible(child: Text(label, style: heavy(14, weight: FontWeight.w700))),
          ],
        ),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

class _TickBox extends StatelessWidget {
  const _TickBox(this.on, {this.color = Swatch.accent});
  final bool on;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: on ? color : Colors.white,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? color : const Color(0xFF767676), width: 1.5),
        ),
        child: on ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
      );
}

/// Buttons in a row where one is picked (`.seg`).
Widget _seg<T>(List<T> options, T picked, String Function(T) label, ValueChanged<T> onPick, {bool dense = true}) => Wrap(
      spacing: dense ? 4 : 8,
      runSpacing: 6,
      children: [
        for (final o in options) OfficeButton(label: label(o), kind: o == picked ? BtnKind.on : BtnKind.plain, dense: dense, onPressed: () => onPick(o)),
      ],
    );

Widget _small(String text) => Text(text, style: mono(12, color: Swatch.muted));

Widget _plusMinus(int add, int del, {bool binary = false, String binWord = 'bin'}) {
  final s = mono(12, weight: FontWeight.w800);
  if (binary) return Text(binWord, style: s.copyWith(color: Swatch.muted));
  return Text.rich(TextSpan(children: [
    TextSpan(text: '+$add', style: s.copyWith(color: _addFg)),
    const TextSpan(text: ' '),
    TextSpan(text: '−$del', style: s.copyWith(color: _delFg)),
  ]));
}

Widget _code(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: mono(12, color: const Color(0xFF1D4F91))),
    );

/// The .pill for an issue or PR, by its CSS class.
Widget _pill(String word, String cls) {
  final (bg, fg) = switch (cls) {
    'working' => (Swatch.warn, Swatch.ink),
    'done' => (Swatch.good, Colors.white),
    'idle' => (const Color(0xFFE0F2FE), Swatch.ink),
    'offline' => (const Color(0xFFDEE2E6), Swatch.ink),
    _ => (Colors.white, Swatch.ink),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
    child: Text(word, style: heavy(12, color: fg, weight: FontWeight.w900)),
  );
}

Widget _title(Widget pill, String text) => Row(
      children: [
        pill,
        const SizedBox(width: 10),
        Flexible(child: Tooltip(message: text, child: Text(text, overflow: TextOverflow.ellipsis))),
      ],
    );

/// A multi-line text box in the office's style.
Widget _textArea(TextEditingController c, {FocusNode? focus, String? hint, int minLines = 4, bool readOnly = false, ValueChanged<String>? onChanged, bool autofocus = false}) =>
    TextField(
      controller: c,
      focusNode: focus,
      minLines: minLines,
      maxLines: 12,
      readOnly: readOnly,
      autofocus: autofocus,
      onChanged: onChanged,
      style: heavy(15, weight: FontWeight.w500),
      decoration: InputDecoration(hintText: hint, hintStyle: heavy(15, color: Swatch.muted, weight: FontWeight.w500)),
    );

// ---- Comment box --------------------------------------------------------------------------------

/// Where you comment on an issue or a PR's conversation. It goes out through the server's gh, so
/// as that account rather than as you. The draft is kept per item until it is posted, so Esc or a
/// closed window doesn't lose it.
class _CommentBox extends StatefulWidget {
  const _CommentBox({required this.kind, required this.number, required this.itemUrl, required this.net, required this.onPosted, this.viewer = ''});
  final GhKind kind;
  final int number;
  final String itemUrl;
  final OfficeSocketLike net;
  final ValueChanged<GhComment> onPosted;

  /// The GitHub account the comment goes out as, once the window knows it.
  final String viewer;

  @override
  State<_CommentBox> createState() => _CommentBoxState();
}

/// What the windows need of the socket: send, and the replies.
typedef OfficeSocketLike = ({void Function(ClientMsg) send, Stream<ServerMsg> messages});

class _CommentBoxState extends State<_CommentBox> {
  final _ta = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _preview = false;
  String? _error;
  Timer? _timer;
  StreamSubscription<ServerMsg>? _sub;

  String get _key => '$_draftKey${widget.itemUrl}';

  @override
  void initState() {
    super.initState();
    final d = _pref(_key);
    _ta.text = d is String ? d : '';
  }

  @override
  void dispose() {
    _settle();
    _ta.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _saveDraft() {
    if (_ta.text.isNotEmpty) {
      _savePref(_key, _ta.text);
    } else {
      storageRemove(_key);
    }
  }

  void _settle() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _busy = false;
  }

  void _setPreview(bool on) {
    setState(() => _preview = on);
    if (!on) _focus.requestFocus();
  }

  void _submit() {
    final body = _ta.text;
    if (_busy || body.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _sub = widget.net.messages.listen((m) {
      if (m is! GhCommentedMsg || m.kind != widget.kind || m.number != widget.number) return;
      _settle();
      if (!mounted) return;
      final c = m.comment;
      setState(() {
        if (c != null) {
          _ta.text = '';
          _saveDraft();
          _preview = false;
        } else {
          _error = m.error ?? 'GitHub did not take the comment';
        }
      });
      if (c != null) widget.onPosted(c);
    });
    // The office drops messages while it's disconnected, and then no answer comes.
    _timer = Timer(const Duration(seconds: 45), () {
      _settle();
      if (mounted) {
        setState(() => _error = 'No answer from the office. Reload the conversation to see whether the comment went through before posting it again.');
      }
    });
    widget.net.send(GhCommentCmd(kind: widget.kind, number: widget.number, body: body));
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.viewer.isNotEmpty ? 'Posts to GitHub as @${widget.viewer}' : "Posts to GitHub as the office's gh account";
    final canPost = !_busy && _ta.text.trim().isNotEmpty;
    return _GhCard(
      header: [
        Text('Add a comment', style: heavy(13, weight: FontWeight.w900)),
        const Spacer(),
        _seg([false, true], _preview, (p) => p ? 'Preview' : 'Write', _setPreview),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _preview
                ? Container(
                    constraints: const BoxConstraints(minHeight: 96),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0x402B2D42), width: 3),
                    ),
                    child: _ta.text.trim().isNotEmpty
                        ? MarkdownView(_ta.text, itemUrl: widget.itemUrl)
                        : Padding(padding: const EdgeInsets.all(12), child: _quiet('Nothing to preview.')),
                  )
                : CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
                      const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
                    },
                    child: Semantics(
                      label: 'Comment',
                      child: _textArea(
                        _ta,
                        focus: _focus,
                        readOnly: _busy,
                        hint: 'Leave a comment. Markdown works; ⌘/Ctrl+Enter posts it.',
                        onChanged: (_) => setState(_saveDraft),
                      ),
                    ),
                  ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 0), child: _result(null, _error)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                Expanded(child: Text(who, style: heavy(12, color: Swatch.muted, weight: FontWeight.w700))),
                const SizedBox(width: 10),
                OfficeButton(label: _busy ? 'Posting…' : '💬 Comment', kind: BtnKind.primary, onPressed: canPost ? _submit : null),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Board actions --------------------------------------------------------------------------------

/// What the board windows do with workers; each is main.ts's boardActions() entry of the same name.
class BoardActions {
  BoardActions(this.scope);
  final OfficeScope scope;

  /// Start a worker on a ready-made prompt (shown for editing first).
  void assign(String prompt, String title) => scope.actions.sendToWorker('🤖 $title', initial: prompt);

  /// Your own prompt about an issue or PR; `context` goes first so the worker knows which.
  void ask(String context, String title) => scope.actions.sendToWorker('✍️ $title', context: context);

  /// Walks you to the desk a pull request came from.
  void goToDesk(String deskId) => scope.actions.goToDesk(deskId);

  /// Take the issue's card off the board, to carry to a desk or the queue.
  void pickUp(GhIssue issue) => scope.actions.pickUp(issue);

  /// Put an issue on the 📋 task queue; a worker is seated for it when there's room.
  void queue(String prompt, String title, int issue, {AgentProvider? provider, String? model}) =>
      scope.net.send(QueueAddCmd(prompt: prompt, title: title, issue: issue, provider: provider, model: model));
}

OfficeSocketLike _sock(OfficeScope s) => (send: s.net.send, messages: s.net.messages);

// ---- Merge dialog -------------------------------------------------------------------------------

void _openMerge(OfficeScope scope, GhPull it, GhPullDetail d, VoidCallback handToWorker, VoidCallback onMerged) {
  ModalStack.instance.show((modal) => _MergeDialog(modal: modal, net: _sock(scope), it: it, d: d, handToWorker: handToWorker, onMerged: onMerged));
}

class _MergeDialog extends StatefulWidget {
  const _MergeDialog({required this.modal, required this.net, required this.it, required this.d, required this.handToWorker, required this.onMerged});
  final ModalHandle modal;
  final OfficeSocketLike net;
  final GhPull it;
  final GhPullDetail d;
  final VoidCallback handToWorker;
  final VoidCallback onMerged;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  late final MergeStatus st = mergeStatus(widget.d);
  late GhMergeMethod method;
  late bool deleteBranch;
  late bool auto = st.auto && st.tone != Tone.ok;
  bool busy = false;
  String? error;
  StreamSubscription<ServerMsg>? _sub;

  @override
  void initState() {
    super.initState();
    final p = _mergePref(widget.d.repo.methods);
    method = p.method;
    deleteBranch = p.deleteBranch;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _save() => _savePref(_mergeKey, {'method': method.wire, 'deleteBranch': deleteBranch});

  void _go() {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    _sub = widget.net.messages.listen((m) {
      if (m is! GhMergedMsg || m.number != widget.it.number) return;
      _sub?.cancel();
      busy = false;
      if (m.error != null) {
        if (mounted) setState(() => error = m.error);
        return;
      }
      widget.modal.close();
      widget.onMerged();
    });
    widget.net.send(GhMergeCmd(number: widget.it.number, method: method, deleteBranch: deleteBranch, auto: auto && st.auto));
  }

  void _worker() {
    widget.modal.close();
    widget.handToWorker();
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.it;
    final d = widget.d;
    final conflicts = conflicted(d);
    final methods = d.repo.methods.isEmpty ? GhMergeMethod.values : d.repo.methods;
    // Conflicts can't be merged from here, so fixing them is the main button.
    final worker = conflicts
        ? OfficeButton(
            label: '✨ New worker: fix conflicts & merge',
            kind: BtnKind.primary,
            tooltip: 'A new worker merges the base in, resolves the conflicts, then merges it the way picked above',
            onPressed: _worker,
          )
        : OfficeButton(label: '🤖 Hand to a worker', tooltip: 'A worker fixes whatever is in the way, then merges', onPressed: _worker);
    final go = OfficeButton(
      label: auto ? '⏱ Merge when ready' : '🔀 ${methodLabel[method]}',
      kind: BtnKind.primary,
      onPressed: st.can && !busy ? _go : null,
    );
    return ModalWindow(
      modal: widget.modal,
      width: 580,
      title: Text('🔀 Merge #${it.number}'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _vgap([
          _mergeTitle(it.title, '${it.headRefName} → ${it.baseRefName}'),
          _status(st.icon, st.text, st.tone),
          if (d.checks.isNotEmpty) _checksList(d.checks),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('How', style: heavy(14))),
          _seg(methods, method, (m) => methodLabel[m]!, (m) => setState(() {
                method = m;
                _save();
              })),
          _Check(
            value: deleteBranch,
            label: 'Delete ${it.headRefName} after merging',
            onChanged: (v) => setState(() {
              deleteBranch = v;
              _save();
            }),
          ),
          if (st.auto)
            _Check(
              value: auto,
              label: 'Merge automatically once the requirements pass',
              tooltip: 'gh pr merge --auto (the repo must allow auto-merge)',
              onChanged: (v) => setState(() => auto = v),
            ),
          if (busy || error != null) _result(busy ? (auto && st.auto ? 'Asking GitHub to merge it when ready…' : 'Merging…') : null, error),
        ], 10),
      ),
      footer: Row(
        children: [
          if (!st.can && !conflicts) worker,
          const Spacer(),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          const SizedBox(width: 8),
          conflicts ? worker : go,
        ],
      ),
    );
  }
}

List<Widget> _vgap(List<Widget> ws, double g) => [
      for (var i = 0; i < ws.length; i++) ...[if (i > 0) SizedBox(height: g), ws[i]],
    ];

Widget _mergeTitle(String title, String? refs) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: heavy(16, weight: FontWeight.w900)),
        if (refs != null) Padding(padding: const EdgeInsets.only(top: 2), child: _small(refs)),
      ],
    );

// ---- Close dialog -------------------------------------------------------------------------------

const _reasonLabel = {GhCloseReason.completed: '✅ Completed', GhCloseReason.notPlanned: '🚫 Not planned'};

/// Closes an issue (as completed or not planned) or a PR without merging, with an optional comment.
void _openClose(OfficeScope scope, GhKind kind, int number, String title, GhPull? pull, VoidCallback onClosed) {
  final w = pull == null ? null : workerForPull(scope.store.workers.values, pull);
  ModalStack.instance.show(
    (modal) => _CloseDialog(modal: modal, net: _sock(scope), kind: kind, number: number, title: title, pull: pull, worker: w, onClosed: onClosed),
  );
}

class _CloseDialog extends StatefulWidget {
  const _CloseDialog({
    required this.modal,
    required this.net,
    required this.kind,
    required this.number,
    required this.title,
    required this.pull,
    required this.worker,
    required this.onClosed,
  });
  final ModalHandle modal;
  final OfficeSocketLike net;
  final GhKind kind;
  final int number;
  final String title;
  final GhPull? pull;
  final WorkerInfo? worker;
  final VoidCallback onClosed;

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  GhCloseReason reason = GhCloseReason.completed;
  bool del = false;
  bool busy = false;
  String? error;
  final _comment = TextEditingController();
  StreamSubscription<ServerMsg>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _comment.dispose();
    super.dispose();
  }

  String get noun => widget.pull != null ? 'pull request' : 'issue';

  void _go() {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    _sub = widget.net.messages.listen((m) {
      if (m is! GhClosedMsg || m.kind != widget.kind || m.number != widget.number) return;
      _sub?.cancel();
      busy = false;
      if (m.error != null) {
        if (mounted) setState(() => error = m.error);
        return;
      }
      widget.modal.close();
      widget.onClosed();
    });
    final text = _comment.text.trim();
    widget.net.send(GhCloseCmd(
      kind: widget.kind,
      number: widget.number,
      comment: text.isEmpty ? null : text,
      reason: widget.pull != null ? null : reason,
      deleteBranch: widget.pull != null && del,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pull = widget.pull;
    final w = widget.worker;
    return ModalWindow(
      modal: widget.modal,
      width: 580,
      title: Text('${pull != null ? '🚫' : '✔️'} Close ${pull != null ? 'PR' : 'issue'} #${widget.number}'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _vgap([
          _mergeTitle(widget.title, pull == null ? null : '${pull.headRefName} → ${pull.baseRefName}'),
          if (pull != null)
            _status('ℹ️', "It won't be merged, and can be reopened on GitHub later.${w != null ? ' ${w.name} is still at a desk working on its branch.' : ''}", Tone.muted)
          else
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('Why', style: heavy(14))),
          if (pull != null)
            _Check(value: del, label: 'Delete ${pull.headRefName} too', onChanged: (v) => setState(() => del = v))
          else
            _seg(GhCloseReason.values, reason, (r) => _reasonLabel[r]!, (r) => setState(() => reason = r)),
          Semantics(label: 'Closing comment', child: _textArea(_comment, hint: 'Leave a comment (optional)', autofocus: true)),
          if (busy || error != null) _result(busy ? 'Closing the $noun…' : null, error),
        ], 10),
      ),
      footer: Row(
        children: [
          const Spacer(),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          const SizedBox(width: 8),
          OfficeButton(
            label: pull != null ? '🚫 Close pull request' : '${reason == GhCloseReason.completed ? '✔️' : '🚫'} Close as ${reason.wire}',
            kind: BtnKind.danger,
            onPressed: busy ? null : _go,
          ),
        ],
      ),
    );
  }
}

// ---- Label picker -------------------------------------------------------------------------------

/// Picks an issue's or PR's labels from the repo's own, like GitHub's sidebar: tick them on and off,
/// then save, and the office's gh account adds and takes off the difference.
void openLabels(OfficeScope scope, GhKind kind, int number, String title, String url, List<GhLabel> labels, {ValueChanged<List<GhLabel>>? onSaved}) {
  ModalStack.instance.show(
    (modal) => _LabelDialog(
      modal: modal,
      net: _sock(scope),
      store: scope.store,
      kind: kind,
      number: number,
      title: title,
      url: url,
      labels: labels,
      onSaved: onSaved,
    ),
  );
}

/// The repo's labels (GET /api/gh/labels), a list the server answers with.
Future<List<GhLabel>> _repoLabels(Store store) async {
  final j = jsonDecode(await GhApi.getText(onFloor(store, '/api/gh/labels')));
  if (j is! List) throw GhApiError('No labels came back');
  return [for (final l in j) if (l is Map<String, dynamic>) GhLabel.fromJson(l)];
}

class _LabelDialog extends StatefulWidget {
  const _LabelDialog({
    required this.modal,
    required this.net,
    required this.store,
    required this.kind,
    required this.number,
    required this.title,
    required this.url,
    required this.labels,
    this.onSaved,
  });
  final ModalHandle modal;
  final OfficeSocketLike net;
  final Store store;
  final GhKind kind;
  final int number;
  final String title;
  final String url;
  final List<GhLabel> labels;
  final ValueChanged<List<GhLabel>>? onSaved;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  late final Set<String> had = widget.labels.map((l) => l.name).toSet();
  late final Set<String> on = {...had};
  List<GhLabel>? repo;
  String error = '';
  bool busy = false;
  String? result;
  List<GhLabel> rows = const [];
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  StreamSubscription<ServerMsg>? _sub;
  Timer? _timer;

  String get noun => widget.kind == GhKind.pull ? 'PR' : 'issue';

  @override
  void initState() {
    super.initState();
    _load();
    _filterFocus.requestFocus();
  }

  @override
  void dispose() {
    _settle();
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      error = '';
      repo = null;
      rows = labelRows(widget.labels, null);
    });
    _repoLabels(widget.store).then((l) {
      if (mounted) setState(() => rows = labelRows(widget.labels, repo = l));
    }).catchError((Object err) {
      if (mounted) setState(() => error = '$err');
    });
  }

  void _settle() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    busy = false;
  }

  void _submit() {
    final c = labelChanges(had, on);
    if (busy || (c.add.isEmpty && c.remove.isEmpty)) return;
    setState(() {
      busy = true;
      result = null;
    });
    _sub = widget.net.messages.listen((m) {
      if (m is! GhLabeledMsg || m.kind != widget.kind || m.number != widget.number) return;
      _settle();
      final labels = m.labels;
      if (labels == null) {
        if (mounted) setState(() => result = m.error ?? 'GitHub did not take the labels');
        return;
      }
      widget.modal.close();
      widget.onSaved?.call(labels);
    });
    // The office drops messages while it's disconnected, and then no answer comes.
    _timer = Timer(const Duration(seconds: 45), () {
      _settle();
      if (mounted) setState(() => result = 'No answer from the office. Look at the board to see whether the labels changed before saving again.');
    });
    widget.net.send(GhLabelsCmd(kind: widget.kind, number: widget.number, add: c.add, remove: c.remove));
  }

  void _toggle(String name) {
    if (busy) return;
    setState(() => on.contains(name) ? on.remove(name) : on.add(name));
  }

  @override
  Widget build(BuildContext context) {
    final c = labelChanges(had, on);
    final shown = rows.where((l) => labelMatches(l, _filter.text)).toList();
    final q = _filter.text.trim();
    final manage = '${repoUrlOf(widget.url)}/labels';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
      },
      child: ModalWindow(
        modal: widget.modal,
        width: 580,
        title: Text('🏷️ Labels on $noun #${widget.number}'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _vgap([
            _mergeTitle(widget.title, null),
            Semantics(
              label: 'Filter labels',
              child: BoxInput(
                controller: _filter,
                focusNode: _filterFocus,
                hint: 'Filter labels…',
                onChanged: (_) => setState(() {}),
                // Enter in the filter ticks (or unticks) the first label it shows.
                onSubmitted: (_) {
                  if (shown.isNotEmpty) _toggle(shown.first.name);
                  _filterFocus.requestFocus();
                },
              ),
            ),
            Container(
              constraints: BoxConstraints(maxHeight: math.min(420, MediaQuery.sizeOf(context).height * 0.5)),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Swatch.ink, width: 3)),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in shown) _LabelRow(label: l, on: on.contains(l.name), enabled: !busy, onTap: () => _toggle(l.name)),
                  if (error.isNotEmpty)
                    _errorBox(error, _load)
                  else if (repo == null)
                    _spinnerRow("Loading the repo's labels…")
                  else if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          Text(q.isNotEmpty ? 'No labels match “$q”. ' : 'This repository has no labels yet. ', style: heavy(14, color: Swatch.muted, weight: FontWeight.w700)),
                          _Link('Make one on GitHub ↗', manage, style: heavy(14, color: _blueLink)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (busy || result != null) _result(busy ? 'Saving the labels on GitHub…' : null, result),
          ], 10),
        ),
        footer: Row(
          children: [
            Expanded(
              child: Text(labelSummary(had, on), maxLines: 1, overflow: TextOverflow.ellipsis, style: heavy(13, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
            const SizedBox(width: 8),
            OfficeButton(
              label: busy ? 'Saving…' : '🏷️ Save labels',
              kind: BtnKind.primary,
              onPressed: busy || (c.add.isEmpty && c.remove.isEmpty) ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// A label in the picker: a tick box, its chip, and its description under it.
class _LabelRow extends StatelessWidget {
  const _LabelRow({required this.label, required this.on, required this.enabled, required this.onTap});
  final GhLabel label;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = label.description;
    return Semantics(
      checked: on,
      enabled: enabled,
      label: label.name,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: Swatch.paper2,
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [_TickBox(on, color: Swatch.accent), const SizedBox(width: 8), Flexible(child: _BigLabel(label))]),
              if (d != null && d.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 3),
                  child: Text(d, style: heavy(12, color: Swatch.muted, weight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label chip at the picker's size (12px).
class _BigLabel extends StatelessWidget {
  const _BigLabel(this.label);
  final GhLabel label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(color: parseHex(label.color), borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 1.5)),
        child: Text(label.name, style: heavy(12, color: labelIsDark(label.color) ? Colors.white : Swatch.ink)),
      );
}

/// The button after an issue's or PR's labels that opens the label picker.
class _LabelButton extends StatelessWidget {
  const _LabelButton({required this.has, required this.onPressed});
  final bool has;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Change the labels',
        child: OfficeButton(label: has ? '🏷️ Edit' : '🏷️ Add labels', dense: true, tooltip: 'Change the labels', onPressed: onPressed),
      );
}

// ---- The PR window ------------------------------------------------------------------------------

/// Opens a pull request's window, on the tab you used last.
ModalHandle openPull(OfficeScope scope, GhPull first) =>
    ModalStack.instance.show((modal) => _PullWindow(modal: modal, scope: scope, first: first))..doing = '🔀 reading PR #${first.number}';

class _Section {
  _Section({required this.big});
  final bool big;
  final GlobalKey groupKey = GlobalKey();
  final Map<String, GlobalKey<FlashRowState>> rowKeys = {};
  Widget? body;
}

class _PullWindow extends StatefulWidget {
  const _PullWindow({required this.modal, required this.scope, required this.first});
  final ModalHandle modal;
  final OfficeScope scope;
  final GhPull first;

  @override
  State<_PullWindow> createState() => _PullWindowState();
}

enum _Tab { conversation, files }

class _PullWindowState extends State<_PullWindow> {
  late GhPull it = widget.first;
  late final String itemUrl = it.url;
  late final Reviewed reviewed = Reviewed(it.url, _reviewStore);
  late final BoardActions actions = BoardActions(widget.scope);
  GhPullDetail? detail;
  String detailError = '';
  List<DiffFile>? files;
  String diffError = '';
  _Tab tab = _pref(_tabKey) == 'files' ? _Tab.files : _Tab.conversation;
  bool treeMode = _pref(_filesKey) != 'list';
  String filter = '';
  String current = '';
  final Set<String> collapsedDirs = {};

  /// Files you opened or closed yourself; the rest follow the defaults (reviewed ones closed).
  final Map<String, bool> open = {};
  final Map<String, _Section> sections = {};

  /// The files in the order the sidebar lists them, after the filter.
  List<DiffFile> order = [];
  final _main = ScrollController();
  final _filterCtl = TextEditingController();
  final _focus = FocusNode();
  int _generation = 0;
  late final Store store = widget.scope.store;

  @override
  void initState() {
    super.initState();
    store.topic(Topic.pulls).addListener(_onPulls);
    store.topic(Topic.workers).addListener(_onWorkers);
    _main.addListener(_spy);
    _loadAll();
  }

  @override
  void dispose() {
    store.topic(Topic.pulls).removeListener(_onPulls);
    store.topic(Topic.workers).removeListener(_onWorkers);
    _main.dispose();
    _filterCtl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onWorkers() => setState(() {});

  void _onPulls() {
    final fresh = store.pulls.items.where((p) => p.number == it.number).firstOrNull;
    if (fresh == null) return;
    final d = detail;
    setState(() => it = d != null ? _withState(fresh, fresh.state == 'OPEN' ? d.state : fresh.state) : fresh);
  }

  static GhPull _withLabels(GhPull p, List<GhLabel> labels) => GhPull.fromJson({...p.toJson(), 'labels': [for (final l in labels) l.toJson()]});

  static GhPull _withState(GhPull p, String state, {bool? isDraft, String? reviewDecision}) => GhPull(
        number: p.number,
        title: p.title,
        state: state,
        isDraft: isDraft ?? p.isDraft,
        url: p.url,
        author: p.author,
        labels: p.labels,
        reviewDecision: reviewDecision ?? p.reviewDecision,
        headRefName: p.headRefName,
        baseRefName: p.baseRefName,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        additions: p.additions,
        deletions: p.deletions,
        checks: p.checks,
        body: p.body,
        closes: p.closes,
      );

  // --- Loading
  void _loadAll() {
    final g = ++_generation;
    setState(() {
      detailError = '';
      diffError = '';
    });
    GhApi.getJson(onFloor(store, '/api/gh/pull?number=${it.number}')).then((j) {
      if (g != _generation || !mounted) return;
      final d = GhPullDetail.fromJson(j);
      setState(() {
        detail = d;
        it = _withState(it, d.state, isDraft: d.isDraft, reviewDecision: d.reviewDecision);
        // Line comments go into the diff, so draw it again with them.
        if (files != null) _setupFiles();
      });
    }).catchError((Object err) {
      if (g == _generation && mounted) setState(() => detailError = '$err');
    });
    GhApi.getText(onFloor(store, '/api/gh/pull/diff?number=${it.number}')).then((text) {
      if (g != _generation || !mounted) return;
      setState(() {
        files = parseDiff(text);
        _setupFiles();
      });
    }).catchError((Object err) {
      if (g == _generation && mounted) setState(() => diffError = '$err');
    });
  }

  void _reload() {
    widget.scope.net.send(const GhRefreshCmd());
    _loadAll();
  }

  void _handToWorker() {
    final d = detail;
    final p = _mergePref(d?.repo.methods ?? GhMergeMethod.values);
    if (d != null && conflicted(d)) {
      actions.assign(fixConflictsPrompt(it, p.method, p.deleteBranch), 'Fix conflicts & merge PR #${it.number}');
    } else {
      actions.assign(fixAndMergePrompt(it, p.method, p.deleteBranch), 'Fix up & merge PR #${it.number}');
    }
  }

  void _merge() {
    final d = detail;
    if (d != null) _openMerge(widget.scope, it, d, _handToWorker, _loadAll);
  }

  void _setTab(_Tab t) {
    setState(() => tab = t);
    _savePref(_tabKey, t.name);
    _focus.requestFocus();
  }

  // --- Files
  List<DiffFile> _shown() {
    final fs = files;
    if (fs == null) return [];
    final q = filter.trim().toLowerCase();
    final list = treeMode ? treeOrder(buildTree(fs)) : fs;
    return q.isEmpty ? list : list.where((f) => f.path.toLowerCase().contains(q)).toList();
  }

  bool _isOpenFile(DiffFile f) => open[f.path] ?? reviewed.mark(f) != ReviewMark.reviewed;

  int _countComments(String p) => detail?.reviewComments.where((c) => c.path == p && c.replyTo == null).length ?? 0;

  void _setupFiles() {
    sections.clear();
    final fs = files;
    if (fs == null) return;
    var budget = 0;
    for (final f in fs) {
      // Big files and lock files wait for a click, so a huge PR doesn't lock up the window.
      final big = looksGenerated(f.path) || f.lines.length > 800 || budget > 6000;
      if (!big) budget += f.lines.length;
      sections[f.path] = _Section(big: big);
    }
    order = _shown();
    if (current.isEmpty && order.isNotEmpty) current = order.first.path;
  }

  Widget _bodyOf(DiffFile f) {
    final s = sections[f.path]!;
    return s.body ??= FileDiffLines(file: f, comments: detail?.reviewComments ?? const [], itemUrl: itemUrl, rowKeys: s.rowKeys);
  }

  double? _offsetOf(String p) {
    final ro = sections[p]?.groupKey.currentContext?.findRenderObject();
    return ro is RenderSliver ? ro.constraints.precedingScrollExtent : null;
  }

  void _jump(double off) {
    if (!_main.hasClients) return;
    _main.jumpTo(off.clamp(0, _main.position.maxScrollExtent));
  }

  void _spy() {
    final top = _main.offset + 12;
    var at = '';
    for (final f in order) {
      final off = _offsetOf(f.path);
      if (off == null || off > top) break;
      at = f.path;
    }
    if (at.isNotEmpty && at != current) setState(() => current = at);
  }

  void _after(VoidCallback fn) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fn();
      });

  void _scrollToFile(String p, {bool reveal = false}) {
    final f = files?.where((x) => x.path == p).firstOrNull;
    if (f == null) return;
    setState(() {
      if (reveal && !_isOpenFile(f)) open[p] = true;
      current = p;
    });
    _after(() {
      final off = _offsetOf(p);
      if (off != null) _jump(off);
      // Opening a file moves the ones after it: set current again after the jump's spy.
      if (current != p) setState(() => current = p);
    });
  }

  void _revealLine(String p, GhReviewSide side, int? line) {
    final f = files?.where((x) => x.path == p).firstOrNull;
    final s = sections[p];
    if (f == null || s == null) return;
    setState(() {
      open[p] = true;
      current = p;
    });
    _after(() {
      final row = s.rowKeys['${side.wire}:$line'];
      final ro = row?.currentContext?.findRenderObject();
      if (ro == null || !_main.hasClients) return _scrollToFile(p);
      final off = RenderAbstractViewport.of(ro).getOffsetToReveal(ro, 0).offset;
      _jump(off - _main.position.viewportDimension / 3);
      row!.currentState?.flash();
      _after(() => setState(() => current = p));
    });
  }

  void _setReviewed(DiffFile f, bool on, {bool advance = false}) {
    reviewed.set(f, on);
    setState(() => open.remove(f.path));
    // Closing a file you were reading: keep its header in view instead of jumping past the next one.
    final off = _offsetOf(f.path);
    if (on && off != null && _main.hasClients && off < _main.offset) _after(() => _jump(off));
    if (on && advance) {
      final i = order.indexOf(f);
      final next = order.skip(i + 1).where((x) => reviewed.mark(x) != ReviewMark.reviewed).firstOrNull;
      if (next != null) _scrollToFile(next.path);
    }
  }

  void _step(int dir) {
    if (order.isEmpty) return;
    final i = order.indexWhere((f) => f.path == current);
    final next = order[(i + dir).clamp(0, order.length - 1)];
    _scrollToFile(next.path, reveal: true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || tab != _Tab.files) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    if (hw.isMetaPressed || hw.isControlPressed || hw.isAltPressed) return KeyEventResult.ignored;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null)) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyJ || k == LogicalKeyboardKey.keyN) {
      _step(1);
    } else if (k == LogicalKeyboardKey.keyK || k == LogicalKeyboardKey.keyP) {
      _step(-1);
    } else if (k == LogicalKeyboardKey.keyV) {
      final f = files?.where((x) => x.path == current).firstOrNull;
      if (f != null) _setReviewed(f, reviewed.mark(f) != ReviewMark.reviewed, advance: true);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Frame
  @override
  Widget build(BuildContext context) {
    final (word, cls) = stateOf(it.state, isDraft: it.isDraft);
    final h = MediaQuery.sizeOf(context).height;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ModalWindow(
        modal: widget.modal,
        width: 1400,
        height: (h - 32).clamp(0, 920),
        scrollBody: false,
        bodyPadding: EdgeInsets.zero,
        title: _title(_pill(word, cls), '#${it.number} ${it.title}'),
        headerExtras: [OfficeButton(label: '🔄', tooltip: 'Reload from GitHub', dense: true, onPressed: _reload)],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _meta(),
            _tabs(),
            Expanded(
              child: IndexedStack(
                index: tab.index,
                sizing: StackFit.expand,
                children: [_conversation(), _filesPane()],
              ),
            ),
          ],
        ),
        footer: _footer(),
      ),
    );
  }

  Widget _meta() {
    final d = detail;
    final commits = d != null ? '${d.commits} commit${d.commits == 1 ? '' : 's'}' : 'its commits';
    final muted = heavy(13, color: Swatch.muted, weight: FontWeight.w700);
    final badge = it.reviewDecision.isEmpty
        ? null
        : _Badge(
            it.reviewDecision == 'REVIEW_REQUIRED' ? 'review required' : (reviewBadge[it.reviewDecision]?.$1 ?? it.reviewDecision.toLowerCase()),
            reviewBadge[it.reviewDecision]?.$2 ?? '',
          );
    return _MetaBar(children: [
      GhAvatar(it.author),
      Text(it.author, style: heavy(13, weight: FontWeight.w900)),
      Text(it.state == 'MERGED' ? 'merged $commits into' : 'wants to merge $commits into', style: muted),
      _code(it.baseRefName),
      Text('from', style: muted),
      _code(it.headRefName),
      _plusMinus(it.additions, it.deletions),
      ...it.labels.map(LabelChip.new),
      _LabelButton(
        has: it.labels.isNotEmpty,
        onPressed: () => openLabels(widget.scope, GhKind.pull, it.number, it.title, it.url, it.labels,
            onSaved: (labels) => mounted ? setState(() => it = _withLabels(it, labels)) : null),
      ),
      ?badge,
    ]);
  }

  Widget _tabs() {
    final d = detail;
    final fs = files;
    final done = fs == null ? 0 : fs.where((f) => reviewed.mark(f) == ReviewMark.reviewed).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: Swatch.paper, border: Border(bottom: BorderSide(color: Swatch.ink, width: 3))),
      child: Row(
        children: [
          _TabButton(
            on: tab == _Tab.conversation,
            onTap: () => _setTab(_Tab.conversation),
            children: [
              const Text('💬 Conversation'),
              if (d != null) _Count(d.comments.length + d.reviews.length + d.reviewComments.where((c) => c.replyTo == null).length),
            ],
          ),
          const SizedBox(width: 4),
          _TabButton(
            on: tab == _Tab.files,
            onTap: () => _setTab(_Tab.files),
            children: [
              const Text('📄 Files changed'),
              if (fs != null) _Count(fs.length),
              if (fs != null && fs.isNotEmpty)
                Text('✓ $done/${fs.length}', style: heavy(11, color: done == fs.length ? _addFg : Swatch.muted, weight: FontWeight.w900)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final d = detail;
    final isOpen = it.state == 'OPEN';
    final conflicts = d != null && conflicted(d);
    final w = workerForPull(store.workers.values, it);
    return Row(
      children: [
        Expanded(child: Align(alignment: Alignment.centerLeft, child: _Link('Open on GitHub ↗', it.url, style: heavy(14, color: _blueLink)))),
        Flexible(
          flex: 4,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (w != null) OfficeButton(label: "🪑 Go to ${w.name}'s desk", onPressed: () => actions.goToDesk(w.deskId)),
              OfficeButton(
                label: '✍️ Ask a worker…',
                tooltip: 'Send a worker your own prompt about this PR',
                onPressed: () => actions.ask(pullContext(it), 'Ask about PR #${it.number}'),
              ),
              if (isOpen) OfficeButton(label: '🔍 Review', onPressed: () => actions.assign(reviewPrompt(it), 'Review PR #${it.number}')),
              if (conflicts)
                OfficeButton(
                  label: '✨ Fix conflicts & merge',
                  kind: BtnKind.primary,
                  tooltip: 'A new worker merges the base in, resolves the conflicts, gets the checks green, then merges',
                  onPressed: _handToWorker,
                )
              else if (isOpen)
                OfficeButton(
                  label: '🤖 Fix comments & merge',
                  tooltip: 'A worker addresses the review comments, gets the checks green, then merges',
                  onPressed: _handToWorker,
                ),
              if (isOpen)
                OfficeButton(
                  label: '🚫 Close PR…',
                  tooltip: 'Close this pull request without merging it',
                  onPressed: () => _openClose(widget.scope, GhKind.pull, it.number, it.title, it, _loadAll),
                ),
              if (isOpen)
                OfficeButton(
                  label: '🔀 Merge…',
                  kind: conflicts ? BtnKind.plain : BtnKind.primary,
                  tooltip: d != null ? 'Merge this pull request' : 'Loading…',
                  onPressed: d != null ? _merge : null,
                ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Conversation
  void _showInDiff(GhReviewComment c) {
    _setTab(_Tab.files);
    _after(() => _revealLine(c.path, c.side, c.line));
  }

  Widget _conversation() {
    final d = detail;
    final items = <Widget>[
      _commentCard(GhComment(id: 'body', author: it.author, body: d?.body ?? it.body, createdAt: it.createdAt, url: it.url), itemUrl, 'opened this'),
    ];
    if (detailError.isNotEmpty) {
      items.add(_errorBox(detailError, _loadAll));
    } else if (d == null) {
      items.add(_spinnerRow('Loading the conversation…'));
    } else {
      final replies = repliesOf(d.reviewComments);
      final timeline = <(String, Widget)>[
        for (final c in d.comments) (c.createdAt, _commentCard(c, itemUrl, 'commented')),
        for (final r in d.reviews) (r.createdAt, _commentCard(r, itemUrl, '', reviewBadge[r.state ?? ''] ?? (r.state?.toLowerCase() ?? 'reviewed', ''))),
        for (final c in d.reviewComments.where((c) => c.replyTo == null))
          (
            c.createdAt,
            _GhCard(
              header: [
                const Text('💬'),
                Flexible(child: Tooltip(message: c.path, child: Text('${c.path}${c.line != null ? ':${c.line}' : ''}', overflow: TextOverflow.ellipsis, style: mono(12)))),
                if (c.line == null) const _Badge('outdated', 'muted'),
                const Spacer(),
                if (c.line != null) OfficeButton(label: 'Show in diff', dense: true, onPressed: () => _showInDiff(c)),
              ],
              child: ReviewThread(root: c, replies: replies, itemUrl: itemUrl, inCard: true),
            ),
          ),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      items.addAll(timeline.map((x) => x.$2));
      if (timeline.isEmpty) items.add(_quiet('No comments or reviews yet.'));
      items.add(_mergeBox(d));
    }
    return ColoredBox(
      color: _ghBg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The comment box stays put while the conversation above it is redrawn, so a load
                // finishing doesn't take the focus (or the text) away from someone typing.
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _vgap(items, 14)),
                const SizedBox(height: 14),
                _CommentBox(
                  kind: GhKind.pull,
                  number: it.number,
                  itemUrl: itemUrl,
                  net: _sock(widget.scope),
                  viewer: d?.viewer ?? '',
                  onPosted: (c) {
                    if (detail == null) return _loadAll();
                    setState(() => detail!.comments.add(c));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mergeBox(GhPullDetail d) {
    final st = mergeStatus(d);
    Widget go(Widget b) => Align(alignment: Alignment.centerRight, child: b);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink, width: 2),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _vgap([
          _status(st.icon, st.text, st.tone),
          if (d.checks.isNotEmpty) _checksList(d.checks),
          if (it.state == 'OPEN' && st.can) go(OfficeButton(label: '🔀 Merge…', kind: BtnKind.primary, onPressed: _merge)),
          if (conflicted(d))
            go(OfficeButton(label: '✨ New worker: fix conflicts & merge', kind: BtnKind.primary, onPressed: _handToWorker))
          else if (it.state == 'OPEN' && !st.can && !d.isDraft)
            go(OfficeButton(label: '🤖 Have a worker fix it & merge', onPressed: _handToWorker)),
        ], 10),
      ),
    );
  }

  // --- Files pane
  Widget _filesPane() {
    if (diffError.isNotEmpty) return Center(child: _errorBox(diffError, _loadAll));
    final fs = files;
    if (fs == null) return Center(child: _spinnerRow('Loading the diff…'));
    order = _shown();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 310, child: _side(fs)),
        const ColoredBox(color: Swatch.ink, child: SizedBox(width: 3)),
        Expanded(child: _mainPane()),
      ],
    );
  }

  Widget _side(List<DiffFile> fs) {
    final done = fs.where((f) => reviewed.mark(f) == ReviewMark.reviewed).length;
    final rows = <Widget>[];
    if (treeMode) {
      _dirRows(buildTree(fs), 0, order.toSet(), rows);
    } else {
      rows.addAll(order.map((f) => _fileRow(f, 0)));
    }
    return Container(
      color: Swatch.paper2,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _modeBtn(true, '🌲 Tree')),
              const SizedBox(width: 6),
              Expanded(child: _modeBtn(false, '☰ List')),
            ],
          ),
          const SizedBox(height: 6),
          _ProgressBar(fs.isEmpty ? 0 : done / fs.length),
          const SizedBox(height: 6),
          Text('$done of ${fs.length} file${fs.length == 1 ? '' : 's'} reviewed', style: heavy(12, color: Swatch.muted)),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: TextField(
              controller: _filterCtl,
              onChanged: (v) => setState(() => filter = v),
              style: heavy(13, weight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Filter files…',
                contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Swatch.ink, width: 2)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Swatch.accent, width: 2)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? Padding(padding: const EdgeInsets.all(6), child: Text(filter.isNotEmpty ? 'No files match.' : 'No files changed.', textAlign: TextAlign.center, style: heavy(13, color: Swatch.muted, weight: FontWeight.w700)))
                : ListView(children: rows),
          ),
          const SizedBox(height: 8),
          const _KeysHint(),
        ],
      ),
    );
  }

  Widget _modeBtn(bool tree, String label) => OfficeButton(
        label: label,
        dense: true,
        kind: treeMode == tree ? BtnKind.on : BtnKind.plain,
        onPressed: () {
          setState(() => treeMode = tree);
          _savePref(_filesKey, tree ? 'tree' : 'list');
        },
      );

  void _dirRows(TreeDir d, int depth, Set<DiffFile> visible, List<Widget> out) {
    for (final sub in d.dirs) {
      final inside = treeOrder(sub).where(visible.contains).toList();
      if (inside.isEmpty) continue;
      final shut = collapsedDirs.contains(sub.path) && filter.isEmpty;
      final all = inside.every((f) => reviewed.mark(f) == ReviewMark.reviewed);
      out.add(_TreeRow(
        depth: depth,
        tooltip: sub.path,
        onTap: () => setState(() => collapsedDirs.contains(sub.path) ? collapsedDirs.remove(sub.path) : collapsedDirs.add(sub.path)),
        children: [
          SizedBox(width: 12, child: Text(shut ? '▸' : '▾', style: heavy(11, color: Swatch.muted))),
          const Text('📁'),
          Expanded(child: Text(sub.name, overflow: TextOverflow.ellipsis, style: heavy(13, weight: FontWeight.w700))),
          if (all) Tooltip(message: 'Everything in here is reviewed', child: const Icon(Icons.check, size: 15, color: _addFg)),
        ],
      ));
      if (!shut) _dirRows(sub, depth + 1, visible, out);
    }
    for (final f in d.files) {
      if (visible.contains(f)) out.add(_fileRow(f, depth));
    }
  }

  Widget _fileRow(DiffFile f, int depth) {
    final slash = f.path.lastIndexOf('/');
    final n = _countComments(f.path);
    final mark = reviewed.mark(f);
    // The name first and its folder after, so a narrow sidebar cuts the folder, not the name.
    return _TreeRow(
      depth: depth,
      on: current == f.path,
      tooltip: f.path,
      onTap: () => _scrollToFile(f.path, reveal: true),
      children: [
        _ReviewTick(mark: mark, onTap: () => _setReviewed(f, mark != ReviewMark.reviewed)),
        _StatusBox(f.status),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: f.path.substring(slash + 1), style: heavy(13, color: mark == ReviewMark.reviewed ? Swatch.muted : Swatch.ink, weight: FontWeight.w700)),
              if (!treeMode && slash >= 0) TextSpan(text: ' ${f.path.substring(0, slash)}', style: heavy(13, color: Swatch.muted, weight: FontWeight.w600)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (n > 0) Tooltip(message: '$n comment${n > 1 ? 's' : ''}', child: Text('💬$n', style: heavy(11))),
        _plusMinus(f.additions, f.deletions, binary: f.binary),
      ],
    );
  }

  Widget _mainPane() {
    final slivers = <Widget>[];
    for (final f in order) {
      slivers.add(SliverPadding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), sliver: _fileSliver(f)));
    }
    if (order.isEmpty) slivers.add(const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: 12), child: DiffNote('No files match the filter.'))));
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    return ColoredBox(
      color: const Color(0xFFEFE6DA),
      child: SelectionArea(child: CustomScrollView(controller: _main, slivers: slivers)),
    );
  }

  Widget _fileSliver(DiffFile f) {
    final s = sections[f.path]!;
    final isOpen = _isOpenFile(f);
    final mark = reviewed.mark(f);
    Widget? body;
    if (isOpen) {
      body = s.big && open[f.path] != true && s.body == null
          ? DiffNote(
              looksGenerated(f.path) ? 'Generated or lock file — not shown by default.' : 'Large diff (${f.lines.length} lines) — not shown by default.',
              action: OfficeButton(label: 'Show diff', dense: true, onPressed: () => setState(() => open[f.path] = true)),
            )
          : _bodyOf(f);
    }
    return DecoratedSliver(
      key: s.groupKey,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Swatch.ink, width: 2),
        boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
      ),
      sliver: SliverMainAxisGroup(
        slivers: [
          PinnedHeaderSliver(child: _fileHeader(f, isOpen, mark)),
          if (body != null)
            SliverToBoxAdapter(
              child: ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)), child: body),
            ),
        ],
      ),
    );
  }

  Widget _fileHeader(DiffFile f, bool isOpen, ReviewMark mark) {
    final n = _countComments(f.path);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: const Radius.circular(10), bottom: Radius.circular(isOpen ? 0 : 10)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: mark == ReviewMark.reviewed ? const Color(0xFFD8F5E3) : Swatch.paper2,
          border: isOpen ? const Border(bottom: BorderSide(color: Swatch.ink, width: 2)) : null,
        ),
        child: Row(
          children: _gap([
            Semantics(
              label: 'Show or hide this file',
              button: true,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => open[f.path] = !_isOpenFile(f)),
                  child: SizedBox(width: 22, height: 22, child: Center(child: Text(isOpen ? '▾' : '▸', style: heavy(12)))),
                ),
              ),
            ),
            _StatusBox(f.status),
            Expanded(
              child: Tooltip(
                message: f.path,
                child: Text(
                  f.status == FileStatus.R && f.oldPath != null ? '${f.oldPath} → ${f.path}' : f.path,
                  overflow: TextOverflow.ellipsis,
                  style: mono(12.5, weight: FontWeight.w700),
                ),
              ),
            ),
            _plusMinus(f.additions, f.deletions, binary: f.binary, binWord: 'binary'),
            if (n > 0) Text('💬 $n', style: heavy(11)),
            if (mark == ReviewMark.stale)
              Tooltip(
                message: 'The file changed after you marked it reviewed',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(color: Swatch.warn, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
                  child: Text('changed since review', style: heavy(11)),
                ),
              ),
            Tooltip(
              message: 'Mark as reviewed (V)',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _setReviewed(f, mark != ReviewMark.reviewed),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                    decoration: BoxDecoration(
                      color: mark == ReviewMark.reviewed ? Swatch.good : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Swatch.ink, width: 2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TickBox(mark == ReviewMark.reviewed, color: _addFg),
                        const SizedBox(width: 6),
                        Text('Reviewed', style: heavy(12.5, color: mark == ReviewMark.reviewed ? Colors.white : Swatch.ink)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ], 8),
        ),
      ),
    );
  }
}

class _MetaBar extends StatelessWidget {
  const _MetaBar({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x262B2D42), width: 2))),
        child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: children),
      );
}

class _TabButton extends StatefulWidget {
  const _TabButton({required this.on, required this.onTap, required this.children});
  final bool on;
  final VoidCallback onTap;
  final List<Widget> children;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: widget.on,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => hover = true),
          onExit: (_) => setState(() => hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Transform.translate(
              offset: const Offset(0, 3),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: widget.on ? Swatch.accent : Colors.transparent, width: 4))),
                child: DefaultTextStyle(
                  style: heavy(14, color: widget.on || hover ? Swatch.ink : Swatch.muted),
                  child: Row(mainAxisSize: MainAxisSize.min, children: _gap(widget.children, 6)),
                ),
              ),
            ),
          ),
        ),
      );
}

class _Count extends StatelessWidget {
  const _Count(this.n);
  final int n;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(color: Swatch.paper2, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
        child: Text('$n', style: heavy(11)),
      );
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar(this.value);
  final double value;

  @override
  Widget build(BuildContext context) => Container(
        height: 10,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: Swatch.ink, width: 2)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 250),
            widthFactor: value.clamp(0, 1),
            heightFactor: 1,
            child: const ColoredBox(color: Swatch.good),
          ),
        ),
      );
}

class _KeysHint extends StatelessWidget {
  const _KeysHint();

  Widget _key(String k) => Container(
        margin: const EdgeInsets.only(right: 3),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        constraints: const BoxConstraints(minWidth: 18),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(7), border: Border.all(color: Swatch.ink, width: 1.5)),
        child: Text(k, textAlign: TextAlign.center, style: heavy(11, weight: FontWeight.w900)),
      );

  @override
  Widget build(BuildContext context) {
    final s = heavy(11, color: Swatch.muted, weight: FontWeight.w700);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [_key('J'), _key('K'), Text('next / previous file · ', style: s), _key('V'), Text('reviewed', style: s)],
    );
  }
}

class _TreeRow extends StatefulWidget {
  const _TreeRow({required this.depth, required this.children, required this.onTap, this.on = false, this.tooltip});
  final int depth;
  final List<Widget> children;
  final VoidCallback onTap;
  final bool on;
  final String? tooltip;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    Widget w = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 1),
          padding: EdgeInsets.fromLTRB(6 + widget.depth * 14.0, 3, 6, 3),
          decoration: BoxDecoration(
            color: widget.on ? Colors.white : (hover ? const Color(0xBFFFFFFF) : null),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: widget.on ? Swatch.ink : Colors.transparent, width: 2),
          ),
          child: Row(children: _gap(widget.children, 6)),
        ),
      ),
    );
    if (widget.tooltip != null) w = Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 600), child: w);
    return w;
  }
}

class _ReviewTick extends StatelessWidget {
  const _ReviewTick({required this.mark, required this.onTap});
  final ReviewMark mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: switch (mark) {
          ReviewMark.reviewed => 'Reviewed — click to unmark',
          ReviewMark.stale => 'Changed since you reviewed it',
          ReviewMark.none => 'Mark as reviewed',
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (mark) { ReviewMark.reviewed => Swatch.good, ReviewMark.stale => Swatch.warn, ReviewMark.none => Colors.white },
                border: Border.all(color: Swatch.ink, width: 2),
              ),
              child: switch (mark) {
                ReviewMark.reviewed => const Icon(Icons.check, size: 12, color: Colors.white),
                ReviewMark.stale => Text('!', style: heavy(11, weight: FontWeight.w900).copyWith(height: 1)),
                ReviewMark.none => null,
              },
            ),
          ),
        ),
      );
}

class _StatusBox extends StatelessWidget {
  const _StatusBox(this.status);
  final FileStatus status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      FileStatus.M => (Swatch.warn, Swatch.ink),
      FileStatus.A => (Swatch.good, Colors.white),
      FileStatus.D => (Swatch.bad, Colors.white),
      FileStatus.R => (Swatch.info, Swatch.ink),
    };
    return Tooltip(
      message: statusWord[status]!,
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5), border: Border.all(color: Swatch.ink, width: 2)),
        child: Text(status.name, style: mono(10, color: fg, weight: FontWeight.w900, height: 1)),
      ),
    );
  }
}

// ---- The issue window -----------------------------------------------------------------------------

ModalHandle openIssue(OfficeScope scope, GhIssue first) =>
    ModalStack.instance.show((modal) => _IssueWindow(modal: modal, scope: scope, first: first))..doing = '📋 reading issue #${first.number}';

class _IssueWindow extends StatefulWidget {
  const _IssueWindow({required this.modal, required this.scope, required this.first});
  final ModalHandle modal;
  final OfficeScope scope;
  final GhIssue first;

  @override
  State<_IssueWindow> createState() => _IssueWindowState();
}

class _IssueWindowState extends State<_IssueWindow> {
  late GhIssue it = widget.first;
  late final String itemUrl = it.url;
  late final Store store = widget.scope.store;
  late final BoardActions actions = BoardActions(widget.scope);
  late final _ProviderPicker provider = _ProviderPicker(store.project, 'Queue provider');
  GhIssueDetail? detail;
  String error = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    store.topic(Topic.issues).addListener(_onIssues);
    store.topic(Topic.queue).addListener(_onQueue);
    provider.addListener(_onQueue);
    _load();
  }

  @override
  void dispose() {
    store.topic(Topic.issues).removeListener(_onIssues);
    store.topic(Topic.queue).removeListener(_onQueue);
    provider.dispose();
    super.dispose();
  }

  void _onQueue() => setState(() {});

  void _onIssues() {
    final fresh = store.issues.items.where((i) => i.number == it.number).firstOrNull;
    if (fresh == null) return;
    // The board can lag behind a close made from here.
    final d = detail;
    setState(() => it = d != null ? _issueWithState(fresh, fresh.state == 'OPEN' ? d.state : fresh.state) : fresh);
  }

  static GhIssue _issueWithLabels(GhIssue i, List<GhLabel> labels) => GhIssue.fromJson({...i.toJson(), 'labels': [for (final l in labels) l.toJson()]});

  static GhIssue _issueWithState(GhIssue i, String state) => GhIssue(
        number: i.number,
        title: i.title,
        state: state,
        url: i.url,
        author: i.author,
        labels: i.labels,
        assignees: i.assignees,
        createdAt: i.createdAt,
        updatedAt: i.updatedAt,
        body: i.body,
        comments: i.comments,
      );

  void _load() {
    final g = ++_generation;
    setState(() => error = '');
    GhApi.getJson(onFloor(store, '/api/gh/issue?number=${it.number}')).then((j) {
      if (g != _generation || !mounted) return;
      final d = GhIssueDetail.fromJson(j);
      setState(() {
        detail = d;
        it = _issueWithState(it, d.state);
      });
    }).catchError((Object err) {
      if (g == _generation && mounted) setState(() => error = '$err');
    });
  }

  void _addToQueue() {
    if (!provider.valid()) return;
    widget.modal.close();
    actions.queue(issuePrompt(it), '#${it.number} ${it.title}', it.number, provider: provider.value, model: provider.model);
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = it.state == 'OPEN';
    final h = MediaQuery.sizeOf(context).height;
    final muted = heavy(13, color: Swatch.muted, weight: FontWeight.w700);
    return ModalWindow(
      modal: widget.modal,
      width: 920,
      height: (h - 32).clamp(0, 920),
      scrollBody: false,
      bodyPadding: EdgeInsets.zero,
      title: _title(_pill(isOpen ? 'open' : 'closed', isOpen ? 'done' : 'offline'), '#${it.number} ${it.title}'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaBar(children: [
            GhAvatar(it.author),
            Text(it.author, style: heavy(13, weight: FontWeight.w900)),
            Text('opened this ${timeAgo(it.createdAt)}', style: muted),
            if (it.assignees.isNotEmpty) Text('· 👤 ${it.assignees.join(', ')}', style: muted),
            ...it.labels.map(LabelChip.new),
            _LabelButton(
              has: it.labels.isNotEmpty,
              onPressed: () => openLabels(widget.scope, GhKind.issue, it.number, it.title, it.url, it.labels,
                  onSaved: (labels) => mounted ? setState(() => it = _issueWithLabels(it, labels)) : null),
            ),
          ]),
          Expanded(child: _conversation()),
        ],
      ),
      footer: _footer(isOpen),
    );
  }

  Widget _conversation() {
    final d = detail;
    final items = <Widget>[
      _commentCard(GhComment(id: 'body', author: it.author, body: d?.body ?? it.body, createdAt: it.createdAt, url: it.url), itemUrl, 'opened this'),
      if (error.isNotEmpty)
        _errorBox(error, _load)
      else if (d == null)
        _spinnerRow('Loading comments…')
      else if (d.comments.isEmpty)
        _quiet('No comments yet.')
      else
        ...d.comments.map((c) => _commentCard(c, itemUrl, 'commented')),
    ];
    return ColoredBox(
      color: _ghBg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _vgap(items, 14)),
                const SizedBox(height: 14),
                _CommentBox(
                  kind: GhKind.issue,
                  number: it.number,
                  itemUrl: itemUrl,
                  net: _sock(widget.scope),
                  viewer: d?.viewer ?? '',
                  onPosted: (c) {
                    if (detail == null) return _load();
                    setState(() => detail!.comments.add(c));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(bool isOpen) {
    final task = store.taskForIssue(it.number);
    final onQueue = task != null && task.status != TaskStatus.done;
    return Row(
      children: [
        Expanded(child: Align(alignment: Alignment.centerLeft, child: _Link('Open on GitHub ↗', it.url, style: heavy(14, color: _blueLink)))),
        Flexible(
          flex: 4,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              OfficeButton(
                label: '✍️ Ask a worker…',
                tooltip: 'Send a worker your own prompt about this issue',
                onPressed: () => actions.ask(issueContext(it), 'Ask about issue #${it.number}'),
              ),
              if (isOpen)
                OfficeButton(
                  label: '✔️ Close issue…',
                  tooltip: 'Close this issue on GitHub',
                  onPressed: () => _openClose(widget.scope, GhKind.issue, it.number, it.title, null, _load),
                ),
              if (isOpen && !onQueue) _ProviderPickerView(provider),
              if (isOpen)
                OfficeButton(
                  label: onQueue ? (task.status == TaskStatus.running ? '🤖 ${task.workerName ?? 'A worker'} is on it' : '📋 On the queue') : '📋 Add to queue',
                  tooltip: onQueue ? null : 'A worker picks it up by itself when a desk is free and there is room under the worker limit',
                  onPressed: onQueue ? null : _addToQueue,
                ),
              if (isOpen)
                OfficeButton(
                  label: '✋ Pick it up',
                  tooltip: 'Carry its card to an empty desk, a worker or the queue board, and press E there',
                  onPressed: () => actions.pickUp(it),
                ),
              OfficeButton(
                label: '🤖 Hand to a worker',
                kind: BtnKind.primary,
                onPressed: () => actions.assign(issuePrompt(it), 'Hand issue #${it.number} to a worker'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Provider picker ----------------------------------------------------------------------------
// A small port of provider.ts's providerPicker for the issue window's queue button. It never offers
// a provider the server's project metadata doesn't list.

const _providerKey = 'agent-office.provider';
const _providerLabel = {
  AgentProvider.claude: 'Claude Code',
  AgentProvider.opencode: 'OpenCode',
  AgentProvider.codex: 'Codex',
  AgentProvider.custom: 'Custom',
};

String _providerNote(AgentProvider p) => switch (p) {
      AgentProvider.claude => 'Office usage and budget track Claude Code.',
      AgentProvider.codex => 'Review Office hooks in /hooks to enable tracking. Codex reports root-session tokens; subagents are excluded and cost is unavailable.',
      AgentProvider.custom => 'Usage is untracked unless compatible Claude Code hooks report it.',
      _ => 'OpenCode reports model/provider estimates; they are not billing, and arrive after the first report.',
    };

/// Providers the server says this project can start.
List<AgentProvider> _supportedProviders(ProjectInfo? project) {
  final values = project?.agentProviders.toSet().toList() ?? const [];
  if (values.isNotEmpty) return values;
  return project != null ? [project.defaultProvider] : const [AgentProvider.claude];
}

/// The provider's name, resolving old tasks with no provider to the project's default.
String providerName(AgentProvider? provider, ProjectInfo? project) =>
    _providerLabel[provider ?? project?.defaultProvider ?? _supportedProviders(project).first]!;

bool _validModel(String v) {
  if (v.isEmpty || v.length > 256 || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(v)) return false;
  final parts = v.split('/');
  return parts.length >= 2 && RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$').hasMatch(parts.first) && parts.skip(1).every((p) => p.isNotEmpty);
}

class _ProviderPicker extends ChangeNotifier {
  _ProviderPicker(ProjectInfo? project, this.label) : options = _supportedProviders(project) {
    final fallback = project != null && options.contains(project.defaultProvider) ? project.defaultProvider : options.first;
    final saved = AgentProvider.tryParse(storageGet(_providerKey));
    selected = saved != null && options.contains(saved) ? saved : fallback;
  }

  final String label;
  final List<AgentProvider> options;
  late AgentProvider selected;
  final modelCtl = TextEditingController();
  String? modelError;

  AgentProvider get value => selected;

  /// The optional initial OpenCode model override. Empty or invalid input is omitted.
  String? get model => selected == AgentProvider.opencode && _validModel(modelCtl.text) ? modelCtl.text : null;

  void pick(AgentProvider p) {
    selected = p;
    storageSet(_providerKey, p.wire);
    notifyListeners();
  }

  /// Reports a visible field error for an invalid nonempty OpenCode model.
  bool valid() {
    if (selected != AgentProvider.opencode || modelCtl.text.isEmpty) {
      modelError = null;
      return true;
    }
    final ok = _validModel(modelCtl.text);
    modelError = ok ? null : 'Use provider/model format without whitespace or control characters (up to 256 characters).';
    notifyListeners();
    return ok;
  }

  @override
  void dispose() {
    modelCtl.dispose();
    super.dispose();
  }
}

class _ProviderPickerView extends StatelessWidget {
  const _ProviderPickerView(this.p);
  final _ProviderPicker p;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.label, style: heavy(12)),
              const SizedBox(height: 2),
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9), border: Border.all(color: Swatch.ink, width: 2)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AgentProvider>(
                    value: p.selected,
                    isDense: true,
                    style: heavy(13),
                    items: [for (final o in p.options) DropdownMenuItem(value: o, child: Text(_providerLabel[o]!))],
                    onChanged: (v) => v == null ? null : p.pick(v),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(_providerNote(p.selected), style: heavy(11, color: Swatch.muted, weight: FontWeight.w700)),
          ),
          if (p.selected == AgentProvider.opencode) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 190,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('OpenCode model', style: heavy(12)),
                  const SizedBox(height: 3),
                  SizedBox(
                    height: 30,
                    child: TextField(
                      controller: p.modelCtl,
                      maxLength: 256,
                      style: heavy(13, weight: FontWeight.w500),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Default (OpenCode settings)',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: BorderSide(color: p.modelError != null ? Swatch.bad : Swatch.ink, width: 2),
                        ),
                      ),
                    ),
                  ),
                  if (p.modelError != null) Text(p.modelError!, style: heavy(11, color: Swatch.bad, weight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ],
      );
}
