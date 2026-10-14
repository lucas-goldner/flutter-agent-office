// The floor plan's windows (ui/floorplan.ts): L at a desk for the sign over it (what it says, its colour,
// or take it down), and E at the "Room to grow" sign to build the back office out a row, or wall the last
// row back up.

import 'package:flutter/material.dart';
import 'package:office_shared/floorplan.dart';
import 'package:office_shared/layout.dart' show Wing, desks, wingDesks;
import 'package:office_shared/protocol.dart';

import '../interop/portable.dart' show storageGet, storageSet;
import '../office_scope.dart';
import '../state/store.dart' show Topic;
import '../world/toon.dart' show hex;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

const _colorKey = 'agent-office.signColor';

String _lastColor() {
  try {
    return signColor(storageGet(_colorKey));
  } catch (_) {
    return signColors.first.color;
  }
}

/// L at a desk: what the sign over it says (and its colour), or take it down.
ModalHandle? openDeskLabel(OfficeScope scope, String deskId) {
  final desk = [...desks, ...wingDesks].where((d) => d.id == deskId).firstOrNull;
  if (desk == null) return null;
  return ModalStack.instance.show(
    (modal) => _DeskLabelWindow(scope: scope, modal: modal, deskId: deskId, label: desk.label),
  )..doing = '🪧 labeling ${desk.label}';
}

class _DeskLabelWindow extends StatefulWidget {
  const _DeskLabelWindow({required this.scope, required this.modal, required this.deskId, required this.label});
  final OfficeScope scope;
  final ModalHandle modal;
  final String deskId;
  final String label;

  @override
  State<_DeskLabelWindow> createState() => _DeskLabelWindowState();
}

class _DeskLabelWindowState extends State<_DeskLabelWindow> {
  late final DeskLabel? _old = widget.scope.store.floorPlan.labels[widget.deskId];
  late String _color = _old?.color ?? _lastColor();
  late final TextEditingController _text = TextEditingController(text: _old?.text ?? '')
    ..selection = TextSelection(baseOffset: 0, extentOffset: (_old?.text ?? '').length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send(String text) {
    widget.scope.net.send(DeskLabelCmd(widget.deskId, text, color: _color));
    widget.modal.close();
  }

  void _submit() {
    final text = cleanLabel(_text.text);
    if (text.isNotEmpty || _old != null) _send(text);
  }

  @override
  Widget build(BuildContext context) {
    final text = cleanLabel(_text.text);
    final old = _old;
    final ink = hex(signInk(_color));
    return ModalWindow(
      modal: widget.modal,
      width: 520,
      title: Text('🪧 Sign over ${widget.label}'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What it'll look like, hung up.
          Container(
            key: const ValueKey('sign-preview'),
            height: 96,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: hex(_color),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Swatch.ink, width: kBorder),
            ),
            child: Text(
              text.isEmpty ? 'Operations' : text,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: heavy(30, color: text.isEmpty ? ink.withValues(alpha: 0.45) : ink, weight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 14),
          const FieldLabel('What it says'),
          BoxInput(
            controller: _text,
            hint: 'Operations',
            maxLength: maxLabel,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final idea in labelIdeas)
                OfficeButton(
                  label: idea,
                  dense: true,
                  onPressed: () => setState(() {
                    _text.text = idea;
                    _text.selection = TextSelection.collapsed(offset: idea.length);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const FieldLabel('Color'),
          Wrap(
            spacing: 8,
            children: [
              for (final c in signColors)
                Tooltip(
                  message: c.name,
                  child: GestureDetector(
                    key: ValueKey('swatch-${c.name}'),
                    onTap: () => setState(() {
                      _color = c.color;
                      try {
                        storageSet(_colorKey, _color);
                      } catch (_) {
                        // a private window: the colour just isn't remembered
                      }
                    }),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: hex(c.color),
                        shape: BoxShape.circle,
                        border: Border.all(color: Swatch.ink, width: c.color == _color ? 4 : kBorder),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Note('It hangs from the ceiling over the desk, for everyone on this floor.'),
        ],
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (old != null) OfficeButton(label: 'Take it down', kind: BtnKind.danger, onPressed: () => _send('')),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          OfficeButton(
            key: const ValueKey('sign-submit'),
            label: text.isEmpty && old != null
                ? 'Take it down'
                : old != null
                ? 'Save'
                : '🪧 Hang it',
            kind: BtnKind.primary,
            onPressed: text.isEmpty && old == null ? null : _submit,
          ),
        ],
      ),
    );
  }
}

/// E at the sign in the back office (or on the wall where it goes through): build it out, or wall it up.
ModalHandle openExpand(OfficeScope scope) =>
    ModalStack.instance.show((modal) => _ExpandWindow(scope: scope, modal: modal))..doing = '🔨 in the back office';

class _ExpandWindow extends StatefulWidget {
  const _ExpandWindow({required this.scope, required this.modal});
  final OfficeScope scope;
  final ModalHandle modal;

  @override
  State<_ExpandWindow> createState() => _ExpandWindowState();
}

class _ExpandWindowState extends State<_ExpandWindow> with ListenTo {
  @override
  void initState() {
    super.initState();
    final store = widget.scope.store;
    listenTo(store.topic(Topic.floorPlan), () => setState(() {}));
    listenTo(store.topic(Topic.workers), () => setState(() {}));
  }

  String _names(int row) => rowDesks(row).map((d) => d.label).join(' and ');

  @override
  Widget build(BuildContext context) {
    final store = widget.scope.store;
    final level = store.floorPlan.wing;
    final full = level >= Wing.rows;
    final next = level + 1;
    final last = level > 0 ? rowDesks(level) : const [];
    final busy = last.where((d) => store.workerAtDesk(d.id) != null).firstOrNull;
    void send(ClientMsg m) {
      widget.scope.net.send(m);
      widget.modal.close();
    }

    return ModalWindow(
      modal: widget.modal,
      width: 500,
      title: const Text('🔨 Back office'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            level == 0
                ? 'The office has room to grow through the north wall, between the gong and the corner.'
                : 'The back office is built out $level of ${Wing.rows} rows, with ${level * 2} more desks.',
            style: heavy(15, weight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < Wing.rows; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: _names(i + 1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: i < level ? Swatch.good : Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Swatch.ink, width: kBorder),
                      ),
                      child: Text(i < level ? '🪑🪑' : '· ·', style: heavy(14)),
                    ),
                  ),
                ),
            ],
          ),
          Note(
            full
                ? "It can't go back any further."
                : 'Knocking through brings ${_names(next)}, each with its own sign to hang (press L at a desk).',
          ),
          if (busy != null) Note("Someone's at ${busy.label}: send them home before walling that row up.", bad: true),
          const Note('It changes the floor for everyone on it, and stays built across restarts.'),
        ],
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (level > 0)
            OfficeButton(
              key: const ValueKey('shrink'),
              label: '🧱 Wall up the last row',
              onPressed: busy != null ? null : () => send(const FloorShrinkCmd()),
            ),
          OfficeButton(
            key: const ValueKey('expand'),
            label: full
                ? 'Built all the way out'
                : level == 0
                ? '🔨 Knock through (+2 desks)'
                : '🔨 Another row (+2 desks)',
            kind: BtnKind.primary,
            onPressed: full ? null : () => send(const FloorExpandCmd()),
          ),
        ],
      ),
    );
  }
}
