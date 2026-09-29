// The office's own prompts (ui/prompts.ts, #137): what the boards' buttons send workers, the
// queue's worktree note, the board agents' briefs, the meeting room's parts and the sign writer's
// instructions. A list down the side, grouped by where they're used; the one picked on the right,
// with its placeholders. Admins rewrite them for the whole office; everyone else reads them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:office_shared/prompts.dart';
import 'package:office_shared/protocol.dart';

import '../office_scope.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// One of the office's prompts as it has it now (rewritten in ⚙️ Settings, or the default), filled in.
String officePrompt(Store store, PromptId id, [PromptVars vars = const {}]) =>
    fillPrompt(promptText(store.prompts.custom, id), vars);

/// How many of the office's prompts someone rewrote.
int rewrittenPrompts(Store store) => store.prompts.custom.length;

/// As the office keeps it: Windows line ends and outer whitespace don't count.
String normPrompt(String text) => text.replaceAll(RegExp(r'\r\n?'), '\n').trim();

/// What the editor warns about a prompt's text: an empty one that can't be, placeholders that aren't
/// filled in there, and the ones the office counts on that are missing.
List<String> promptWarnings(PromptId id, String text) {
  final def = prompts[id]!;
  final inText = placeholders(text);
  return [
    if (text.trim().isEmpty && !def.optional) 'It can’t be empty: write something, or put the default back.',
    for (final name in inText)
      if (!def.vars.containsKey(name)) '{{$name}} isn’t filled in here, so it’s sent just as it’s written.',
    for (final name in def.needs)
      if (!inText.contains(name))
        'The office counts on {{$name}} (${def.vars[name]!.toLowerCase()}): without it the worker isn’t told.',
  ];
}

/// What you typed and haven't saved, by prompt: kept while the page is open, so closing the window
/// by mistake doesn't lose it.
final Map<PromptId, String> _drafts = {};

/// The prompts, in their groups' order.
List<(PromptGroup, List<PromptId>)> promptSections() => [
  for (final g in promptGroups.keys)
    (
      g,
      [
        for (final id in promptIds)
          if (prompts[id]!.group == g) id,
      ],
    ),
];

ModalHandle openPromptEditor(OfficeScope scope, {PromptId? first}) => ModalStack.instance.show(
  (modal) => _PromptEditor(scope: scope, modal: modal, first: first ?? promptIds.first),
  // A click beside it shouldn't throw away what you're writing.
  backdropCloses: false,
);

class _PromptEditor extends StatefulWidget {
  const _PromptEditor({required this.scope, required this.modal, required this.first});

  final OfficeScope scope;
  final ModalHandle modal;
  final PromptId first;

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> with ListenTo {
  late PromptId _current = widget.first;
  final _text = TextEditingController();
  final _focus = FocusNode();

  Store get store => widget.scope.store;
  String _saved(PromptId id) => promptText(store.prompts.custom, id);
  bool _dirty(PromptId id) => _drafts.containsKey(id) && normPrompt(_drafts[id]!) != _saved(id);

  @override
  void initState() {
    super.initState();
    _text.text = _drafts[_current] ?? _saved(_current);
    // Saved, here or by someone else: a draft that now matches is done with, and a prompt you haven't
    // touched shows what it says now.
    listenTo(store.topic(Topic.prompts), () {
      _drafts.removeWhere((id, d) => normPrompt(d) == _saved(id));
      if (!_drafts.containsKey(_current) && _text.text != _saved(_current)) _text.text = _saved(_current);
      setState(() {});
    });
    listenTo(store.topic(Topic.me), () => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _pick(PromptId id) => setState(() {
    _current = id;
    _text.text = _drafts[id] ?? _saved(id);
  });

  void _edited(String v) => setState(() {
    if (normPrompt(v) == _saved(_current)) {
      _drafts.remove(_current);
    } else {
      _drafts[_current] = v;
    }
  });

  void _insert(String token) {
    final sel = _text.selection;
    final v = _text.text;
    final a = sel.isValid ? sel.start : v.length;
    final b = sel.isValid ? sel.end : v.length;
    _text.value = TextEditingValue(
      text: v.replaceRange(a, b, token),
      selection: TextSelection.collapsed(offset: a + token.length),
    );
    _focus.requestFocus();
    _edited(_text.text);
  }

  void _save() {
    if (!_dirty(_current)) return;
    final value = normPrompt(_text.text);
    widget.scope.net.send(PromptsSetCmd(_current, value == prompts[_current]!.text ? null : value));
  }

  @override
  Widget build(BuildContext context) {
    final admin = store.me.admin;
    final def = prompts[_current]!;
    final edit = store.prompts.custom[_current];
    final dirty = _dirty(_current);
    final muted = heavy(12, color: Swatch.muted, weight: FontWeight.w700);
    return ModalWindow(
      modal: widget.modal,
      width: 980,
      height: 680,
      scrollBody: false,
      title: const Text('📝 Prompts'),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 250,
            child: ListView(
              children: [
                for (final (g, ids) in promptSections()) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                    child: Text(
                      promptGroups[g]!,
                      style: heavy(12, color: Swatch.muted, weight: FontWeight.w900),
                    ),
                  ),
                  for (final id in ids) _item(id),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(def.label, style: heavy(17, weight: FontWeight.w900)),
                    ),
                    Text(
                      dirty
                          ? '● Not saved yet'
                          : edit != null
                          ? '✎ Rewritten by ${edit.by} ${timeAgo(edit.at)}'
                          : 'The default',
                      style: heavy(12, color: dirty ? Swatch.accent : Swatch.muted),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text(def.used + (def.optional ? ' Leave it empty to send nothing.' : ''), style: muted),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('prompt-text'),
                    controller: _text,
                    focusNode: _focus,
                    readOnly: !admin,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    inputFormatters: [LengthLimitingTextInputFormatter(promptMax)],
                    style: const TextStyle(fontFamily: kMono, fontFamilyFallback: kMonoFallback, fontSize: 13),
                    onChanged: _edited,
                    decoration: const InputDecoration(contentPadding: EdgeInsets.all(10)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: def.vars.isEmpty
                        ? [Text('No placeholders: it’s sent just as it’s written.', style: muted)]
                        : [
                            Text(admin ? 'Placeholders (click one to put it in):' : 'Placeholders:', style: muted),
                            for (final e in def.vars.entries)
                              SmallButton(
                                key: ValueKey('var-${e.key}'),
                                label: '{{${e.key}}}',
                                tooltip: e.value,
                                onPressed: admin ? () => _insert('{{${e.key}}}') : null,
                              ),
                          ],
                  ),
                ),
                for (final w in promptWarnings(_current, _text.text))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('⚠️ $w', style: heavy(12, color: Swatch.bad)),
                  ),
              ],
            ),
          ),
        ],
      ),
      footer: Row(
        spacing: 8,
        children: [
          FooterNote(
            admin
                ? 'For the whole office, on every floor. A rewritten prompt is used from the next time it’s sent.'
                : 'Only admins can change the office’s prompts. This is what they say now.',
          ),
          if (admin) ...[
            OfficeButton(
              label: '↺ Default',
              tooltip: 'Put the office’s own wording back in the box (then Save)',
              onPressed: normPrompt(_text.text) == def.text
                  ? null
                  : () {
                      _text.text = def.text;
                      _edited(def.text);
                    },
            ),
            if (dirty)
              OfficeButton(
                label: 'Undo changes',
                onPressed: () => setState(() {
                  _drafts.remove(_current);
                  _text.text = _saved(_current);
                }),
              ),
            OfficeButton(label: 'Save', kind: BtnKind.primary, onPressed: dirty ? _save : null),
          ],
        ],
      ),
    );
  }

  Widget _item(PromptId id) {
    final on = id == _current;
    final edited = store.prompts.custom.containsKey(id);
    final mark = _dirty(id)
        ? '●'
        : edited
        ? '✎'
        : '';
    return Tooltip(
      message: _dirty(id)
          ? 'Not saved yet'
          : edited
          ? 'Rewritten'
          : 'The default',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        key: ValueKey('prompt-$id'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _pick(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(color: on ? Swatch.paper2 : null, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Expanded(
                child: Text(prompts[id]!.label, style: heavy(13, weight: on ? FontWeight.w900 : FontWeight.w700)),
              ),
              Text(mark, style: heavy(12, color: Swatch.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
