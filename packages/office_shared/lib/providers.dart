// The agents a worker can run, and what the office knows about each of them, in one table: its
// name, the executable it runs as, which models and reasoning efforts it takes and how its spend
// shows. How the server starts and follows each one is its own business.
//
// Ported from src/shared/providers.ts. The provider and effort enums themselves ([AgentProvider],
// [AgentEffort], [claudeModels], [isClaudeModel]) stay in protocol.dart, where the wire types are.

import 'protocol.dart';

/// Every provider, in the table's order (TS AGENT_PROVIDERS).
const List<AgentProvider> agentProviderList = AgentProvider.values;

/// The model each alias stands for in Claude Code today, for the windows to say which one a worker
/// gets ("Opus 5.5", not "Opus"). Claude Code resolves the alias itself, to its own latest: a new
/// model generation means new names here. Once a worker has spoken, its card goes by the model its
/// session reports instead (see [claudeModelName]).
const Map<String, String> claudeModelNames = {
  'fable': 'Fable 5.1',
  'opus': 'Opus 5.5',
  'sonnet': 'Sonnet 5.5',
  'haiku': 'Haiku 4.5',
};

final RegExp _claudeNow = RegExp(r'claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?![0-9])');
final RegExp _claudeOld = RegExp(r'claude-(\d{1,2})(?:-(\d{1,2}))?-([a-z]+)');

/// What a Claude model id is called: "Opus 5.5" for `claude-opus-5-5`, "Haiku 4.5" for
/// `claude-haiku-4-5-20251001`, "Sonnet 3.5" for the older `claude-3-5-sonnet-20241022`, with or
/// without a cloud's prefix and suffix around it. Null for anything that isn't one.
String? claudeModelName(String id) {
  String cap(String family) => family[0].toUpperCase() + family.substring(1);
  String version(String major, String? minor) => minor != null && minor.isNotEmpty ? '$major.$minor' : major;
  final now = _claudeNow.firstMatch(id);
  if (now != null) return '${cap(now[1]!)} ${version(now[2]!, now[3])}';
  final old = _claudeOld.firstMatch(id);
  return old != null ? '${cap(old[3]!)} ${version(old[1]!, old[2])}' : null;
}

const int openCodeModelMax = 256;
const int grokModelMax = 64;
const int museModelMax = 128;
const int piModelMax = 256;
const int cursorModelMax = 128;
const int codexModelMax = 128;

/// DeepSeek Harness model ids are opaque option ids from its live catalog (the `session/new`
/// configuration-option state), so the office cannot validate them syntactically the way it does
/// Claude aliases or OpenCode `provider/model` ids: it only bounds length and rejects control
/// characters. A stale saved id degrades at `session/new` instead of failing the launch.
const int dshModelMax = 256;

final RegExp _unsafe = RegExp(r'[\s\p{Cc}\p{Cf}]', unicode: true);
final RegExp _control = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);
final RegExp _openCodeProvider = RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$');
final RegExp _plainId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
final RegExp _codexId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]*$');
final RegExp _piId = RegExp(r'^[A-Za-z0-9._:/@+][A-Za-z0-9._:/@+-]*$');
final RegExp _cursorId = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]*(?:\[[A-Za-z0-9._-]+=[A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+=[A-Za-z0-9._-]+)*\])?$',
);

/// OpenCode model ids are argv values, so reject anything that could be ambiguous or unsafe.
bool isValidOpenCodeModel(Object? value) {
  if (value is! String || value.isEmpty || value.length > openCodeModelMax) return false;
  if (_unsafe.hasMatch(value)) return false;
  final parts = value.split('/');
  return parts.length >= 2 && _openCodeProvider.hasMatch(parts[0]) && parts.skip(1).every((part) => part.isNotEmpty);
}

/// Grok model ids are argv values (`grok-4.6`), so reject anything that could be ambiguous or unsafe.
bool isValidGrokModel(Object? value) {
  if (value is! String || value.isEmpty || value.length > grokModelMax) return false;
  if (_unsafe.hasMatch(value)) return false;
  return _plainId.hasMatch(value);
}

/// Muse model ids are argv values (`muse-spark-1.3-contributor`), so reject anything ambiguous or unsafe.
bool isValidMuseModel(Object? value) {
  if (value is! String || value.isEmpty || value.length > museModelMax) return false;
  if (_unsafe.hasMatch(value)) return false;
  return _plainId.hasMatch(value);
}

/// Codex model ids are argv values: its own (`gpt-5.5`), or a local provider's (`gpt-oss:20b`,
/// `openai/gpt-oss-20b`). Only the characters a model name uses get through, and never a leading '-'.
bool isValidCodexModel(Object? value) =>
    value is String && value.isNotEmpty && value.length <= codexModelMax && _codexId.hasMatch(value);

/// Pi takes model ids, fuzzy model names and provider/model patterns (`sonnet`, `openai/gpt-4.1`,
/// `sonnet:high`). They're argv values, and a Windows `.cmd` launcher runs them through cmd.exe, so
/// only the characters a model name uses get through, and never a leading '-'.
bool isValidPiModel(Object? value) =>
    value is String && value.isNotEmpty && value.length <= piModelMax && _piId.hasMatch(value);

/// Cursor model ids are argv values (`gpt-5`, `sonnet-4-thinking`), and a parameterized one carries
/// its overrides in brackets (`claude-opus-4-8[context=1m,effort=high]`). Only those characters get
/// through, and never a leading '-'.
bool isValidCursorModel(Object? value) =>
    value is String && value.length <= cursorModelMax && _cursorId.hasMatch(value);

/// DSH catalog ids are opaque, so only their length and control characters can be checked here.
bool isValidDshModel(Object? value) {
  if (value is! String || value.isEmpty || value.length > dshModelMax) return false;
  return !_control.hasMatch(value);
}

/// One model a provider offers, for the hire dialog: a fixed one, or one its own CLI lists.
class ModelOption {
  const ModelOption({required this.id, this.name, this.efforts});

  factory ModelOption.fromJson(Map<String, dynamic> j) => ModelOption(
    id: j['id'] is String ? j['id'] as String : '',
    name: j['name'] is String ? j['name'] as String : null,
    efforts: j['efforts'] is List ? [for (final e in j['efforts'] as List) ?AgentEffort.tryParse(e)] : null,
  );

  final String id;

  /// What it's called, when that's more than its id ("GPT-5.5", "Opus 5.5").
  final String? name;

  /// The reasoning efforts it takes, when its catalogue says: every one, when it doesn't.
  final List<AgentEffort>? efforts;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': ?name,
    if (efforts != null) 'efforts': [for (final e in efforts!) e.wire],
  };
}

/// How the hire dialog asks for a provider's model: picked from a list, or typed in.
enum ModelPick { list, typed }

/// How the hire dialog asks for a provider's model (see the client's provider UI).
class ModelField {
  const ModelField({
    required this.pick,
    this.fixed,
    this.catalog = false,
    required this.unset,
    this.max,
    required this.hint,
    this.invalid,
  });

  /// Picked from a list (the fixed ones, or its catalogue), or typed in, with its catalogue as suggestions.
  final ModelPick pick;

  /// The ones it always has (Claude Code's aliases).
  final List<ModelOption>? fixed;

  /// Its CLI lists them: the office asks it, at /api/agents/<provider>/models.
  final bool catalog;

  /// What leaving it alone gets: "Default (Grok settings)".
  final String unset;

  /// The longest id it takes, for a typed one.
  final int? max;

  /// The line under the fields.
  final String hint;

  /// What a typed id it turns down says.
  final String? invalid;
}

/// How a provider's spend shows on a worker's card, in the workers list and in the queue.
class ProviderUsage {
  const ProviderUsage({
    this.tracked = false,
    this.reports = false,
    this.noCost = false,
    this.waiting,
    required this.note,
  });

  /// Tracked from its start, numbers or not: the office reads them off its session itself.
  final bool tracked;

  /// It reports numbers of its own: until the first report comes in, it's waiting for one rather than untracked.
  final bool reports;

  /// Its reports leave the cost out unless they say it's known.
  final bool noCost;

  /// What it says while it waits for its first numbers.
  final String? waiting;

  /// The note under the provider picker.
  final String note;
}

class ProviderMeta {
  const ProviderMeta({
    required this.label,
    required this.name,
    this.bin,
    this.validModel,
    this.invalidModel,
    this.models,
    this.takesEffort = false,
    this.effortLabel,
    this.unpicked,
    required this.usage,
  });

  /// What the office's windows call it.
  final String label;

  /// What the server's messages and --help call it, where that's shorter ("Muse").
  final String name;

  /// The executable it runs as: an office started with `--agent <bin>` runs it. None for a custom --agent.
  final String? bin;

  /// Takes a model picked for each worker: which ids (they end up on its command line, so they're checked).
  final bool Function(Object? value)? validModel;

  /// What asking for a model [validModel] turns down says.
  final String? invalidModel;

  /// How the hire dialog asks for that model. A provider that takes one has this too (a test checks).
  final ModelField? models;

  /// Takes a reasoning effort picked for each worker.
  final bool takesEffort;

  /// What it calls its reasoning effort, when that isn't "Effort".
  final String? effortLabel;

  /// Why it has no model or effort to pick, for the hire dialog to say.
  final String? unpicked;

  /// How its spend shows on a worker's card, in the workers list and in the queue.
  final ProviderUsage usage;
}

/// What the office knows about each provider (TS PROVIDER_META).
final Map<AgentProvider, ProviderMeta> providerMetaTable = {
  AgentProvider.claude: ProviderMeta(
    label: 'Claude Code',
    name: 'Claude Code',
    bin: 'claude',
    validModel: isClaudeModel,
    invalidModel: 'Invalid Claude model (expected fable, opus, sonnet or haiku)',
    models: ModelField(
      pick: ModelPick.list,
      fixed: [for (final id in claudeModels) ModelOption(id: id, name: claudeModelNames[id])],
      unset: 'Default (--agent-args)',
      hint: 'The cost panel tracks each model separately.',
    ),
    takesEffort: true,
    usage: const ProviderUsage(tracked: true, note: 'Office usage and budget track Claude Code.'),
  ),
  AgentProvider.opencode: const ProviderMeta(
    label: 'OpenCode',
    name: 'OpenCode',
    bin: 'opencode',
    validModel: isValidOpenCodeModel,
    invalidModel: 'Invalid OpenCode model (expected provider/model without whitespace)',
    models: ModelField(
      pick: ModelPick.typed,
      catalog: true,
      unset: 'Default (OpenCode settings)',
      max: openCodeModelMax,
      hint: 'Optional provider/model: choose a suggestion or type one. Effort is the model’s variant in OpenCode.',
      invalid: 'Use provider/model format without whitespace or control characters (up to 256 characters).',
    ),
    takesEffort: true,
    usage: ProviderUsage(
      reports: true,
      waiting: 'waiting for metrics',
      note: 'OpenCode reports model/provider estimates; they are not billing, and arrive after the first report.',
    ),
  ),
  AgentProvider.codex: const ProviderMeta(
    label: 'Codex',
    name: 'Codex',
    bin: 'codex',
    validModel: isValidCodexModel,
    invalidModel: 'Invalid Codex model (expected a model id such as gpt-5.5, without whitespace)',
    models: ModelField(
      pick: ModelPick.list,
      catalog: true,
      unset: 'Default (Codex settings)',
      max: codexModelMax,
      hint: 'Optional model and effort for this worker.',
      invalid: 'Use a Codex model id without whitespace (up to 128 characters).',
    ),
    takesEffort: true,
    usage: ProviderUsage(
      reports: true,
      noCost: true,
      waiting: 'waiting for first report',
      note:
          'Review Office hooks in /hooks to enable tracking. Codex reports root-session tokens; subagents are excluded and cost is unavailable.',
    ),
  ),
  AgentProvider.grok: const ProviderMeta(
    label: 'Grok',
    name: 'Grok',
    bin: 'grok',
    validModel: isValidGrokModel,
    invalidModel: 'Invalid Grok model',
    models: ModelField(
      pick: ModelPick.list,
      catalog: true,
      unset: 'Default (Grok settings)',
      max: grokModelMax,
      hint: 'Optional model and effort for this worker.',
      invalid: 'Use a Grok model id without whitespace (up to 64 characters).',
    ),
    takesEffort: true,
    usage: ProviderUsage(note: 'Grok spend is not metered by the office; token totals stay in the worker terminal.'),
  ),
  AgentProvider.muse: const ProviderMeta(
    label: 'Muse Code',
    name: 'Muse',
    bin: 'muse',
    validModel: isValidMuseModel,
    invalidModel: 'Invalid Muse model',
    models: ModelField(
      pick: ModelPick.typed,
      unset: 'Default (Muse settings)',
      max: museModelMax,
      hint: 'Optional model id (for example muse-spark-1.3-contributor) and effort for this worker.',
      invalid: 'Use a Muse model id without whitespace or control characters (up to 128 characters).',
    ),
    takesEffort: true,
    usage: ProviderUsage(note: 'Muse spend is not metered by the office; token totals stay in the worker terminal.'),
  ),
  AgentProvider.dsh: const ProviderMeta(
    label: 'DeepSeek Harness',
    name: 'DeepSeek Harness',
    bin: 'dsh',
    validModel: isValidDshModel,
    invalidModel: 'Invalid DeepSeek Harness model (expected a catalog model id of up to 256 characters)',
    models: ModelField(
      pick: ModelPick.typed,
      unset: 'Default (DSH profile)',
      max: dshModelMax,
      hint: 'Optional model id from DeepSeek Harness’s catalog, and effort; leave empty to use the profile default.',
      invalid: 'Use a DeepSeek Harness catalog model id of up to 256 characters without control characters.',
    ),
    takesEffort: true,
    usage: ProviderUsage(
      reports: true,
      waiting: 'waiting for first report',
      note: 'DeepSeek Harness reports context usage over ACP after its first turn; cost may be unavailable.',
    ),
  ),
  AgentProvider.pi: const ProviderMeta(
    label: 'Pi',
    name: 'Pi',
    bin: 'pi',
    validModel: isValidPiModel,
    invalidModel: 'Invalid Pi model (expected a model name or provider/model without whitespace)',
    models: ModelField(
      pick: ModelPick.typed,
      unset: 'Default (Pi settings)',
      max: piModelMax,
      hint: 'Optional model name or provider/model; leave Default to use Pi settings.',
      invalid: 'Use a Pi model name or provider/model: letters, digits and . _ : / @ + - (up to 256 characters).',
    ),
    takesEffort: true,
    effortLabel: 'Thinking',
    usage: ProviderUsage(
      note:
          'Pi uses your existing Pi login and settings. Usage and cost stay in its terminal; the office does not meter them.',
    ),
  ),
  AgentProvider.cursor: const ProviderMeta(
    label: 'Cursor',
    name: 'Cursor',
    bin: 'cursor-agent',
    validModel: isValidCursorModel,
    invalidModel: 'Invalid Cursor model (expected a model id such as gpt-5, with any overrides in brackets)',
    models: ModelField(
      pick: ModelPick.typed,
      catalog: true,
      unset: 'Default (Cursor settings)',
      max: cursorModelMax,
      hint:
          'Optional model id; suggestions come from `cursor-agent models` once Cursor is signed in on the office machine. An effort goes in brackets after it: model[effort=high].',
      invalid:
          'Use a Cursor model id: letters, digits and . _ -, with any overrides in brackets, like model[effort=high] (up to 128 characters).',
    ),
    usage: ProviderUsage(
      note:
          'Cursor uses the Cursor CLI login on the office machine. Usage and cost stay in its terminal and your Cursor account; the office does not meter them.',
    ),
  ),
  AgentProvider.custom: const ProviderMeta(
    label: 'Custom',
    name: 'Custom',
    unpicked: 'A custom --agent runs as it is: set its model and effort in --agent-args.',
    usage: ProviderUsage(note: 'Usage is untracked unless compatible Claude Code hooks report it.'),
  ),
};

/// What the table says about [provider], when it's one (saved state and the wire can hold anything):
/// an [AgentProvider], or its wire spelling.
ProviderMeta? providerMeta(Object? provider) {
  final p = provider is AgentProvider ? provider : AgentProvider.tryParse(provider);
  return p == null ? null : providerMetaTable[p];
}

/// Whether a model can be picked for a worker on [provider].
bool takesModel(Object? provider) => providerMeta(provider)?.validModel != null;

/// Whether a reasoning effort can be picked for a worker on [provider].
bool takesEffort(Object? provider) => providerMeta(provider)?.takesEffort ?? false;

/// A saved model, when [provider] takes that one; for what workers.json or the queue kept, which may be from anywhere.
String? savedModel(Object? provider, Object? model) =>
    (providerMeta(provider)?.validModel?.call(model) ?? false) ? model as String : null;

/// A saved reasoning effort, when [provider] takes one.
AgentEffort? savedEffort(Object? provider, Object? effort) {
  if (!takesEffort(provider)) return null;
  return effort is AgentEffort ? effort : AgentEffort.tryParse(effort);
}

/// "a, b or c": the names of the providers that [has] holds for, in the table's order.
String providerNames(bool Function(ProviderMeta meta) has) {
  final names = [
    for (final p in AgentProvider.values)
      if (has(providerMetaTable[p]!)) providerMetaTable[p]!.name,
  ];
  return names.length > 1 ? '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}' : names.join();
}
