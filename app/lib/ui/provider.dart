// Which agent a new worker runs, and on what model and effort (ui/provider.ts, #79 #88 #272 and the new
// harnesses): the provider helpers, each provider's models as its CLI lists them, and the picker. What each
// provider takes, and how its model is asked for, is its row in office_shared's provider table
// (providers.dart), so a provider added there gets its fields here.

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/portable.dart';
import 'window_parts.dart' show SmallButton;
import '../net/api.dart';

import 'package:office_shared/protocol.dart';
import 'package:office_shared/providers.dart';

import 'theme.dart';

final Map<AgentProvider, String> kProviderLabel = {
  for (final p in AgentProvider.values) p: providerMetaTable[p]!.label,
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

/// Claude Code's aliases by name: "Opus 5.5".
const Map<String, String> kClaudeModelLabel = claudeModelNames;

const Map<AgentEffort, String> kEffortLabel = {
  AgentEffort.low: 'Low',
  AgentEffort.medium: 'Medium',
  AgentEffort.high: 'High',
  AgentEffort.xhigh: 'Extra high',
  AgentEffort.max: 'Max',
};

/// Claude Code's models go by their names, and so does a custom --agent's, which is read the same way.
bool _namesClaude(AgentProvider? provider) => provider == AgentProvider.claude || provider == AgentProvider.custom;

/// What a model is called: "Opus 5.5" for Claude Code's `opus` or `claude-opus-5-5`, and the id itself for
/// the others.
String modelName(AgentProvider? provider, String model) {
  if (!_namesClaude(provider)) return model;
  return claudeModelNames[model] ?? claudeModelName(model) ?? model;
}

/// A short badge for the task card / sidebar: "Opus 5.5", "Opus 5.5 · High", "gpt-5.5 · High". [runs] is the
/// model its session says it's on (Usage.model): for Claude Code that's surer than what an alias stands for,
/// and it's there for a worker left on the default too.
String? modelBadge(AgentProvider? provider, String? model, AgentEffort? effort, [String? runs]) {
  final id = _namesClaude(provider) ? (runs ?? model) : (model ?? runs);
  final parts = [
    if (id != null && id.isNotEmpty) modelName(provider, id),
    if (effort != null && takesEffort(provider)) kEffortLabel[effort]!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// What a worker runs, in a line: "Claude Code · Opus 5.5 · High", or only "Codex" for one on its defaults
/// that hasn't said.
String engineLabel(WorkerInfo w, ProjectInfo? project) {
  final badge = modelBadge(w.provider, w.model, w.effort, w.usage?.model);
  final label = providerLabel(w.provider, project);
  return badge != null ? '$label · $badge' : label;
}

/// The worker a new one starts on unless someone picks another: the one set in ⚙️ Settings
/// ([picked], from store.prompts.agent), or the office's --agent on its own default model.
AgentChoice officeChoice(ProjectInfo? project, PromptsAgent? picked) {
  if (picked != null && supportedProviders(project).contains(picked.provider)) {
    return AgentChoice(provider: picked.provider, model: picked.model, effort: picked.effort);
  }
  return AgentChoice(provider: resolvedProvider(project?.defaultProvider, project));
}

/// "Claude Code · Opus 5.5 · High", "Claude Code", "OpenCode · anthropic/claude-sonnet-4", "Grok · grok-4.6".
String choiceLabel(AgentChoice c) {
  final badge = modelBadge(c.provider, c.model, c.effort);
  return badge == null ? kProviderLabel[c.provider]! : '${kProviderLabel[c.provider]} · $badge';
}

/// The same names, under the HUD's older spelling.
final Map<AgentProvider, String> providerNamesByProvider = kProviderLabel;

bool providerUsageTracked(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) =>
    providerMetaTable[resolvedProvider(provider, project)]!.usage.tracked || usage != null;

enum ProviderUsageState { tracked, waiting, untracked }

/// Distinguishes a provider with no first report from one whose metrics are intentionally unavailable.
ProviderUsageState providerUsageState(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) {
  final u = providerMetaTable[resolvedProvider(provider, project)]!.usage;
  if (usage != null) return ProviderUsageState.tracked;
  return u.tracked || u.reports ? ProviderUsageState.waiting : ProviderUsageState.untracked;
}

/// The short "no numbers yet" suffix for a tracked-but-silent provider, shared by the terminal, the workers
/// list and the queue so all three say the same thing.
String providerWaitingLabel(AgentProvider? provider, ProjectInfo? project) =>
    providerMetaTable[resolvedProvider(provider, project)]!.usage.waiting ?? '';

String providerUsageNote(AgentProvider provider) => providerMetaTable[provider]!.usage.note;

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

/// The longest OpenCode model id (kept for the older callers).
const kModelMax = openCodeModelMax;

/// An OpenCode model id: provider/model, no whitespace or control characters.
bool validModel(String value) => isValidOpenCodeModel(value);

// ---- Each provider's models, as its CLI lists them ------------------------------------------------

/// A provider's models as its CLI listed them, kept a minute; one that couldn't be listed isn't asked again
/// for as long.
class _Catalogue {
  List<ModelOption>? list;
  bool failed = false;
  int at = 0;
  Future<void>? request;
}

final Map<AgentProvider, _Catalogue> _catalogues = {};
const int _catalogueTtlMs = 60000;

/// What the office's `GET /api/agents/<provider>/models` said, as the models [provider] takes (no repeats).
/// An older office listed OpenCode's as plain ids.
List<ModelOption> parseModels(AgentProvider provider, Object? body) {
  final valid = providerMetaTable[provider]!.validModel;
  final models = body is Map ? body['models'] : null;
  final seen = <String>{};
  return [
    if (models is List)
      for (final m in models)
        if (m is String ? ModelOption(id: m) : (m is Map<String, dynamic> ? ModelOption.fromJson(m) : null)
            case final ModelOption o when valid != null && valid(o.id) && seen.add(o.id))
          o,
  ];
}

/// Asks for [provider]'s models, unless what's here is fresh: then there's nothing to wait for.
Future<void>? loadCatalogue(AgentProvider provider) {
  final c = _catalogues.putIfAbsent(provider, _Catalogue.new);
  if ((c.list != null || c.failed) && DateTime.now().millisecondsSinceEpoch - c.at < _catalogueTtlMs) return null;
  return c.request ??= () async {
    try {
      final res = await Api.getJson('/api/agents/${provider.wire}/models');
      if (!res.ok) throw Exception('HTTP ${res.status}');
      c.list = parseModels(provider, res.body);
      c.failed = false;
    } catch (_) {
      c.failed = true;
    } finally {
      c.at = DateTime.now().millisecondsSinceEpoch;
      c.request = null;
    }
  }();
}

/// The models [provider]'s catalogue has now, or null.
List<ModelOption>? catalogueOf(AgentProvider provider) => _catalogues[provider]?.list;

/// For tests: what [provider]'s CLI listed, or that it couldn't.
@visibleForTesting
void setCatalogue(AgentProvider provider, {List<ModelOption>? list, bool failed = false}) {
  _catalogues[provider] = _Catalogue()
    ..list = list
    ..failed = failed
    ..at = DateTime.now().millisecondsSinceEpoch;
}

/// OpenCode's models by id, for the older callers.
Future<List<String>> fetchOpenCodeModels() async {
  await loadCatalogue(AgentProvider.opencode);
  return [for (final m in catalogueOf(AgentProvider.opencode) ?? const <ModelOption>[]) m.id];
}

// ---- The picker ---------------------------------------------------------------------------------

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
  bool _disposed = false;

  /// The model id the fields are on, whichever control is showing ('' for the provider's default).
  String _chosen = '';
  AgentEffort? _effort;

  /// The typed model, for a provider whose model is typed in (and one whose list couldn't be had).
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
  ProviderMeta get meta => providerMetaTable[_selected]!;
  String? get modelError => _modelError;

  /// Its models: the ones it always has, or the ones its CLI listed.
  List<ModelOption> get known => meta.models?.fixed ?? catalogueOf(_selected) ?? const [];

  /// Its catalogue is being asked for, or couldn't be had.
  bool get loading => (meta.models?.catalog ?? false) && _catalogues[_selected]?.request != null;
  bool get listFailed => (meta.models?.catalog ?? false) && (_catalogues[_selected]?.failed ?? false);

  /// Typed in: for a provider whose model is, and for one whose list couldn't be had.
  bool get typed => meta.models?.pick == ModelPick.typed || listFailed;

  /// The model the fields are on ('' for the default).
  String get chosen => _chosen;

  /// Another provider: its own defaults, since another's model and effort mean nothing to it.
  set selected(AgentProvider p) {
    _editing = true;
    set(AgentChoice(provider: p));
    // Remembered for hiring without a picker (rememberedProvider: a card dropped on a desk).
    if (options.contains(p)) storageSet(_providerKey, p.wire);
  }

  /// Picks a model from the list ('' for the default).
  set chosen(String id) {
    _chosen = id;
    if (modelText.text.trim() != id) modelText.text = id;
    _modelError = null;
    _fitEffort();
    notifyListeners();
  }

  /// Claude Code's alias, under the older name.
  String? get claudeModel => _selected == AgentProvider.claude && _chosen.isNotEmpty ? _chosen : null;
  set claudeModel(String? m) => chosen = (m != null && isClaudeModel(m)) ? m : '';

  AgentEffort? get effortPicked => _effort;
  set effortPicked(AgentEffort? e) {
    _effort = e;
    _fitEffort();
    notifyListeners();
  }

  /// The efforts on offer: the ones the model picked takes, where its catalogue says (null: every one).
  List<AgentEffort>? get efforts => known.where((o) => o.id == _chosen).firstOrNull?.efforts;

  /// An effort the model picked doesn't take goes back to the default.
  void _fitEffort() {
    final e = efforts;
    if (_effort != null && e != null && !e.contains(_effort)) _effort = null;
  }

  /// Puts the fields on this provider, model and effort.
  void set(AgentChoice c) {
    _selected = options.contains(c.provider) ? c.provider : (options.contains(fallback) ? fallback : options.first);
    final mine = _selected == c.provider;
    final m = c.model;
    _chosen = mine && m != null && (meta.validModel?.call(m) ?? false) ? m : '';
    modelText.text = _chosen;
    _effort = mine && meta.takesEffort ? c.effort : null;
    _modelError = null;
    _fitEffort();
    notifyListeners();
    load();
  }

  /// Asks the provider's CLI for its models (once someone can see the fields: the picker calls it).
  void load() {
    if (!editing || !(meta.models?.catalog ?? false)) return;
    final provider = _selected;
    final loading = loadCatalogue(provider);
    if (loading == null) return;
    notifyListeners();
    loading.then((_) {
      if (_disposed || _selected != provider) return;
      _fitEffort();
      notifyListeners();
    });
  }

  AgentProvider value() {
    if (!editing) return officeDefault.provider;
    return options.contains(_selected) ? _selected : fallback;
  }

  String get _id => typed ? modelText.text.trim() : _chosen;

  /// The model picked for it, when one was: an id its provider takes (a Claude Code alias, an OpenCode
  /// provider/model, a Codex model).
  String? model() {
    if (!editing) return officeDefault.model;
    final id = _id;
    return id.isNotEmpty && (meta.validModel?.call(id) ?? false) ? id : null;
  }

  /// The reasoning effort picked for it, when one was (Pi calls it thinking).
  AgentEffort? effort() {
    if (!editing) return officeDefault.effort;
    if (!meta.takesEffort || _effort == null) return null;
    final e = typed ? known.where((o) => o.id == _id).firstOrNull?.efforts : efforts;
    return e == null || e.contains(_effort) ? _effort : null;
  }

  AgentChoice choice() => AgentChoice(provider: value(), model: model(), effort: effort());

  /// Reports a visible field error for a typed model its provider doesn't take.
  bool valid() {
    final id = _id;
    if (!editing || id.isEmpty) {
      _setError(null);
      return true;
    }
    final okay = meta.validModel?.call(id) ?? false;
    _setError(okay ? null : (meta.models?.invalid ?? 'That isn’t a model id this provider takes.'));
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
    _disposed = true;
    modelText.dispose();
    super.dispose();
  }
}

/// Which worker to start: the office's default as a line with ✏️ Edit, or (editing, or as Settings' fields) a
/// provider selector that never offers a provider outside the server's metadata, with the model and effort
/// its row in the provider table takes under it. [compact] lays the pieces out in one line under a prompt,
/// as the queue's add form does.
class ProviderPicker extends StatefulWidget {
  const ProviderPicker({super.key, required this.controller, this.label = 'Worker', this.compact = false});

  final ProviderPickerController controller;
  final String label;
  final bool compact;

  @override
  State<ProviderPicker> createState() => _ProviderPickerState();
}

class _ProviderPickerState extends State<ProviderPicker> {
  ProviderPickerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    // Fields put on their provider before anyone could see them ask once they're on the page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.load();
    });
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The line under the fields.
  String _hint() {
    final m = c.meta;
    final field = m.models;
    if (field == null) return m.unpicked ?? '';
    if (c.loading) return 'Loading ${m.label} models…';
    if (c.listFailed) {
      return '${m.label}’s models couldn’t be listed: leave it empty for its default, or type a model id.';
    }
    return field.hint;
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
    final m = c.meta;
    final field = m.models;
    final label = Text(c.fields ? widget.label : 'Provider', style: heavy(13));
    final select = OfficeSelect<AgentProvider>(
      key: const ValueKey('provider-select'),
      options: [for (final p in c.options) (p, kProviderLabel[p]!)],
      value: c.selected,
      onChanged: (p) => c.selected = p,
    );
    final known = c.known;
    final allowed = c.efforts;
    final pieces = <Widget>[
      label,
      select,
      if (field != null) ...[
        Text('Model', style: heavy(13)),
        if (c.typed)
          SizedBox(
            width: widget.compact ? 220 : 300,
            child: _ModelField(controller: c, models: known),
          )
        else
          OfficeSelect<String>(
            key: const ValueKey('provider-model'),
            options: [
              ('', field.unset),
              for (final o in known) (o.id, o.name ?? o.id),
              // A saved one, or the list is still on its way.
              if (c.chosen.isNotEmpty && !known.any((o) => o.id == c.chosen)) (c.chosen, c.chosen),
            ],
            value: c.chosen,
            onChanged: (id) => c.chosen = id,
          ),
      ],
      if (m.takesEffort) ...[
        Text(m.effortLabel ?? 'Effort', style: heavy(13)),
        Tooltip(
          message: allowed != null && allowed.isEmpty ? 'This model has no reasoning effort to pick' : '',
          child: OfficeSelect<AgentEffort?>(
            key: const ValueKey('provider-effort'),
            options: [
              (null, 'Default'),
              for (final e in AgentEffort.values)
                if (allowed == null || allowed.contains(e)) (e, kEffortLabel[e]!),
            ],
            value: c.effortPicked,
            onChanged: (e) => c.effortPicked = e,
          ),
        ),
      ],
    ];
    final hint = _hint();
    final notes = <Widget>[
      Text(providerUsageNote(c.selected), style: muted),
      if (c.modelError != null)
        Text(
          c.modelError!,
          style: heavy(11, color: Swatch.bad, weight: FontWeight.w700),
        )
      else if (hint.isNotEmpty)
        Text(hint, key: const ValueKey('provider-hint'), style: muted),
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
class OfficeSelect<T> extends StatelessWidget {
  const OfficeSelect({super.key, required this.options, required this.value, required this.onChanged});

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
  final List<ModelOption> models;

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
    final field = controller.meta.models;
    OutlineInputBorder box(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: c, width: 2),
    );
    final bad = controller.modelError != null;
    return RawAutocomplete<ModelOption>(
      key: const ValueKey('provider-model-text'),
      textEditingController: controller.modelText,
      focusNode: _focus,
      displayStringForOption: (o) => o.id,
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        return models
            .where((m) => m.id.toLowerCase().contains(q) || (m.name?.toLowerCase().contains(q) ?? false))
            .take(50);
      },
      onSelected: (o) => controller.chosen = o.id,
      fieldViewBuilder: (context, text, focus, onSubmit) => TextField(
        controller: text,
        focusNode: focus,
        maxLength: field?.max ?? 256,
        autocorrect: false,
        style: heavy(13, weight: FontWeight.w600),
        onChanged: (_) => controller.clearError(),
        decoration: InputDecoration(
          counterText: '',
          hintText: field?.unset ?? '',
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
                      child: Text(
                        o.name != null && o.name != o.id ? '${o.name} · ${o.id}' : o.id,
                        style: heavy(13, weight: FontWeight.w600),
                      ),
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
