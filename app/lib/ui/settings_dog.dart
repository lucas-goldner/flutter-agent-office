// ⚙️ Settings → Building → Office dog: its name, and its breed and coat as buttons, for everyone on the
// floor (see server/dog.dart). A port of upstream's ui/settings-dog.ts (#220).

import 'package:flutter/material.dart';
import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart' show DogBreedCmd, DogCoatCmd, DogNameCmd;

import 'hud_parts.dart' show cssColor;
import 'settings_rows.dart';
import 'theme.dart';
import 'window_parts.dart';

/// What the note under the dog's setting says.
String dogNote(String name) =>
    '$name lives on this floor. When a worker needs input, $name runs to its desk and barks. Walk up and '
    'press E to pet it. Its name, breed and coat are for everyone on this floor.';

class DogCard extends StatefulWidget {
  const DogCard({super.key, required this.c});
  final SettingsContext c;

  @override
  State<DogCard> createState() => _DogCardState();
}

class _DogCardState extends State<DogCard> {
  final _dog = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _dog.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rename() {
    final name = cleanDogName(_dog.text);
    if (name.isEmpty) return _focus.requestFocus();
    widget.c.net.send(DogNameCmd(name));
    _dog.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final dog = c.store.dog!;
    return SettingCard(
      title: 'Office dog',
      scope: SettingScope.floor,
      children: [
        Row(
          children: [
            Expanded(
              child: BoxInput(
                controller: _dog,
                focusNode: _focus,
                maxLength: dogNameMax,
                hint: dog.name,
                onSubmitted: (_) => _rename(),
              ),
            ),
            const SizedBox(width: 8),
            OfficeButton(label: 'Rename', kind: BtnKind.primary, onPressed: _rename),
          ],
        ),
        ChoiceRow<DogBreed>(
          options: [for (final b in dogBreeds) (b, dogBreedNames[b]!)],
          value: dog.breed,
          onPick: (b) {
            if (b != c.store.dog?.breed) c.net.send(DogBreedCmd(b.wire));
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, coat) in dogCoats.indexed)
              CoatSwatch(
                key: ValueKey('coat-$i'),
                body: coat.$1,
                light: coat.$2,
                label: dogCoatNames[i],
                selected: i == dog.coat,
                onTap: () {
                  if (i != c.store.dog?.coat) c.net.send(DogCoatCmd(i));
                },
              ),
          ],
        ),
        Note(dogNote(dog.name)),
      ],
    );
  }
}

/// A coat to pick: its body colour and its belly's, split on the diagonal.
class CoatSwatch extends StatelessWidget {
  const CoatSwatch({
    super.key,
    required this.body,
    required this.light,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String body, light, label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? Swatch.accent : Swatch.ink, width: selected ? 4 : kBorder),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [cssColor(body), cssColor(body), cssColor(light), cssColor(light)],
                stops: const [0, 0.55, 0.55, 1],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
