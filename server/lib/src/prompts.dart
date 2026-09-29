// The prompts the office writes for workers by itself (office_shared's prompts.dart), as rewritten in
// ⚙️ Settings, and the provider, model and effort every worker starts on unless whoever starts it
// picks others. Port of src/server/prompts.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'agents.dart';

/// What the floors read: a prompt as the office has it now, and what workers start on.
abstract interface class PromptSource {
  String text(PromptId id);

  /// The worker picked in ⚙️ Settings, when one was.
  AgentChoice? agent();
}

/// A prompt's text, from [source] when there is one, else the default, with its placeholders filled.
String officePrompt(PromptSource? source, PromptId id, [PromptVars vars = const {}]) =>
    fillPrompt(source != null ? source.text(id) : prompts[id]!.text, vars);

/// The providers this office can start, and the one it was started with (--agent).
typedef OfficeProviders = ({List<AgentProvider> list, AgentProvider configured});

/// The same for the whole building, kept in .agent-office/prompts.json; admins change them.
class OfficePrompts implements PromptSource {
  OfficePrompts(String dataDir, this._providers, this._onState) : _path = p.join(dataDir, 'prompts.json') {
    _restore();
  }

  final OfficeProviders _providers;
  final void Function(PromptsState state) _onState;
  final String _path;
  final Map<PromptId, PromptCustom> _custom = {};
  PromptsAgent? _agent;

  PromptsState state() => PromptsState(custom: Map.of(_custom), agent: _agent);

  @override
  String text(PromptId id) => promptText(_custom, id);

  @override
  AgentChoice? agent() {
    final a = _agent;
    return a == null ? null : AgentChoice(provider: a.provider, model: a.model, effort: a.effort);
  }

  /// Rewrites a prompt; [text] null (or the default's own text) puts the default back. Returns why it
  /// can't, if it can't.
  String? setPrompt(Object? id, String? text, String by) {
    if (!isPromptId(id)) return 'Unknown prompt';
    final key = id as String;
    final def = prompts[key]!;
    final clean = text?.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (clean != null && clean.length > promptMax) return 'A prompt can be ${_thousands(promptMax)} characters at most';
    if (clean == '' && !def.optional) return 'That prompt can’t be empty: write something, or put the default back';
    if (clean == null || clean == def.text) {
      _custom.remove(key);
    } else {
      _custom[key] = PromptCustom(text: clean, by: by, at: DateTime.now().millisecondsSinceEpoch);
    }
    _changed();
    return null;
  }

  /// Picks the worker everyone starts on; null goes back to the one the office was started with.
  String? setAgent(AgentChoice? choice, String by) {
    if (choice == null) {
      _agent = null;
      _changed();
      return null;
    }
    final why = _problem(choice.provider, choice.model, choice.effort);
    if (why != null) return why;
    _agent = PromptsAgent(
      provider: choice.provider,
      model: choice.model == null || choice.model!.isEmpty ? null : choice.model,
      effort: choice.effort,
      by: by,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _changed();
    return null;
  }

  /// Checks a choice as it came off the wire ([provider] may be anything).
  String? problem(Object? provider, Object? model, Object? effort) => _problem(provider, model, effort);

  String? _problem(Object? provider, Object? model, Object? effort) {
    final pr = provider is AgentProvider ? provider : AgentProvider.tryParse(provider);
    if (pr == null || !_providers.list.contains(pr)) return 'Unknown agent provider';
    if (pr == AgentProvider.custom && _providers.configured != AgentProvider.custom) {
      return 'Custom is not the configured agent provider';
    }
    return validateWorkerModel(WorkerKind.agent, pr, model) ?? validateWorkerEffort(WorkerKind.agent, pr, effort);
  }

  void _changed() {
    _persist();
    _onState(state());
  }

  void _restore() {
    Object? raw;
    try {
      raw = jsonDecode(File(_path).readAsStringSync());
    } catch (_) {
      return; // never changed: the defaults
    }
    if (raw is! Map) return;
    final custom = raw['custom'];
    if (custom is Map) {
      for (final e in custom.entries) {
        final v = e.value;
        if (!isPromptId(e.key) || v is! Map || v['text'] is! String) continue;
        final text = v['text'] as String;
        _custom[e.key as String] = PromptCustom(
          text: text.length > promptMax ? text.substring(0, promptMax) : text,
          by: v['by'] is String ? v['by'] as String : 'someone',
          at: v['at'] is num ? (v['at'] as num).toInt() : 0,
        );
      }
    }
    final a = raw['agent'];
    if (a is Map) {
      final provider = AgentProvider.tryParse(a['provider']);
      if (provider != null) {
        final model = a['model'] is String ? a['model'] as String : null;
        final effort = AgentEffort.tryParse(a['effort']);
        // One the office can't start any more (it was started with another --agent) is forgotten.
        if (_problem(provider, model, effort) == null) {
          _agent = PromptsAgent(
            provider: provider,
            model: model,
            effort: effort,
            by: a['by'] is String ? a['by'] as String : 'someone',
            at: a['at'] is num ? (a['at'] as num).toInt() : 0,
          );
        }
      }
    }
  }

  void _persist() {
    try {
      final tmp = '$_path.tmp';
      File(tmp).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'custom': {for (final e in _custom.entries) e.key: e.value.toJson()},
          'agent': ?_agent?.toJson(),
        }),
      );
      chmodSync(tmp, 0x180); // 0600
      File(tmp).renameSync(_path);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// 20000 → "20,000".
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
