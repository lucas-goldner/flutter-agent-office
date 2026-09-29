// The character select screen: your name, skin tone, hair and shirt, with a preview (ui/character.ts).
// `first` is the one you see when you join, which can't be skipped.
//
// The spinning 3D preview is the world's Person model, handed in as [CharacterPreview]; without
// one a flat chibi head stands in (see [ChibiAvatar]).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../office_scope.dart';
import 'package:office_shared/avatar.dart';
import '../state/store.dart';
import 'hud_parts.dart' show cssColor;
import 'chibi.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// Draws your character with this look and shirt colour.
typedef CharacterPreview = Widget Function(Look look, String color);

ModalHandle openCharacter(
  OfficeScope scope, {
  bool first = false,
  required void Function(Profile p) onSave,
  CharacterPreview? preview,
}) => ModalStack.instance.show(
  (modal) => _CharacterWindow(scope: scope, modal: modal, first: first, onSave: onSave, preview: preview),
  escCloses: !first,
  backdropCloses: !first,
)..doing = '🪞 picking a new look';

class _CharacterWindow extends StatefulWidget {
  const _CharacterWindow({
    required this.scope,
    required this.modal,
    required this.first,
    required this.onSave,
    this.preview,
  });

  final OfficeScope scope;
  final ModalHandle modal;
  final bool first;
  final void Function(Profile p) onSave;
  final CharacterPreview? preview;

  @override
  State<_CharacterWindow> createState() => _CharacterWindowState();
}

class _CharacterWindowState extends State<_CharacterWindow> {
  Store get store => widget.scope.store;
  late Look _look = store.profile.look;
  late String _color = store.profile.color;
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  /// Bumped on every change, for the little hop that shows it landed.
  int _cheer = 0;

  @override
  void initState() {
    super.initState();
    final p = store.profile;
    _name.text = widget.first ? (p.name != 'Guest' ? p.name : '') : p.name;
    // Your account's name is the one everyone sees; only the look is yours to change here.
    final account = store.me.account;
    if (account != null) _name.text = account.name;
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _change({int? skin, int? hair, int? style, String? color}) => setState(() {
    _look = Look(skin: skin ?? _look.skin, hair: hair ?? _look.hair, style: style ?? _look.style);
    if (color != null) _color = color;
    _cheer++;
  });

  void _surprise() {
    final r = randomLook();
    _change(
      skin: r.skin,
      hair: r.hair,
      style: r.style,
      color: kAvatarColors[math.Random().nextInt(kAvatarColors.length)],
    );
  }

  void _save() {
    var name = _name.text.trim();
    if (name.length > 24) name = name.substring(0, 24);
    if (name.isEmpty) return _nameFocus.requestFocus();
    store.profile = Profile(name: name, color: _color, look: _look);
    saveProfile(store.profile);
    widget.modal.close();
    widget.onSave(store.profile);
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.first;
    final narrow = MediaQuery.sizeOf(context).width <= 640;
    final stage = _Stage(
      look: _look,
      color: _color,
      cheer: _cheer,
      preview: widget.preview,
      height: narrow ? 230 : 360,
    );
    final opts = _options();
    return ModalWindow(
      modal: widget.modal,
      width: 780,
      closable: !first,
      title: Text(first ? '👋 Pick your character' : '🧍 Your character'),
      body: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: 230, child: stage),
                const SizedBox(height: 18),
                opts,
              ],
            )
          // The stage stretches to the options' height, like the grid row.
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 250, child: stage),
                  const SizedBox(width: 18),
                  Expanded(child: opts),
                ],
              ),
            ),
      footer: Row(
        children: [
          OfficeButton(label: '🎲 Surprise me', tooltip: 'Random look', onPressed: _surprise),
          const Spacer(),
          OfficeButton(label: first ? 'Enter the office 🚪' : 'Save', kind: BtnKind.primary, onPressed: _save),
        ],
      ),
    );
  }

  Widget _options() {
    final account = store.me.account;
    Widget swatch(String color, String label, bool on, VoidCallback choose) =>
        _Swatch(color: color, label: label, selected: on, onTap: choose);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Your name', top: 0),
        BoxInput(
          controller: _name,
          focusNode: _nameFocus,
          autofocus: account == null,
          readOnly: account != null,
          maxLength: 24,
          hint: 'e.g. Ada',
          tooltip: account != null ? 'Your account name' : null,
          onSubmitted: (_) => _save(),
        ),
        if (account != null) Note("🔑 Signed in as ${account.name}, so that's your name here."),
        const FieldLabel('Skin tone', top: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, c) in skinTones.indexed)
              swatch(c, 'Skin tone ${i + 1} of ${skinTones.length}', i == _look.skin, () => _change(skin: i)),
          ],
        ),
        const FieldLabel('Hair', top: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (i, name) in hairStyles.indexed)
              SmallButton(
                label: name,
                kind: i == _look.style ? BtnKind.on : BtnKind.plain,
                onPressed: () => _change(style: i),
              ),
          ],
        ),
        const FieldLabel('Hair color', top: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, c) in hairColors.indexed)
              swatch(c, hairColorNames[i], i == _look.hair, () => _change(hair: i)),
          ],
        ),
        const FieldLabel('Shirt', top: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final c in kAvatarColors) swatch(c, 'Shirt $c', c == _color, () => _change(color: c))],
        ),
      ],
    );
  }
}

/// A 34px colour button; the picked one has an orange ring around it.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label, required this.selected, required this.onTap});

  final String color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    waitDuration: const Duration(milliseconds: 500),
    child: Semantics(
      label: label,
      selected: selected,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            // outline: 3px solid accent; outline-offset: 2px
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? Swatch.accent : Colors.transparent, width: 3),
            ),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: cssColor(color),
                shape: BoxShape.circle,
                border: Border.all(color: Swatch.ink, width: kBorder),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The .charsel-stage: a sky-blue spotlight with your character in it.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.look,
    required this.color,
    required this.cheer,
    required this.preview,
    required this.height,
  });

  final Look look;
  final String color;
  final int cheer;
  final CharacterPreview? preview;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minHeight: height),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Swatch.ink, width: kBorder),
      gradient: const RadialGradient(
        center: Alignment(0, -0.4),
        radius: 1.1,
        colors: [Colors.white, Color(0xFFE3F3FF), Swatch.sky],
        stops: [0, 0.55, 1],
      ),
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (preview != null)
          preview!(look, color)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 30, 24, 36),
            // A little hop, to show a change landed.
            child: TweenAnimationBuilder<double>(
              key: ValueKey(cheer),
              tween: Tween(begin: cheer == 0 ? 1 : 0, end: 1),
              duration: const Duration(milliseconds: 320),
              builder: (context, t, child) =>
                  Transform.translate(offset: Offset(0, -18 * math.sin(t * math.pi)), child: child),
              child: ChibiAvatar(look: look, color: color),
            ),
          ),
        if (preview != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: IgnorePointer(
              child: Text(
                'Drag to spin',
                textAlign: TextAlign.center,
                style: heavy(12, color: Swatch.muted),
              ),
            ),
          ),
      ],
    ),
  );
}
