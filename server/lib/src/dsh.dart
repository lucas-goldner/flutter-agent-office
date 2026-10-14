// DeepSeek Harness as a provider, over ACP (see docs/dsh-acp-integration.md). Ported from upstream's
// src/server/dsh.ts.
//
// `dsh` has no interactive terminal: its ACP profile speaks newline-delimited JSON-RPC v1 over
// stdio instead. A DSH worker therefore keeps the office's headless terminal, but nothing is
// mirrored into it — committed assistant messages, thoughts, tool lifecycles and permission
// prompts are rendered into it here, as ANSI lines.
//
// This module owns the wire. The translation core above the connection is pure, so the test suite
// can drive a fake ACP agent over stdio without a DSH install (test/dsh_test.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'providers/provider.dart' show writePrivate;

const dshProfileDefault = 'acp';

/// Where a floor keeps the sessions the office lists and resumes (under its .agent-office dir).
const dshSessionsDir = 'dsh-sessions';
const dshPatchFile = 'dsh-patch.yml';

const _esc = '\x1b[';
const _reset = '${_esc}0m';

const _bold = '${_esc}1m';
const _italic = '${_esc}3m';
const _underline = '${_esc}4m';

/// 24-bit foreground, for the harness's own semantic colors on the office's dark terminal.
String _fg(String hex) {
  final n = int.parse(hex.replaceFirst('#', ''), radix: 16);
  return '${_esc}38;2;${(n >> 16) & 255};${(n >> 8) & 255};${n & 255}m';
}

/// 24-bit background, for the harness's code blocks.
String _bg(String hex) {
  final n = int.parse(hex.replaceFirst('#', ''), radix: 16);
  return '${_esc}48;2;${(n >> 16) & 255};${(n >> 8) & 255};${n & 255}m';
}

/// DeepSeek Harness's own design tokens, read off its theme (`body[data-ds-dark-theme]`, the mode
/// the office's dark terminal matches) and carried into ANSI here. Every color in this file comes
/// from this table, so the transcript and the harness's web chat agree.
abstract final class _V {
  /// `label-primary`: assistant prose.
  static final text = _fg('#F9FAFB');

  /// `label-secondary`: a tool's title.
  static final secondary = _fg('#CFD3D6');

  /// `label-tertiary`: reasoning, tool summaries, captions.
  static final muted = _fg('#ADB2B8');

  /// `label-caption`: the dot between a tool's title and its summary.
  static final faint = _fg('#81858C');

  /// `link` (dark): the harness's blue, for notices and the person's own line.
  static final brand = _fg('#7AAAFF');

  /// `state-warn-primary`, with `-secondary` for the approval edge.
  static final warn = _fg('#F59E0B');
  static final warnEdge = _fg('#F7AD31');

  /// `state-error-primary` (dark).
  static final bad = _fg('#F25A5A');

  /// Code: the harness renders it in the body color on a subtle block of its own.
  static final code = _fg('#E1E5EE');
  static final inlineCodeBg = _bg('#292929');
  static final blockCodeBg = _bg('#1B1B1C');

  /// `label-dimmed`, for a fenced block's gutter.
  static final faintBg = _fg('#81858C');
  static const reset = _reset;
  static const bold = _bold;
  static const italic = _italic;
  static const underline = _underline;
}

/// The left rule that marks a block as reasoning rather than the answer.
const _thoughtRule = '│';

/// The marker a tool call's outcome hangs from.
const _toolElbow = '└';

/// Bounds on everything read off the wire, so a chatty or hostile agent can't grow a terminal.
const _maxText = 4000;
const _maxLine = 2000;
const _maxFrame = 4000000;

/// A line typed into a DSH terminal, before Enter: about what a prompt box takes.
const _maxTyped = 20000;

/// A permission request never needs more choices than a person can read.
const _maxOptions = 20;
const _controlTimeoutMs = 30000;

/// Tool output shown per update: enough to be useful, not enough to bury the turn.
const _maxToolOutputLines = 8;

typedef _Rec = Map<dynamic, dynamic>;

String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;

num? _num(Object? value) => value is num && value.isFinite ? value : null;

String _bounded(String text, [int max = _maxText]) => text.length > max ? '${text.substring(0, max)}…' : text;

String _oneLine(String text, [int max = _maxLine]) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}

String _reason(Object err) => switch (err) {
  StateError(:final message) => message,
  ProcessException(:final message) => message,
  _ => '$err',
};

// -------------------------------------------------------------------------------------------------
// The wire, as far as this office needs it
// -------------------------------------------------------------------------------------------------

class DshPermissionOption {
  const DshPermissionOption({required this.optionId, required this.name, required this.kind, required this.once});

  final String optionId;
  final String name;
  final String kind;

  /// One-shot choices are the only ones ACP offers; kept for the rendered prompt.
  final bool once;
}

/// The choices a permission request offers, defensively read off the wire.
List<DshPermissionOption> permissionOptions(Object? params) {
  final raw = params is _Rec && params['options'] is List ? params['options'] as List : const [];
  final options = <DshPermissionOption>[];
  for (final entry in raw) {
    if (options.length >= _maxOptions) break;
    if (entry is! _Rec) continue;
    final optionId = _str(entry['optionId']);
    if (optionId == null) continue;
    final kind = _str(entry['kind']) ?? 'other';
    options.add(
      DshPermissionOption(
        optionId: optionId,
        name: _oneLine(_str(entry['name']) ?? optionId, 120),
        kind: kind,
        once: kind.contains('once'),
      ),
    );
  }
  return options;
}

/// What a typed line means while a permission prompt is open: an option, or nothing.
DshPermissionOption? permissionChoice(String line, List<DshPermissionOption> options) {
  final text = line.trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(text)) {
    final i = int.parse(text) - 1;
    return i >= 0 && i < options.length ? options[i] : null;
  }
  return options.where((o) => o.optionId == text).firstOrNull ??
      options.where((o) => o.name.toLowerCase() == text.toLowerCase()).firstOrNull;
}

/// A one-line notice from the office itself, rather than from the model.
String _notice(String kind, String text) {
  final glyph = switch (kind) {
    'bad' => '✖',
    'warn' => '▲',
    'quiet' => '·',
    _ => '◆',
  };
  final paint = switch (kind) {
    'bad' => _V.bad,
    'warn' => _V.warn,
    'quiet' => _V.muted,
    _ => _V.brand,
  };
  final body = kind == 'quiet' ? _V.muted : paint;
  return '$paint$glyph${_V.reset} $body${_escapeText(text)}${_V.reset}\r\n';
}

/// The prompted lines for an outstanding permission request. [remembered] is what the tool call's own
/// row said it would do (see [DshRenderer.toolDetail]), for a request that carries only the call's id.
String renderPermission(Object? params, List<DshPermissionOption> options, [String? remembered]) {
  final toolCall = params is _Rec && params['toolCall'] is _Rec ? params['toolCall'] as _Rec : const {};
  // The approval card names the tool the way the harness does, and shows what it will run under it,
  // in full: what is being approved must never be cut off or left to the model's own description.
  final label = _str(toolCall['title']) ?? _str(toolCall['name']);
  final rawInput = toolCall['rawInput'];
  final detail = (rawInput is _Rec ? _toolSummary(rawInput, _detailKeys) : null) ?? remembered;
  final what = label != null ? _oneLine(label, 120) : null;
  final lines = [
    '\r\n${_V.warn}$_bold  ▲ Waiting for approval${_V.reset} ${_V.secondary}${what != null ? 'Tool ${_escapeText(what)} requests privileged execution' : 'A tool call requests privileged execution'}${_V.reset}\r\n',
  ];
  if (detail != null && detail != label) {
    lines.add('    ${_V.code}${_escapeText(_oneLine(detail, _maxText))}${_V.reset}\r\n');
  }
  final width = options.fold(0, (max, o) => o.name.length > max ? o.name.length : max);
  for (var index = 0; index < options.length; index++) {
    final option = options[index];
    // The card paints reject in the error color and allow in the warning's own; so does this.
    final paint = RegExp('reject|cancel|deny').hasMatch(option.kind) ? _V.bad : _V.warnEdge;
    lines.add(
      '  $paint$_bold${index + 1}${_V.reset}${_V.faint})${_V.reset} ${_V.secondary}${_escapeText(option.name.padRight(width))}${_V.reset}  ${_V.faint}${_escapeText(option.kind)}${_V.reset}\r\n',
    );
  }
  final hint = _allowOption(options) != null
      ? 'Enter allows once, Esc rejects, or type a number for another choice.'
      : 'Type a number to choose, or Esc to reject.';
  lines.add('  ${_V.muted}$hint${_V.reset}\r\n');
  return lines.join();
}

/// The choice the harness's Enter key means: allow once, and only that. A request with no one-shot
/// allow (only "always", say) needs a number typed, so a stray Enter never grants more than one call.
DshPermissionOption? _allowOption(List<DshPermissionOption> options) =>
    options.where((o) => o.once && RegExp('allow|approve|accept').hasMatch(o.kind)).firstOrNull;

/// What a tool call will act on, most specific first: the approval card shows this, not the model's description of it.
const _detailKeys = ['command', 'path', 'file_path', 'query', 'pattern', 'url', 'description'];

/// The choice its Escape key means: reject, if the tool offers one.
DshPermissionOption? _rejectOption(List<DshPermissionOption> options) =>
    options.where((o) => RegExp('reject|cancel|deny').hasMatch(o.kind)).firstOrNull;

/// The ACP `ToolKind` → office action mapping (docs/dsh-acp-integration.md). Kinds are semantic, so
/// they are trusted ahead of the tool's name; a call with no usable kind falls back to the same
/// name-based mapper the other providers use.
WorkerAction? toolKindAction(Object? kind, Object? name, Object? title, Object? rawInput) {
  final k = _str(kind);
  if (k == 'read') return WorkerAction.read;
  if (k == 'edit' || k == 'delete' || k == 'move') return WorkerAction.edit;
  if (k == 'fetch') return WorkerAction.web;
  if (k == 'execute') {
    final command = rawInput is _Rec ? _str(rawInput['command']) : null;
    return command != null ? commandAction(command) : null;
  }
  if (k == 'search') {
    // A code search reads; a web search browses. The title is where the difference shows.
    final haystack = '${_str(title) ?? ''} ${_str(name) ?? ''}'.toLowerCase();
    return RegExp('web|fetch|http|url|brows').hasMatch(haystack) ? WorkerAction.web : WorkerAction.read;
  }
  if (k == null) return toolAction(name ?? title, rawInput);
  return null; // think, switch_mode, other: plain typing
}

/// ACP's `usage_update` is context occupancy plus, possibly, a cumulative cost — not the
/// input/output/cache split the office's Usage type wants. Context tokens are reported as `input`
/// with an authoritative `totalTokens`, and cost is only shown when the agent supplies it
/// (docs/dsh-acp-integration.md, usage option 1).
Usage? dshUsage(Object? update) {
  if (update is! _Rec) return null;
  final used = _num(update['used']);
  final size = _num(update['size']);
  if (used == null || size == null) return null;
  final costField = update['cost'];
  final cost = costField is _Rec ? _num(costField['amount']) : null;
  final tokens = used.round() < 0 ? 0 : used.round();
  return Usage(
    input: tokens,
    output: 0,
    reasoning: 0,
    cacheWrite: 0,
    cacheRead: 0,
    cost: cost != null ? (cost < 0 ? 0 : cost.toDouble()) : 0,
    costKnown: cost != null,
    calls: 0,
    callsKnown: false,
    totalTokens: tokens,
    contextSize: size.round() < 0 ? 0 : size.round(),
  );
}

class RenderedUpdate {
  const RenderedUpdate(this.text, {this.action, this.failed = false, this.usage});

  /// ANSI text for the worker's terminal (empty when the update is not worth a line).
  final String text;

  /// What the worker should act out now.
  final WorkerAction? action;

  /// A tool call that failed, for the hands-on-heads pose.
  final bool failed;

  /// Context usage, when the update carried any.
  final Usage? usage;
}

/// Renders committed ACP updates into terminal lines, in the harness's own visual language.
///
/// Text is buffered by line rather than written as it streams: a line is emitted only once it is
/// complete, so markdown is formatted whole, a span never splits across chunks, and every line ends
/// CRLF (a bare LF drifting the cursor is what made the first version's output staircase). Reasoning
/// is the harness's "Think" block, each tool call is one row with the harness's own title and
/// summary, a finished tool call is left collapsed the way the chat leaves it, and an approval reads
/// like its approval card. Anything the office does not understand is skipped, never fatal.
class DshRenderer {
  String? _mode;
  String _buffer = '';
  bool _fence = false;

  /// Tool calls by id, so an update that carries only the id still knows what the tool was.
  final _tools = <String, _ToolRow>{};
  int _toolCalls = 0;

  /// What tool call [id] said it would act on, for the approval card.
  String? toolDetail(String? id) => id != null ? _tools[id]?.detail : null;

  /// Closes the turn: flush what is left, close an open code fence, and report the turn the way the
  /// chat's process row does ("Worked · 3 tool calls"). [outcome] is Worked, Stopped or Failed.
  String endTurn([String outcome = 'Worked']) {
    final out = <String>[];
    _flush(out, true);
    _closeFence(out);
    _mode = null;
    final calls = _toolCalls;
    _toolCalls = 0;
    final paint = outcome == 'Failed'
        ? _V.bad
        : outcome == 'Stopped'
        ? _V.warn
        : _V.muted;
    final count = calls > 0 ? ' · $calls tool call${calls == 1 ? '' : 's'}' : '';
    out.add('$paint  $outcome$count${_V.reset}\r\n');
    return out.join();
  }

  RenderedUpdate render(Object? update) {
    final out = <String>[];
    if (update is! _Rec) return const RenderedUpdate('');
    final kind = _str(update['sessionUpdate']);

    if (kind == 'agent_message_chunk' || kind == 'agent_thought_chunk') {
      final content = update['content'];
      final text = content is _Rec ? _str(content['text']) : null;
      if (text == null) return const RenderedUpdate('');
      _write(out, kind == 'agent_thought_chunk' ? 'thought' : 'text', text);
      return RenderedUpdate(out.join());
    }

    if (kind == 'tool_call') {
      _closeFence(out);
      _flush(out, true);
      final id = _str(update['toolCallId']);
      final row = _toolRow(update);
      if (id != null) _tools[id] = row;
      _toolCalls++;
      out.add(_toolLine(row));
      return RenderedUpdate(
        out.join(),
        action: toolKindAction(update['kind'], update['name'], update['title'], update['rawInput']),
      );
    }

    if (kind == 'tool_call_update') {
      final id = _str(update['toolCallId']);
      final remembered = id != null ? _tools[id] : null;
      final row = _toolRow(update, remembered);
      if (id != null) _tools[id] = row;
      final status = _str(update['status']);
      if (status == 'failed') {
        _closeFence(out);
        _flush(out, true);
        final why = _toolError(update);
        out.add(
          '  ${_V.faint}$_toolElbow${_V.reset} ${_V.bad}${_escapeText(row.title)} failed${_V.reset}${why != null ? ' ${_V.faint}·${_V.reset} ${_V.muted}${_escapeText(why)}${_V.reset}' : ''}\r\n',
        );
        out.addAll(_toolOutput(update));
        return RenderedUpdate(out.join(), action: WorkerAction.failing, failed: true);
      }
      // completed: the harness leaves a finished tool call collapsed, with no check mark, so there
      // is nothing to add to the row this tool already printed.
      final action = toolKindAction(update['kind'], update['name'], update['title'], update['rawInput']);
      return RenderedUpdate('', action: action);
    }

    if (kind == 'usage_update') return RenderedUpdate('', usage: dshUsage(update));

    if (kind == 'config_option_update') {
      _closeFence(out);
      _flush(out, true);
      final options = update['configOptions'];
      for (final option in options is List ? options : const []) {
        if (option is! _Rec) continue;
        final id = _str(option['id']);
        final current = option['currentValue'];
        final value = _str(current) ?? (current is bool ? '$current' : null);
        if (id != null && value != null) {
          out.add(
            '  ${_V.muted}${_escapeText(id)} ${_V.faint}→${_V.reset} ${_V.muted}${_escapeText(_oneLine(value, 120))}${_V.reset}\r\n',
          );
        }
      }
      return RenderedUpdate(out.join());
    }

    // plan, current_mode, available_commands and anything newer: not part of this surface.
    return const RenderedUpdate('');
  }

  /// Buffers streamed text for [mode], flushing whole lines as they complete.
  void _write(List<String> out, String mode, String text) {
    if (_mode != mode) {
      final wasThinking = _mode == 'thought';
      _closeFence(out);
      _flush(out, true);
      _mode = mode;
      // The chat introduces reasoning with a "Think" row; give the block the same heading, and let
      // the answer start clear of it.
      if (mode == 'thought') {
        out.add('${_V.secondary}  ✻ Think${_V.reset}\r\n');
      } else if (wasThinking) {
        out.add('\r\n');
      }
    }
    _buffer += text;
    _flush(out, false);
  }

  void _flush(List<String> out, bool last) {
    // Model text is untrusted: keep newlines and tabs, and strip whole escape sequences (colors,
    // cursor moves, window titles) before anything else looks at the text, so no trace of one can
    // show up as if the model had typed it.
    _buffer = _escapeText(_buffer.replaceAll(RegExp(r'\r\n?'), '\n'));
    for (;;) {
      final nl = _buffer.indexOf('\n');
      if (nl < 0) break;
      final line = _buffer.substring(0, nl);
      _buffer = _buffer.substring(nl + 1);
      out.add(_line(line));
    }
    // A single line that never ends still has to show something before it is finished.
    if (_buffer.length > 4000) {
      out.add(_line(_buffer));
      _buffer = '';
    }
    if (last && _buffer.isNotEmpty) {
      out.add(_line(_buffer));
      _buffer = '';
    }
  }

  /// One complete line, styled for what it is: fenced code, reasoning, or the answer.
  String _line(String raw) {
    final text = raw.replaceAll('\t', '  ').replaceFirst(RegExp(r'\s+$'), '');
    final probe = text.trim();
    if (probe.startsWith('```')) {
      final opening = !_fence;
      _fence = opening;
      if (opening) {
        final language = _oneLine(probe.substring(3), 40);
        return '  ${_V.faintBg}┌─${language.isNotEmpty ? ' ${_V.code}${_V.blockCodeBg}${_escapeText(language)}' : ''}${_V.reset}\r\n';
      }
      return '  ${_V.faintBg}└─${_V.reset}\r\n';
    }
    if (_fence) return '  ${_V.blockCodeBg}${_V.code}${_escapeText(text)}${_V.reset}\r\n';
    if (_mode == 'thought') return '${_V.muted}  $_thoughtRule ${_markdown(text, _V.muted)}${_V.reset}\r\n';
    return '${_markdown(text, _V.text)}${_V.reset}\r\n';
  }

  void _closeFence(List<String> out) {
    if (!_fence) return;
    _fence = false;
    out.add('  ${_V.faintBg}└─${_V.reset}\r\n');
  }

  /// A failing tool's own output, tail-first, so it says why without burying the turn.
  List<String> _toolOutput(_Rec update) {
    final text = _contentText(update);
    if (text == null) return const [];
    final lines = [for (final line in text.split('\n')) line.replaceFirst(RegExp(r'\s+$'), '')];
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final shown = lines.length > _maxToolOutputLines ? lines.sublist(lines.length - _maxToolOutputLines) : lines;
    final omitted = lines.length - shown.length;
    return [
      if (omitted > 0) '      ${_V.faint}… $omitted more line${omitted == 1 ? '' : 's'}${_V.reset}\r\n',
      for (final line in shown) '      ${_V.muted}${_escapeText(_oneLine(line, _maxLine))}${_V.reset}\r\n',
    ];
  }
}

/// One tool call as the chat draws it: a leading icon, a title, and a one-line summary.
class _ToolRow {
  const _ToolRow({required this.icon, required this.title, this.summary, this.detail});

  final String icon;
  final String title;
  final String? summary;

  /// What it acts on (the command, the path), for an approval that names only the call's id.
  final String? detail;
}

typedef _Described = ({String icon, String title, List<String> keys});

/// The harness's own tool rows: it picks a title and which argument to summarize by the tool's wire
/// name (its client has no per-ToolKind icon table), so this mirrors that table as closely as a
/// terminal can. The icons are glyphs standing in for the SVGs the chat draws.
final List<({RegExp name, _Described row})> _toolRows = [
  (name: RegExp(r'^(pwsh|bash)$'), row: (icon: '❯', title: 'Bash', keys: ['description', 'command'])),
  (name: RegExp(r'^run_code$'), row: (icon: '{ }', title: 'Code', keys: ['description'])),
  (name: RegExp(r'^read_image$'), row: (icon: '▤', title: 'Read image', keys: ['path', 'file_path'])),
  (name: RegExp(r'^read$'), row: (icon: '▤', title: 'Read', keys: ['path', 'file_path', 'url'])),
  (name: RegExp(r'^web_fetch$'), row: (icon: '⇅', title: 'Fetch', keys: ['url'])),
  (name: RegExp(r'^web_search$'), row: (icon: '⌕', title: 'Search', keys: ['query', 'url'])),
  (name: RegExp(r'^grep$'), row: (icon: '⌕', title: 'Grep', keys: ['pattern', 'path'])),
  (name: RegExp(r'^glob$'), row: (icon: '⌕', title: 'Glob', keys: ['pattern', 'path'])),
  (name: RegExp(r'^write$'), row: (icon: '✎', title: 'Write', keys: ['path', 'file_path'])),
  (name: RegExp(r'^edit$'), row: (icon: '✎', title: 'Edit', keys: ['path', 'file_path'])),
];

/// The fallback for a tool this office does not know, from its semantic kind.
_Described _kindRow(Object? kind) {
  final k = _str(kind);
  if (k == 'read') return (icon: '▤', title: 'Read', keys: ['path', 'file_path']);
  if (k == 'edit' || k == 'delete' || k == 'move') return (icon: '✎', title: 'Edit', keys: ['path', 'file_path']);
  if (k == 'execute') return (icon: '❯', title: 'Bash', keys: ['description', 'command']);
  if (k == 'search') return (icon: '⌕', title: 'Search', keys: ['query', 'pattern']);
  if (k == 'fetch') return (icon: '⇅', title: 'Fetch', keys: ['url']);
  return (icon: '✦', title: 'Tool call', keys: const []);
}

/// The first of the harness's summary keys the tool actually sent, else its first short string.
String? _toolSummary(_Rec input, List<String> keys) {
  for (final key in keys) {
    final value = _str(input[key]);
    if (value != null) return value;
  }
  for (final value in input.values) {
    if (value is String && value.trim().isNotEmpty && value.length <= 160) return value;
  }
  return null;
}

/// The row for a tool call, keeping what was already shown when an update carries only its id.
_ToolRow _toolRow(_Rec update, [_ToolRow? remembered]) {
  final wireName = (_str(update['name']) ?? _str(update['title']) ?? '').toLowerCase();
  final known = _toolRows.where((r) => r.name.hasMatch(wireName)).firstOrNull?.row;
  final kind = _str(update['kind']);
  // A tool this office knows by name, else by what the call is doing, else what the row already said.
  final described = known ?? (wireName.isNotEmpty || kind != null ? _kindRow(kind) : null);
  final icon = described?.icon ?? remembered?.icon ?? _kindRow(null).icon;
  final title = described?.title ?? remembered?.title ?? _kindRow(null).title;
  final input = update['rawInput'] is _Rec ? update['rawInput'] as _Rec : null;
  var summary = input != null ? _toolSummary(input, described?.keys ?? const []) : null;
  summary ??= remembered?.summary;
  // An unknown tool's row leads with the tool's own name, the way the chat's generic row does.
  final raw = _str(update['title']) ?? _str(update['name']);
  if (described == null && raw != null) {
    summary = summary != null && summary != raw ? '${_oneLine(raw, 60)} · $summary' : _oneLine(raw, 60);
  }
  final detail = (input != null ? _toolSummary(input, _detailKeys) : null) ?? remembered?.detail;
  return _ToolRow(
    icon: icon,
    title: title,
    summary: summary != null ? _oneLine(summary, 160) : null,
    detail: detail != null ? _bounded(detail) : null,
  );
}

/// A tool row: icon, title, then the harness's dot separator before the summary.
String _toolLine(_ToolRow row) {
  final summary = row.summary != null
      ? ' ${_V.faint}·${_V.reset} ${_V.muted}${_escapeText(row.summary!)}${_V.reset}'
      : '';
  return '  ${_V.faint}${row.icon}${_V.reset} ${_V.secondary}${_escapeText(row.title)}${_V.reset}$summary\r\n';
}

/// Why a tool failed, from its raw output or its content blocks.
String? _toolError(_Rec update) {
  final raw = update['rawOutput'];
  if (raw is _Rec) {
    final message = _str(raw['message']) ?? _str(raw['error']);
    if (message != null) return _oneLine(message, 200);
  }
  if (raw is String && raw.trim().isNotEmpty) return _oneLine(raw, 200);
  final text = _contentText(update);
  return text != null ? _oneLine(text, 200) : null;
}

/// The text of a tool update's content blocks, in order.
String? _contentText(_Rec update) {
  final items = update['content'] is List ? update['content'] as List : const [];
  final parts = <String>[];
  for (final item in items) {
    if (item is! _Rec) continue;
    final direct = _str(item['text']);
    if (direct != null) {
      parts.add(direct);
      continue;
    }
    final content = item['content'];
    if (content is _Rec) {
      final nested = _str(content['text']);
      if (nested != null) parts.add(nested);
    }
  }
  return parts.isNotEmpty ? parts.join('\n') : null;
}

final _osc = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');
final _csi = RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]');
final _twoByte = RegExp(r'\x1b[@-Z\\-_]');
final _controls = RegExp('[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]');

/// Drop control characters and whole escape sequences from text the harness sent, so it cannot drive
/// the terminal — and so the remains of a sequence (`[2J`) never show up as if the model typed it.
String _escapeText(String text) => text
    .replaceAll(_osc, '') // OSC … BEL/ST (titles, hyperlinks)
    .replaceAll(_csi, '') // CSI (colors, cursor, clears)
    .replaceAll(_twoByte, '') // other two-byte escapes
    .replaceAll(_controls, ''); // whatever is left: BEL, 8-bit C1 (CSI, OSC), bidi overrides

/// Text the office writes into a DSH terminal that did not come through the renderer (a prompt, an error).
String terminalSafe(String text) => _escapeText(text);

/// A small markdown renderer for the terminal, standing in for the chat's rich text: headings, rules,
/// quotes, bullets, bold, italic, inline code and links. Streaming is line-buffered upstream, so a
/// span is never split across chunks.
String _markdown(String text, String base) {
  final heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*)$').firstMatch(text);
  if (heading != null) return '${_V.bold}${_V.underline}${_escapeText(heading[2]!)}${_V.reset}$base';
  if (RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$').hasMatch(text)) return '${_V.faint}${'─' * 24}${_V.reset}$base';
  final quote = RegExp(r'^\s{0,3}>\s?(.*)$').firstMatch(text);
  if (quote != null) return '${_V.muted}$_thoughtRule ${_inline(quote[1]!, _V.muted)}${_V.reset}';
  final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(text);
  if (bullet != null) return '${bullet[1]}${_V.faint}•${_V.reset}$base ${_inline(bullet[2]!, base)}';
  return _inline(text, base);
}

/// Inline spans, always falling back to the line's own color after each one.
///
/// Every span is swapped for a placeholder before the next pattern runs, and the ANSI is substituted
/// at the end: the escapes themselves contain `[`, which the link pattern would otherwise match
/// backwards into, corrupting every span on the line.
String _inline(String raw, String base) {
  final painted = <String>[];
  String hold(String ansi) {
    painted.add(ansi);
    return '\u0001${painted.length - 1}\u0001';
  }

  final text = _escapeText(raw)
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => hold('${_V.inlineCodeBg}${_V.code}${m[1]}${_V.reset}$base'))
      .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => hold('${_V.bold}${m[1]}${_V.reset}$base'))
      .replaceAllMapped(
        RegExp(r'(^|[\s(])\*([^*\n]+)\*'),
        (m) => '${m[1]}${hold('${_V.italic}${m[2]}${_V.reset}$base')}',
      )
      .replaceAllMapped(RegExp(r'(^|[\s(])_([^_\n]+)_'), (m) => '${m[1]}${hold('${_V.italic}${m[2]}${_V.reset}$base')}')
      .replaceAllMapped(
        RegExp(r'\[([^\][]{1,500})\]\(([^)\s]{1,2000})\)'),
        (m) => hold('${_V.underline}${m[1]}${_V.reset}$base ${_V.muted}${m[2]}${_V.reset}$base'),
      );
  return text.replaceAllMapped(RegExp(r'\u0001(\d+)\u0001'), (m) {
    final i = int.parse(m[1]!);
    return i < painted.length ? painted[i] : '';
  });
}

/// The choices a select configuration option advertises, flattened across its groups.
List<({String value, String? name})> configOptionValues(Object? option) {
  if (option is! _Rec || option['options'] is! List) return const [];
  final values = <({String value, String? name})>[];
  void add(Object? entry) {
    if (entry is! _Rec) return;
    final value = _str(entry['value']);
    if (value != null) values.add((value: value, name: _str(entry['name'])));
  }

  for (final entry in option['options'] as List) {
    // Model options arrive grouped by provider: [{group, name, options: [...]}].
    if (entry is _Rec && entry['options'] is List) {
      for (final inner in entry['options'] as List) {
        add(inner);
      }
    } else {
      add(entry);
    }
  }
  return values;
}

/// The model inside an advertised route value, which DSH serializes as a JSON [provider, model] pair.
String? _routeModel(String value) {
  try {
    final parsed = jsonDecode(value);
    if (parsed is List && parsed.isNotEmpty && parsed.last is String) return parsed.last as String;
  } catch (_) {
    // Not a route tuple: the value is already the id itself.
  }
  return null;
}

/// Match what someone typed against the live catalog. DSH model values are opaque route tuples
/// (`["deepseek-official","deepseek-v4-pro"]`), so a person is far more likely to type the model
/// name: accept the exact value, the option's label, or the model inside the tuple. Anything that
/// matches nothing is passed through unchanged and the harness has the final say.
String resolveConfigValue(String input, Object? option) {
  final wanted = input.trim();
  final values = configOptionValues(option);
  if (values.isEmpty) return wanted;
  final exact = values.where((e) => e.value == wanted).firstOrNull;
  if (exact != null) return exact.value;
  final byLabel = values.where((e) => e.name?.toLowerCase() == wanted.toLowerCase()).firstOrNull;
  if (byLabel != null) return byLabel.value;
  final byModel = values.where((e) => (_routeModel(e.value) ?? '').toLowerCase() == wanted.toLowerCase()).firstOrNull;
  return byModel?.value ?? wanted;
}

/// The office's effort levels on DSH's ladder (`off`, `low`, `high`, `max`). The office offers one
/// shared set for Claude and DSH, so the middle levels land on the nearest rung DSH has.
String dshEffort(AgentEffort effort) => switch (effort) {
  AgentEffort.low => 'low',
  AgentEffort.xhigh || AgentEffort.max => 'max',
  _ => 'high', // medium and high: DSH's default balance
};

// -------------------------------------------------------------------------------------------------
// Launch configuration
// -------------------------------------------------------------------------------------------------

String dshSessionsRoot(String dataDir) => p.join(dataDir, dshSessionsDir);

/// `dsh` argv: the office's own `--agent-args` first (so a DSH worker respects them), then the
/// profile, then the patch overlays. A trailing `--profile` wins over anything prepended.
List<String> dshArgs({required String profile, List<String> patches = const [], List<String> extra = const []}) => [
  ...extra,
  '--profile',
  profile,
  for (final patch in patches) ...['--patch', patch],
];

/// The patch overlay that keeps a floor's DSH sessions under the office's own directory instead of
/// the user's `~/.dsh/sessions`, so the office can list and resume exactly what it started.
/// Written once per floor; the same file serves every DSH worker on it.
String writeDshPatch(String dataDir) {
  final file = p.join(dataDir, dshPatchFile);
  final body = [
    '# Written by the office: keep DeepSeek Harness sessions in this checkout.',
    '- id: session-persistence-jsonl',
    '  config:',
    '    root: ${jsonEncode(dshSessionsRoot(dataDir))}',
    '',
  ].join('\n');
  Directory(dataDir).createSync(recursive: true);
  writePrivate(file, body);
  return file;
}

class DshLaunch {
  const DshLaunch({
    required this.file,
    required this.args,
    required this.cwd,
    required this.env,
    this.model,
    this.effort,
    this.resumeSessionId,
    this.firstPrompt,
  });

  /// The executable to run: the configured `dsh`, or one a test points at a fake agent.
  final String file;
  final List<String> args;
  final String cwd;
  final Map<String, String> env;

  /// A model chosen for this worker, applied through `session/set_config_option`.
  final String? model;
  final AgentEffort? effort;

  /// The session to carry on, when there is one (R on an exited worker, or a restart).
  final String? resumeSessionId;

  /// Sent as the first prompt once the session is ready.
  final String? firstPrompt;
}

class DshEvents {
  const DshEvents({
    required this.output,
    required this.status,
    required this.action,
    required this.usage,
    required this.session,
    required this.prompted,
    required this.exit,
  });

  /// ANSI text for the worker's terminal.
  final void Function(String text) output;
  final void Function(WorkerStatus status) status;
  final void Function(WorkerAction? action) action;
  final void Function(Usage usage) usage;

  /// The session id the agent handed back, for the worker's card and for resume.
  final void Function(String sessionId) session;

  /// A prompt someone typed into the terminal, for the worker's task card.
  final void Function(String text) prompted;

  /// The child process ended. `quiet` marks a close the office asked for.
  final void Function(int? code, String? error, bool quiet) exit;
}

/// One DSH worker's ACP connection. Serializes prompts (ACP allows one per session), answers
/// permission requests from the person at the terminal, and renders every update into the worker's
/// headless terminal through `events.output`.
class DshSession {
  DshSession(this._launch, this._events);

  final DshLaunch _launch;
  final DshEvents _events;
  Process? _child;
  final _pending = <int, Completer<Object?>>{};
  int _nextId = 100;
  String? _sessionId;
  String _buffer = '';
  String _line = '';
  ({Object id, List<DshPermissionOption> options})? _permission;
  List<_Rec> _configOptions = [];
  final _renderer = DshRenderer();
  bool _prompting = false;
  bool _finished = false;
  bool _closing = false;
  bool _started = false;
  final _exited = Completer<void>();

  String? get id => _sessionId;

  bool get running => _started && !_finished;

  /// Its process id, once it runs.
  int? get pid => _child?.pid;

  /// Completes once the child has ended.
  Future<void> get done => _exited.future;

  /// Spawns the child and runs the ACP handshake. Everything after is driven by updates.
  void start() {
    if (_started) return;
    _started = true;
    _events.status(WorkerStatus.starting);
    unawaited(_spawn());
  }

  Future<void> _spawn() async {
    Process child;
    try {
      child = await Process.start(
        _launch.file,
        _launch.args,
        workingDirectory: _launch.cwd,
        environment: _launch.env,
        includeParentEnvironment: false,
      );
    } catch (err) {
      _finished = true;
      _events.status(WorkerStatus.exited);
      _events.exit(-1, _reason(err), false);
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    if (_closing) {
      child.kill();
    }
    _child = child;
    child.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(_read, onError: (_) {});
    var stderr = '';
    child.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      stderr = stderr + chunk;
      if (stderr.length > _maxText) stderr = stderr.substring(stderr.length - _maxText);
    }, onError: (_) {});
    child.stdin.done.catchError((_) {}).ignore();
    unawaited(
      child.exitCode.then((code) {
        // Give the last of its output a moment to arrive (it's read on another stream).
        Timer(const Duration(milliseconds: 20), () {
          final err = stderr.trim();
          _finish(code, err.isNotEmpty ? err : null);
        });
      }),
    );
    await _handshake();
  }

  /// Keystrokes from a browser: echoed, buffered to a line, submitted on Enter (see the doc).
  void writeInput(String data) {
    if (_finished || !_started) return;
    if (data == '\x1b') {
      cancelTurn();
      return;
    }
    // Arrow/function keys arrive as escape sequences: swallow them rather than typing them in.
    final cleaned = data.replaceAll(RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'), '').replaceAll(RegExp(r'\x1bO[@-~]'), '');
    // A browser sends each key on its own, so Enter is a lone "\r". Several characters at once are a
    // paste, and a blank line in a paste must not press the approval's Enter (allow once); a choice
    // typed out ("1", an option's name) still has to match one of those listed.
    final burst = cleaned.runes.length > 1;
    var echo = '';
    void flushEcho() {
      if (echo.isNotEmpty) _events.output(echo);
      echo = '';
    }

    for (final rune in cleaned.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '\r' || ch == '\n') {
        if (burst && _permission != null && _line.trim().isEmpty) continue;
        flushEcho();
        _submitLine();
      } else if (ch == '\x7f' || ch == '\b') {
        if (_line.isNotEmpty) {
          final runes = _line.runes.toList()..removeLast();
          _line = String.fromCharCodes(runes);
          echo += '\b \b';
        }
      } else if (ch == '\x03') {
        flushEcho();
        cancelTurn();
      } else if (rune < 0x20 || RegExp('[\x80-\x9f\u202a-\u202e\u2066-\u2069]').hasMatch(ch)) {
        continue;
      } else if (_line.length < _maxTyped) {
        _line += ch;
        echo += ch;
      }
    }
    flushEcho();
  }

  /// A prompt from the office (the prompt box, the queue, a board agent): echoed, then submitted.
  void prompt(String text) {
    final clean = text.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (clean.isEmpty) return;
    if (_prompting) {
      _events.output(_notice('warn', 'one prompt at a time — this turn is still running'));
      return;
    }
    _events.output(
      '${_V.brand}${_V.bold}>${_V.reset} ${_V.text}${_escapeText(_bounded(clean, _maxLine)).replaceAll('\n', '\r\n  ')}${_V.reset}\r\n',
    );
    _sendPrompt(clean);
  }

  /// Escape / Ctrl+C. On an open approval this is the harness's Reject, which the tool records and
  /// the turn carries on around; a tool that offers no reject choice is cancelled outright. With no
  /// question open, it cancels the turn in flight.
  void cancelTurn() {
    if (_finished) return;
    final permission = _permission;
    if (permission != null) {
      final reject = _rejectOption(permission.options);
      _answerPermission(reject?.optionId, reject == null);
      if (reject == null) _notify('session/cancel', {'sessionId': _sessionId});
      return;
    }
    if (_prompting) {
      _events.output('\r\n${_notice('quiet', 'cancelled')}');
      _notify('session/cancel', {'sessionId': _sessionId});
      return;
    }
    _line = '';
    _events.output('\r\n');
  }

  /// Sends home: close the session quietly, then end the child. Completes once it has ended (or was
  /// killed half a second later).
  Future<void> close() {
    if (_closing || _finished) return done;
    _closing = true;
    final session = _sessionId;
    if (session != null) {
      // session/close is a request, but the office does not wait on it: the child goes either way.
      _send({
        'jsonrpc': '2.0',
        'id': ++_nextId,
        'method': 'session/close',
        'params': {'sessionId': session},
      });
    }
    final child = _child;
    Timer(const Duration(milliseconds: 500), () {
      try {
        child?.kill();
        child?.stdin.close().ignore();
      } catch (_) {
        // already gone
      }
    });
    // One still being spawned is killed as soon as it's there (see _spawn).
    return done.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  // --- the handshake, and everything the agent sends back ---------------------------------------

  Future<void> _handshake() async {
    try {
      await _request('initialize', {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
        },
        'clientInfo': {'name': 'agent-office', 'version': '0.1.0'},
      });
    } catch (err) {
      _fail('DeepSeek Harness did not answer initialize: ${_reason(err)}');
      return;
    }

    // Only this worker's own session is carried on. Every desk without a worktree shares the
    // checkout, so "the newest session in this directory" may be another worker's, even one still running.
    var ready = false;
    final resume = _launch.resumeSessionId;
    if (resume != null) ready = await _tryResume(resume);
    if (!ready && !await _newSession()) return;

    await _applyChoices();
    final first = _launch.firstPrompt;
    if (first != null && first.isNotEmpty) {
      prompt(first);
    } else {
      _events.status(WorkerStatus.idle);
    }
  }

  Future<bool> _newSession() async {
    try {
      final result = await _request('session/new', {'cwd': _launch.cwd, 'mcpServers': <Object>[]});
      final id = result is _Rec ? _str(result['sessionId']) : null;
      if (id == null) throw StateError('session/new returned no session id');
      _adopt(id, result is _Rec ? result['configOptions'] : null);
      _events.output(_notice('info', 'DeepSeek Harness ready'));
      return true;
    } catch (err) {
      _fail('DeepSeek Harness could not start a session: ${_reason(err)}');
      return false;
    }
  }

  Future<bool> _tryResume(String id) async {
    try {
      final result = await _request('session/resume', {'sessionId': id, 'cwd': _launch.cwd, 'mcpServers': <Object>[]});
      _adopt(id, result is _Rec ? result['configOptions'] : null);
      _events.output(_notice('info', 'resumed session $id'));
      return true;
    } catch (err) {
      _events.output(_notice('quiet', 'could not resume session $id: ${_oneLine(_reason(err), 200)}'));
      return false;
    }
  }

  void _adopt(String id, Object? configOptions) {
    _sessionId = id;
    _configOptions = configOptions is List ? configOptions.whereType<_Rec>().toList() : [];
    _events.session(id);
  }

  /// Model and reasoning effort chosen for this worker, if the live catalog offers them.
  Future<void> _applyChoices() async {
    final model = _launch.model;
    if (model != null && model.isNotEmpty) await _setConfig('model', model);
    final effort = _launch.effort;
    if (effort != null) await _setConfig('reasoning_effort', dshEffort(effort));
  }

  Future<void> _setConfig(String configId, String wanted) async {
    final option = _configOptions.where((e) => _str(e['id']) == configId).firstOrNull;
    if (option == null) {
      _events.output(_notice('quiet', 'the harness advertises no $configId; keeping the profile default'));
      return;
    }
    final value = resolveConfigValue(wanted, option);
    try {
      final result = await _request('session/set_config_option', {
        'sessionId': _sessionId,
        'configId': configId,
        'value': value,
      });
      final options = result is _Rec ? result['configOptions'] : null;
      if (options is List) _configOptions = options.whereType<_Rec>().toList();
      _events.output(_notice('quiet', '$configId → ${_oneLine(value, 160)}'));
    } catch (err) {
      // A stale saved model must not fail the launch: the profile default stays in force.
      _events.output(
        _notice(
          'warn',
          '$configId "${_oneLine(wanted, 120)}" was not accepted (${_oneLine(_reason(err), 160)}); keeping the profile default',
        ),
      );
    }
  }

  void _sendPrompt(String clean) {
    final session = _sessionId;
    if (session == null) {
      _events.output(_notice('bad', 'no session to prompt yet'));
      return;
    }
    _prompting = true;
    _events.status(WorkerStatus.working);
    _request('session/prompt', {
          'sessionId': session,
          'prompt': [
            {'type': 'text', 'text': clean},
          ],
        }, 0)
        .then((result) {
          _prompting = false;
          final stop = result is _Rec ? _str(result['stopReason']) : null;
          _events.output(_renderer.endTurn(stop == 'cancelled' ? 'Stopped' : 'Worked'));
          _events.action(null);
          // "Worked" and "Stopped" are the harness's own words for those two endings.
          if (stop != null && stop != 'end_turn' && stop != 'cancelled') {
            _events.output(_notice('quiet', _oneLine(stop, 80)));
          }
          _events.status(WorkerStatus.done);
        })
        .catchError((Object err) {
          _prompting = false;
          _events.output(_renderer.endTurn('Failed'));
          _events.output(_notice('bad', 'prompt failed: ${_oneLine(_reason(err), 300)}'));
          _events.action(null);
          _events.status(WorkerStatus.done);
        });
  }

  void _submitLine() {
    final text = _line;
    _line = '';
    _events.output('\r\n');
    final permission = _permission;
    if (permission != null) {
      // Enter on an empty line is the harness's Allow once; a number picks a listed choice.
      if (text.trim().isEmpty) {
        final once = _allowOption(permission.options);
        if (once != null) {
          _answerPermission(once.optionId);
        } else {
          _events.output(_notice('warn', 'no allow-once choice here: type a listed number, or Esc'));
        }
        return;
      }
      final pick = permissionChoice(text, permission.options);
      if (pick != null) {
        _answerPermission(pick.optionId);
        return;
      }
      _events.output(_notice('warn', 'Enter allows once, Esc rejects, or type a listed number'));
      return;
    }
    if (text.trim().isNotEmpty) {
      final clean = text.trim();
      // The office can see prompts it sends itself; this one came from the terminal, so it is told.
      _events.prompted(clean);
      _sendPrompt(clean);
    }
  }

  void _answerPermission(String? optionId, [bool cancelled = false]) {
    final permission = _permission;
    if (permission == null) return;
    _permission = null;
    final outcome = cancelled || optionId == null
        ? {'outcome': 'cancelled'}
        : {'outcome': 'selected', 'optionId': optionId};
    _send({
      'jsonrpc': '2.0',
      'id': permission.id,
      'result': {'outcome': outcome},
    });
    final label = cancelled || optionId == null
        ? 'permission cancelled'
        : 'permission answered: ${_oneLine(optionId, 80)}';
    _events.output(_notice('quiet', label));
    // Answering a prompt's question puts the turn back to work; answering autonomous work leaves the
    // session ready for the next prompt.
    _events.status(_prompting ? WorkerStatus.working : WorkerStatus.idle);
  }

  void _onPermission(Object id, Object? params) {
    final options = permissionOptions(params);
    _permission = (id: id, options: options);
    final toolCall = params is _Rec && params['toolCall'] is _Rec ? params['toolCall'] as _Rec : null;
    _events.output(
      renderPermission(params, options, _renderer.toolDetail(toolCall != null ? _str(toolCall['toolCallId']) : null)),
    );
    _events.status(WorkerStatus.needsInput);
  }

  void _onUpdate(Object? params) {
    final update = params is _Rec ? params['update'] : null;
    final rendered = _renderer.render(update);
    if (rendered.text.isNotEmpty) _events.output(rendered.text);
    final usage = rendered.usage;
    if (usage != null) _events.usage(usage);
    final action = rendered.action;
    if (action != null) _events.action(action);
  }

  // --- framing ----------------------------------------------------------------------------------

  void _read(String chunk) {
    _buffer += chunk;
    for (;;) {
      final nl = _buffer.indexOf('\n');
      if (nl < 0) break;
      final frame = _buffer.substring(0, nl).trim();
      _buffer = _buffer.substring(nl + 1);
      if (frame.isEmpty) continue;
      Object? message;
      try {
        message = jsonDecode(frame);
      } catch (_) {
        _events.output(_notice('quiet', 'unreadable ACP frame'));
        continue;
      }
      try {
        _dispatch(message);
      } catch (err) {
        _events.output(_notice('quiet', 'ACP frame skipped: ${_oneLine(_reason(err), 200)}'));
      }
    }
    // A frame that never ends is not a frame: drop it rather than grow without bound.
    if (_buffer.length > _maxFrame) {
      _buffer = '';
      _events.output(_notice('quiet', 'oversized ACP frame dropped'));
    }
  }

  void _dispatch(Object? message) {
    if (message is! _Rec) return;
    final method = _str(message['method']);
    final id = message['id'];
    if (method != null && id != null) {
      if (method == 'session/request_permission') {
        _onPermission(id as Object, message['params']);
      } else {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'unsupported: $method'},
        });
      }
      return;
    }
    if (method != null) {
      if (method == 'session/update') _onUpdate(message['params']);
      return;
    }
    final waiter = id is int ? _pending.remove(id) : null;
    if (waiter == null) return;
    final error = message['error'];
    if (error != null) {
      waiter.completeError(StateError(error is _Rec ? _str(error['message']) ?? 'unknown error' : 'unknown error'));
    } else {
      waiter.complete(message['result']);
    }
  }

  Future<Object?> _request(String method, Object? params, [int timeoutMs = _controlTimeoutMs]) {
    if (_child == null || _finished) return Future.error(StateError('the DeepSeek Harness process is not running'));
    final id = ++_nextId;
    final waiter = Completer<Object?>();
    _pending[id] = waiter;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    if (timeoutMs > 0) {
      Timer(Duration(milliseconds: timeoutMs), () {
        if (_pending.remove(id) != null) waiter.completeError(StateError('$method timed out'));
      });
    }
    return waiter.future;
  }

  void _notify(String method, Object? params) => _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  void _send(Object message) {
    final child = _child;
    if (child == null || _finished) return;
    try {
      child.stdin.write('${jsonEncode(message)}\n');
    } catch (_) {
      // The exit handler reports a broken pipe.
    }
  }

  void _fail(String message) {
    _events.output(_notice('bad', message));
    final child = _child;
    _finish(-1, message);
    try {
      child?.kill();
    } catch (_) {
      // already gone
    }
  }

  void _finish(int? code, [String? error]) {
    if (_finished) return;
    _finished = true;
    final quiet = _closing;
    for (final waiter in _pending.values) {
      waiter.completeError(StateError('the DeepSeek Harness process ended'));
    }
    _pending.clear();
    _child = null;
    _events.exit(code, error, quiet);
    if (!_exited.isCompleted) _exited.complete();
  }
}
