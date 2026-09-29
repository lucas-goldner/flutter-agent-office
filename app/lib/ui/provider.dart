// Which agent a new worker runs (Claude Code, OpenCode, Codex or a custom command): the provider
// helpers and the picker from ui/provider.ts.

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/portable.dart';
import 'window_parts.dart' show SmallButton;
import '../net/api.dart';

import 'package:office_shared/protocol.dart';

import 'theme.dart';

const Map<AgentProvider, String> kProviderLabel = {
  AgentProvider.claude: 'Claude Code',
  AgentProvider.opencode: 'OpenCode',
  AgentProvider.codex: 'Codex',
  AgentProvider.custom: 'Custom',
};

/// Providers the server says this project can start.
List<AgentProvider> supportedProviders(ProjectInfo? project) {
  final values = project?.agentProviders ?? const [];
  if (values.isNotEmpty) return values.toSet().toList();
  return project != null ? [project.defaultProvider] : const [AgentProvider.claude];
}

/// Resolve old workers/tasks that have no provider metadata to the configured default.
AgentProvider resolvedProvider(AgentProvider? provider, ProjectInfo? project) {
  // A worker/task keeps its identity even if the office was later restarted with a
  // configuration that no longer offers that provider.
  if (provider != null) return provider;
  return project?.defaultProvider ?? supportedProviders(project).first;
}

String providerLabel(AgentProvider? provider, ProjectInfo? project) =>
    kProviderLabel[resolvedProvider(provider, project)]!;

const Map<String, String> kClaudeModelLabel = {'fable': 'Fable', 'opus': 'Opus', 'sonnet': 'Sonnet', 'haiku': 'Haiku'};

const Map<AgentEffort, String> kEffortLabel = {
  AgentEffort.low: 'Low',
  AgentEffort.medium: 'Medium',
  AgentEffort.high: 'High',
  AgentEffort.xhigh: 'Extra high',
  AgentEffort.max: 'Max',
};

/// A short badge for the task card / sidebar: "Opus", "Opus · High", or the raw OpenCode model id.
String? modelBadge(AgentProvider? provider, String? model, AgentEffort? effort) {
  if (model == null && effort == null) return null;
  if (provider == AgentProvider.claude) {
    final parts = [?kClaudeModelLabel[model], if (effort != null) kEffortLabel[effort]!];
    return parts.isEmpty ? null : parts.join(' · ');
  }
  return model;
}

/// The worker a new one starts on unless someone picks another: the one set in ⚙️ Settings
/// ([picked], from store.prompts.agent), or the office's --agent on its own default model.
AgentChoice officeChoice(ProjectInfo? project, PromptsAgent? picked) {
  if (picked != null && supportedProviders(project).contains(picked.provider)) {
    return AgentChoice(provider: picked.provider, model: picked.model, effort: picked.effort);
  }
  return AgentChoice(provider: resolvedProvider(project?.defaultProvider, project));
}

/// "Claude Code · Opus · High", "Claude Code", "OpenCode · anthropic/claude-sonnet-4".
String choiceLabel(AgentChoice c) {
  final badge = modelBadge(c.provider, c.model, c.effort);
  return badge == null ? kProviderLabel[c.provider]! : '${kProviderLabel[c.provider]} · $badge';
}

/// The same names, under the HUD's older spelling.
const Map<AgentProvider, String> providerNames = kProviderLabel;

bool providerUsageTracked(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) =>
    resolvedProvider(provider, project) == AgentProvider.claude || usage != null;

enum ProviderUsageState { tracked, waiting, untracked }

/// Distinguishes a provider with no first report from one whose metrics are intentionally unavailable.
ProviderUsageState providerUsageState(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) =>
    switch (resolvedProvider(provider, project)) {
      AgentProvider.claude ||
      AgentProvider.opencode ||
      AgentProvider.codex => usage != null ? ProviderUsageState.tracked : ProviderUsageState.waiting,
      AgentProvider.custom => usage != null ? ProviderUsageState.tracked : ProviderUsageState.untracked,
    };

String providerUsageNote(AgentProvider provider) => switch (provider) {
  AgentProvider.claude => 'Office usage and budget track Claude Code.',
  AgentProvider.codex => 'Review Office hooks in /hooks to enable tracking. Codex reports root-session tokens; subagents are excluded and cost is unavailable.',
  AgentProvider.custom => 'Usage is untracked unless compatible Claude Code hooks report it.',
  AgentProvider.opencode =>
    'OpenCode reports model/provider estimates; they are not billing, and arrive after the first report.',
};

AgentProvider _preferredProvider(List<AgentProvider> options, AgentProvider fallback) {
  final saved = AgentProvider.tryParse(storageGet(_providerKey));
  if (saved != null && options.contains(saved)) return saved;
  return options.contains(fallback) ? fallback : options.first;
}

/// The provider a picker would start on, for hiring without showing one (an issue card dropped on
/// a desk or the queue board): the one last picked anywhere, else the project's default.
AgentProvider rememberedProvider(ProjectInfo? project) =>
    _preferredProvider(supportedProviders(project), resolvedProvider(project?.defaultProvider, project));

const _providerKey = 'agent-office.provider';

const kModelMax = 256;
final _badChars = RegExp(r'[\s\p{Cc}\p{Cf}]', unicode: true);
final _modelHead = RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$');

/// An OpenCode model id: provider/model, no whitespace or control characters.
bool validModel(String value) {
  if (value.isEmpty || value.length > kModelMax || _badChars.hasMatch(value)) return false;
  final parts = value.split('/');
  return parts.length >= 2 && _modelHead.hasMatch(parts[0]) && parts.skip(1).every((p) => p.isNotEmpty);
}

List<String>? _modelList;
int _modelListAt = 0;
Future<List<String>>? _modelRequest;

Future<List<String>> fetchOpenCodeModels() {
  final list = _modelList;
  if (list != null && DateTime.now().millisecondsSinceEpoch - _modelListAt < 60000) return Future.value(list);
  return _modelRequest ??= () async {
    try {
      final res = await Api.getJson('/api/agents/opencode/models');
      if (!res.ok) throw Exception('HTTP ${res.status}');
      final models = res.body['models'];
      final valid = models is List
          ? [
              for (final m in models)
                if (m is String && validModel(m)) m,
            ]
          : <String>[];
      _modelList = valid.toSet().toList();
      _modelListAt = DateTime.now().millisecondsSinceEpoch;
      return _modelList!;
    } finally {
      _modelRequest = null;
    }
  }();
}

const _modelInvalid = 'Use provider/model format without whitespace or control characters (up to 256 characters).';

/// The picker's state, read by the window that owns it (providerPicker and agentFields in provider.ts).
///
/// As a picker ([fields] false) it starts on the office's default worker ([office], set in ⚙️
/// Settings, else the --agent) shown as a line, with ✏️ Edit opening the provider, model and effort
/// fields to pick another for this one. As [fields] it is those fields, always open (Settings).
class ProviderPickerController extends ChangeNotifier {
  ProviderPickerController(this.project, {PromptsAgent? office, this.fields = false})
    : options = supportedProviders(project),
      fallback = resolvedProvider(project?.defaultProvider, project) {
    _office = office;
    set(officeDefault);
  }

  final ProjectInfo? project;
  final List<AgentProvider> options;
  final AgentProvider fallback;
  final bool fields;
  late PromptsAgent? _office;
  bool _editing = false;
  late AgentProvider _selected;

  /// Claude's model alias ('' for the --agent-args default) and reasoning effort.
  String? _claudeModel;
  AgentEffort? _effort;
  final TextEditingController modelText = TextEditingController();
  String? _modelError;

  /// The worker a new one starts on unless someone picks another.
  AgentChoice get officeDefault => officeChoice(project, _office);

  /// Whether the office's default was picked in ⚙️ Settings (not just the --agent).
  bool get officePicked => _office != null;

  /// The office's default changed (someone saved another in Settings) while this is open.
  set office(PromptsAgent? o) {
    _office = o;
    if (!_editing && !fields) set(officeDefault);
    notifyListeners();
  }

  /// The fields are open: this one's picked here, not the office's default.
  bool get editing => fields || _editing;

  /// ✏️ Edit, and back to the default. The fields open on the default as it is now.
  void toggleEdit() {
    _editing = !_editing;
    set(officeDefault);
  }

  AgentProvider get selected => _selected;
  String? get claudeModel => _claudeModel;
  AgentEffort? get effortPicked => _effort;
  String? get modelError => _modelError;

  set selected(AgentProvider p) {
    _selected = p;
    _editing = true;
    // Remembered for hiring without a picker (rememberedProvider: a card dropped on a desk).
    if (options.contains(p)) storageSet(_providerKey, p.wire);
    notifyListeners();
  }

  set claudeModel(String? m) {
    _claudeModel = m == null || m.isEmpty || !claudeModels.contains(m) ? null : m;
    notifyListeners();
  }

  set effortPicked(AgentEffort? e) {
    _effort = e;
    notifyListeners();
  }

  /// Puts the fields on this provider, model and effort.
  void set(AgentChoice c) {
    _selected = options.contains(c.provider) ? c.provider : (options.contains(fallback) ? fallback : options.first);
    final claude = _selected == AgentProvider.claude;
    _claudeModel = claude && c.model != null && claudeModels.contains(c.model) ? c.model : null;
    _effort = claude ? c.effort : null;
    modelText.text = _selected == AgentProvider.opencode ? (c.model ?? '') : '';
    _modelError = null;
    notifyListeners();
  }

  AgentProvider value() {
    if (!editing) return officeDefault.provider;
    return options.contains(_selected) ? _selected : fallback;
  }

  /// The optional initial model override: an OpenCode provider/model id (empty or invalid input is
  /// omitted), or a Claude model alias.
  String? model() {
    if (!editing) return officeDefault.model;
    if (_selected == AgentProvider.claude) return _claudeModel;
    if (_selected != AgentProvider.opencode) return null;
    final v = modelText.text;
    return validModel(v) ? v : null;
  }

  /// The optional Claude reasoning effort.
  AgentEffort? effort() {
    if (!editing) return officeDefault.effort;
    return _selected == AgentProvider.claude ? _effort : null;
  }

  AgentChoice choice() => AgentChoice(provider: value(), model: model(), effort: effort());

  /// Reports a visible field error for an invalid nonempty OpenCode model.
  bool valid() {
    if (!editing || _selected != AgentProvider.opencode || modelText.text.isEmpty) {
      _setError(null);
      return true;
    }
    final okay = validModel(modelText.text);
    _setError(okay ? null : _modelInvalid);
    return okay;
  }

  void _setError(String? e) {
    if (e == _modelError) return;
    _modelError = e;
    notifyListeners();
  }

  void clearError() => _setError(null);

  @override
  void dispose() {
    modelText.dispose();
    super.dispose();
  }
}

/// Which worker to start: the office's default as a line with ✏️ Edit, or (editing, or as
/// Settings' fields) a provider selector that never offers a provider outside the server's
/// metadata, with the model (and for Claude, the reasoning effort) under it. [compact] lays the
/// pieces out in one line under a prompt, as the queue's add form does.
class ProviderPicker extends StatefulWidget {
  const ProviderPicker({super.key, required this.controller, this.label = 'Worker', this.compact = false});

  final ProviderPickerController controller;
  final String label;
  final bool compact;

  @override
  State<ProviderPicker> createState() => _ProviderPickerState();
}

class _ProviderPickerState extends State<ProviderPicker> {
  List<String> _models = const [];
  String _hint = 'Optional provider/model override; suggestions load when OpenCode is selected.';
  AgentProvider? _loadedFor;

  ProviderPickerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _loadModels();
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _loadModels();
    if (mounted) setState(() {});
  }

  void _loadModels() {
    if (!c.editing || c.selected != AgentProvider.opencode) {
      _loadedFor = null;
      return;
    }
    if (_loadedFor == AgentProvider.opencode) return;
    _loadedFor = AgentProvider.opencode;
    _hint = _modelList != null
        ? 'Optional provider/model override; choose a suggestion or enter one manually.'
        : 'Loading OpenCode models… You can enter a provider/model manually.';
    fetchOpenCodeModels().then(
      (models) {
        if (!mounted) return;
        setState(() {
          _models = models;
          _hint = 'Optional provider/model override; choose a suggestion or enter one manually.';
        });
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() => _hint = 'Model suggestions unavailable; enter a provider/model manually if needed.');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final def = c.officeDefault;
    final muted = heavy(11, color: Swatch.muted, weight: FontWeight.w700);
    final summary = c.fields
        ? null
        : Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(widget.label, style: heavy(widget.compact ? 13 : 14)),
              if (!c.editing)
                Tooltip(
                  message: c.officePicked
                      ? 'The office’s default worker, set in ⚙️ Settings'
                      : 'The office’s default worker (its --agent); an admin can pick another in ⚙️ Settings',
                  child: Text(
                    choiceLabel(def),
                    key: const ValueKey('provider-current'),
                    style: heavy(13, weight: FontWeight.w700),
                  ),
                ),
              SmallButton(
                key: const ValueKey('provider-edit'),
                label: c.editing ? '↺ Use the default' : '✏️ Edit',
                tooltip: c.editing
                    ? 'Back to ${choiceLabel(def)}'
                    : 'Pick another provider, model or effort for this one',
                onPressed: c.toggleEdit,
              ),
            ],
          );
    if (!c.editing) return Padding(padding: const EdgeInsets.only(top: 10), child: summary);
    final label = Text(c.fields ? widget.label : 'Provider', style: heavy(13));
    final select = _Select<AgentProvider>(
      key: const ValueKey('provider-select'),
      options: [for (final p in c.options) (p, kProviderLabel[p]!)],
      value: c.selected,
      onChanged: (p) => c.selected = p,
    );
    final pieces = <Widget>[
      label,
      select,
      if (c.selected == AgentProvider.claude) ...[
        Text('Model', style: heavy(13)),
        _Select<String>(
          key: const ValueKey('claude-model'),
          options: [('', 'Default (--agent-args)'), for (final m in claudeModels) (m, kClaudeModelLabel[m]!)],
          value: c.claudeModel ?? '',
          onChanged: (m) => c.claudeModel = m,
        ),
        Text('Effort', style: heavy(13)),
        _Select<AgentEffort?>(
          key: const ValueKey('claude-effort'),
          options: [(null, 'Default'), for (final e in AgentEffort.values) (e, kEffortLabel[e]!)],
          value: c.effortPicked,
          onChanged: (e) => c.effortPicked = e,
        ),
      ],
      if (c.selected == AgentProvider.opencode) ...[
        Text('OpenCode model', style: heavy(13)),
        SizedBox(
          width: widget.compact ? 220 : 300,
          child: _ModelField(controller: c, models: _models),
        ),
      ],
    ];
    final notes = <Widget>[
      Text(providerUsageNote(c.selected), style: muted),
      if (c.selected == AgentProvider.claude) Text('The cost panel tracks each model separately.', style: muted),
      if (c.selected == AgentProvider.opencode)
        Text(
          c.modelError ?? _hint,
          style: heavy(11, color: c.modelError != null ? Swatch.bad : Swatch.muted, weight: FontWeight.w700),
        ),
    ];
    return Padding(
      padding: EdgeInsets.only(top: widget.compact ? 8 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          ?summary,
          // The provider, model and effort on one line (they wrap, a label with its picker, when narrow).
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: pieces),
          ...notes,
        ],
      ),
    );
  }
}

/// A small select box: white, with a 2px ink border (.provider-select). Its list is a MenuAnchor,
/// which draws over the window it's in (a DropdownButton's route would open under the modal).
class _Select<T> extends StatelessWidget {
  const _Select({super.key, required this.options, required this.value, required this.onChanged});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = options.firstWhere((o) => o.$1 == value, orElse: () => options.first);
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: const BorderSide(color: Swatch.ink, width: 2),
          ),
        ),
      ),
      menuChildren: [
        for (final (v, label) in options)
          MenuItemButton(
            onPressed: () => onChanged(v),
            child: Text(label, style: heavy(13, weight: v == value ? FontWeight.w900 : FontWeight.w700)),
          ),
      ],
      builder: (context, menu, _) => InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
        child: Container(
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Swatch.ink, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(current.$2, style: heavy(13)),
              const SizedBox(width: 6),
              Text('▾', style: heavy(12, color: Swatch.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The model box with its suggestions (the <datalist> of the old picker).
class _ModelField extends StatefulWidget {
  const _ModelField({required this.controller, required this.models});

  final ProviderPickerController controller;
  final List<String> models;

  @override
  State<_ModelField> createState() => _ModelFieldState();
}

class _ModelFieldState extends State<_ModelField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final models = widget.models;
    OutlineInputBorder box(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: c, width: 2),
    );
    final bad = controller.modelError != null;
    return RawAutocomplete<String>(
      textEditingController: controller.modelText,
      focusNode: _focus,
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        return models.where((m) => m.toLowerCase().contains(q)).take(50);
      },
      fieldViewBuilder: (context, text, focus, onSubmit) => TextField(
        controller: text,
        focusNode: focus,
        maxLength: kModelMax,
        autocorrect: false,
        style: heavy(13, weight: FontWeight.w600),
        onChanged: (_) => controller.clearError(),
        decoration: InputDecoration(
          counterText: '',
          hintText: 'Default (OpenCode settings)',
          contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          border: box(bad ? Swatch.bad : Swatch.ink),
          enabledBorder: box(bad ? Swatch.bad : Swatch.ink),
          focusedBorder: box(bad ? Swatch.bad : Swatch.accent),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 300),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in options)
                  InkWell(
                    onTap: () => onSelected(o),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(o, style: heavy(13, weight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
