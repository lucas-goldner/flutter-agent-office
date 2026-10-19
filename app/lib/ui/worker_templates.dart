// Worker templates in the Hire dialog: workers kept to hire again, each a name, a first task (a skill,
// say "/write-log-design") and what it runs on. A tap fills the dialog in and the worker is hired under
// that name; ✏️ changes or removes one, ＋ keeps what's in the dialog as a new one. They're the office's
// (PromptsState.templates), the same for everyone.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:office_shared/protocol.dart';

import 'child_button.dart' show PromptField;
import 'modal.dart';
import 'prompt.dart' show WorktreeToggle;
import 'provider.dart';
import 'theme.dart';
import 'window_parts.dart' show BoxInput;

final _rng = math.Random();

/// A new template's id.
String newTemplateId() => 'tpl-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rng.nextInt(1 << 20)}';

/// [list] with [t] in place of the one with its id, or added at the end.
List<WorkerTemplate> putTemplate(List<WorkerTemplate> list, WorkerTemplate t) {
  final i = list.indexWhere((x) => x.id == t.id);
  return i < 0 ? [...list, t] : [...list.sublist(0, i), t, ...list.sublist(i + 1)];
}

/// The row of templates over the Hire dialog's prompt.
class WorkerTemplateBar extends StatelessWidget {
  const WorkerTemplateBar({
    super.key,
    required this.templates,
    required this.picked,
    required this.onPick,
    required this.onEdit,
    required this.onAdd,
  });

  final List<WorkerTemplate> templates;

  /// The one the dialog is filled in from, if any.
  final String? picked;
  final ValueChanged<WorkerTemplate?> onPick;
  final ValueChanged<WorkerTemplate> onEdit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '👷 Templates',
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w800),
        ),
        for (final t in templates)
          _Chip(
            key: ValueKey('tpl-${t.id}'),
            label: t.name,
            on: t.id == picked,
            tooltip: t.prompt.isEmpty ? 'Hire ${t.name}, with no first task' : t.prompt,
            onTap: () => onPick(t.id == picked ? null : t),
            onEdit: () => onEdit(t),
          ),
        Tooltip(
          message: "Keep what's in this dialog (its task, worker and worktree) as a template to hire again",
          child: InkWell(
            key: const ValueKey('tpl-add'),
            onTap: onAdd,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                '＋ Save as template',
                style: heavy(13, color: Swatch.accent, weight: FontWeight.w800),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.on,
    required this.tooltip,
    required this.onTap,
    required this.onEdit,
  });
  final String label;
  final bool on;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: on ? Swatch.accent : Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
              child: Text(label, style: heavy(13, color: on ? Colors.white : Swatch.ink)),
            ),
          ),
        ),
        Tooltip(
          message: 'Change or remove $label',
          child: InkWell(
            key: ValueKey('${(key as ValueKey<String>?)?.value}-edit'),
            onTap: onEdit,
            child: const Padding(
              padding: EdgeInsets.fromLTRB(2, 3, 8, 3),
              child: Text('✏️', style: TextStyle(fontSize: 12)),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Opens the editor for [template] (a new one when it isn't in the office's yet). [onSave] gets it back
/// changed; [onDelete], when given, removes it.
ModalHandle openTemplateEditor({
  required WorkerTemplate template,
  required ProjectInfo? project,
  required PromptsAgent? office,
  required bool worktreeOption,
  required ValueChanged<WorkerTemplate> onSave,
  VoidCallback? onDelete,
}) => ModalStack.instance.show(
  (m) => _TemplateEditor(
    modal: m,
    template: template,
    project: project,
    office: office,
    worktreeOption: worktreeOption,
    onSave: onSave,
    onDelete: onDelete,
  ),
);

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({
    required this.modal,
    required this.template,
    required this.project,
    required this.office,
    required this.worktreeOption,
    required this.onSave,
    this.onDelete,
  });
  final ModalHandle modal;
  final WorkerTemplate template;
  final ProjectInfo? project;
  final PromptsAgent? office;
  final bool worktreeOption;
  final ValueChanged<WorkerTemplate> onSave;
  final VoidCallback? onDelete;

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final _name = TextEditingController(text: widget.template.name);
  late final _prompt = TextEditingController(text: widget.template.prompt);
  late bool _worktree = widget.template.worktree;
  late final ProviderPickerController _agent = () {
    final c = ProviderPickerController(widget.project, office: widget.office);
    final a = widget.template.agent;
    if (a != null) {
      c.toggleEdit();
      c.set(a);
    }
    return c;
  }();
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _agent.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return setState(() => _problem = 'Give it a name: the worker is hired under it');
    if (name.runes.length > workerTemplateNameMax) {
      return setState(() => _problem = 'A name can be $workerTemplateNameMax characters at most');
    }
    if (!_agent.valid()) return;
    widget.modal.close();
    widget.onSave(
      WorkerTemplate(
        id: widget.template.id,
        name: name,
        prompt: _prompt.text.trim(),
        agent: _agent.editing ? _agent.choice() : null,
        worktree: widget.worktreeOption && _worktree,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ModalWindow(
    modal: widget.modal,
    title: Text(widget.onDelete == null ? '👷 New worker template' : '👷 ${widget.template.name}'),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Name',
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        BoxInput(
          key: const ValueKey('tpl-name'),
          controller: _name,
          hint: 'e.g. Log Designer',
          autofocus: true,
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 10),
        Text(
          'First task (a skill, or anything)',
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        PromptField(
          key: const ValueKey('tpl-prompt'),
          controller: _prompt,
          onSend: _save,
          hint: 'e.g. /write-log-design — leave empty to hire it idle',
          minLines: 4,
          autofocus: false,
        ),
        ProviderPicker(controller: _agent),
        if (widget.worktreeOption)
          WorktreeToggle(
            value: _worktree,
            onChanged: (v) => setState(() => _worktree = v),
            tooltip: 'Hire it on a branch of its own',
          ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _problem!,
              style: heavy(13, color: Swatch.bad, weight: FontWeight.w800),
            ),
          ),
      ],
    ),
    footer: Row(
      spacing: 8,
      children: [
        if (widget.onDelete != null)
          OfficeButton(
            key: const ValueKey('tpl-delete'),
            label: '🗑️ Remove',
            onPressed: () {
              widget.modal.close();
              widget.onDelete!();
            },
          ),
        const Spacer(),
        OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
        OfficeButton(key: const ValueKey('tpl-save'), label: 'Save', kind: BtnKind.primary, onPressed: _save),
      ],
    ),
  );
}
