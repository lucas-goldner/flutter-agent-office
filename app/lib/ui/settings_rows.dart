// The pieces ⚙️ Settings is made of (ui/settings-rows.ts and the card markup of ui/settings.ts): the
// categories down the side, a card per setting with who it's for, a row of buttons to pick one of, the
// volume slider, and the registry other parts of the office add their own cards to.
//
// A card is registered once, at startup or the first time its feature loads:
//
//   settingsCards.add(SettingsPane.building, id: 'map', order: 5, (c) => SettingCard(
//     title: 'Map', scope: SettingScope.office, children: [...]));
//
// The built-in cards (settings.dart) are numbered in tens, so a card can go between two of them. A card
// added with the id of one already there replaces it (a fuller dog card for the plain one, say).

import 'package:flutter/material.dart';

import '../net/office_socket.dart';
import '../office_scope.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// The categories down the side of ⚙️ Settings.
enum SettingsPane { you, sound, notify, building, workers }

/// What each category is called and what it holds.
const Map<SettingsPane, ({String icon, String label, String blurb})> settingsPanes = {
  SettingsPane.you: (
    icon: '🧍',
    label: 'You',
    blurb: 'How you look, how you see the office, and how you’re signed in.',
  ),
  SettingsPane.sound: (
    icon: '🔊',
    label: 'Sound & voice',
    blurb: 'How loud the office is for you, and how voice chat works.',
  ),
  SettingsPane.notify: (
    icon: '🔔',
    label: 'Notifications',
    blurb: 'Hear about a worker that needs someone, or finished, while you’re somewhere else.',
  ),
  SettingsPane.building: (
    icon: '🏢',
    label: 'Building',
    blurb: 'The map, the decorations, the sky, the dog, and where new floors are cloned.',
  ),
  SettingsPane.workers: (
    icon: '🤖',
    label: 'Workers',
    blurb: 'What workers start on, how many run at once, when they go home and what the office tells them.',
  ),
};

/// The category [from] moves to with an arrow key: down or right is +1, up or left -1, round the ends.
SettingsPane stepPane(SettingsPane from, int step) {
  const all = SettingsPane.values;
  return all[(from.index + step + all.length) % all.length];
}

/// Who a setting is for, shown by its name: some are yours alone, some the whole office's.
enum SettingScope { you, floor, office }

const Map<SettingScope, ({String label, String title, Color color})> settingScopes = {
  SettingScope.you: (label: 'Just you', title: 'Only for you, kept in this browser', color: Color(0xFFDFF3FB)),
  SettingScope.floor: (label: 'This floor', title: 'The same for everyone on this floor', color: Color(0xFFD7F7EC)),
  SettingScope.office: (label: 'Everyone', title: 'The same for everyone in the building', color: Color(0xFFFFE6D9)),
};

/// What a card is built from: the office, your settings as they are in the window, and a way to change them.
class SettingsContext {
  SettingsContext({
    required this.scope,
    required this.modal,
    required this.current,
    required this.change,
    this.outside,
  });

  final OfficeScope scope;
  final ModalHandle modal;

  /// Your settings as they are in the window now.
  final Settings Function() current;

  /// Changes some of your own settings, and has the office take them up.
  final void Function(void Function(Settings s) edit) change;

  /// What the sky over the office is doing (see describeSky), once the server has said.
  final ({String now, bool live})? outside;

  Settings get settings => current();
  Store get store => scope.store;
  OfficeSocket get net => scope.net;
}

/// Builds one card; null leaves it out this time (the dog card on a floor without a dog).
typedef SettingsCardBuilder = Widget? Function(SettingsContext c);

class SettingsCardEntry {
  const SettingsCardEntry(this.pane, this.id, this.order, this.builder, this.topics);
  final SettingsPane pane;
  final String id;
  final int order;
  final SettingsCardBuilder builder;

  /// What the window listens to so this card redraws when it changes.
  final List<Topic> topics;
}

/// Every card ⚙️ Settings shows, by category.
class SettingsCards {
  final Map<String, SettingsCardEntry> _cards = {};

  /// Adds a card to [pane] at [order] (the built-in ones are 10, 20, 30…), redrawn when any of [topics]
  /// changes. The same [id] again replaces the card.
  void add(
    SettingsPane pane,
    SettingsCardBuilder builder, {
    required String id,
    int order = 1000,
    List<Topic> topics = const [],
  }) => _cards[id] = SettingsCardEntry(pane, id, order, builder, topics);

  void remove(String id) => _cards.remove(id);

  bool has(String id) => _cards.containsKey(id);

  /// [pane]'s cards in order.
  List<SettingsCardEntry> of(SettingsPane pane) =>
      _cards.values.where((c) => c.pane == pane).toList()..sort((a, b) => a.order.compareTo(b.order));

  /// Every topic some card redraws on.
  Set<Topic> get topics => {for (final c in _cards.values) ...c.topics};
}

/// The office's ⚙️ Settings cards. settings.dart puts the built-in ones in; other parts add theirs.
final SettingsCards settingsCards = SettingsCards();

/// One setting: its name and who it's for, then whatever sets it (.setting).
class SettingCard extends StatelessWidget {
  const SettingCard({super.key, required this.title, this.scope, required this.children});

  final String title;
  final SettingScope? scope;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final s = scope == null ? null : settingScopes[scope]!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink.withValues(alpha: 0.18), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(title, style: heavy(15, weight: FontWeight.w900)),
                ),
                if (s != null)
                  Tooltip(
                    message: s.title,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        color: s.color,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Swatch.ink, width: 2),
                      ),
                      child: Text(s.label, style: heavy(11, weight: FontWeight.w900)),
                    ),
                  ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// A row of buttons to pick one of [options] from (choiceRow).
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({super.key, required this.options, required this.value, required this.onPick});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) => SegButtons<T>(
    small: false,
    gap: 8,
    options: options,
    value: value,
    onPick: (v) {
      if (v != value) onPick(v);
    },
  );
}

/// A volume slider with its mute button. Dragging it turns the sound back on; letting go calls [onLetGo].
class VolumeRow extends StatelessWidget {
  const VolumeRow({
    super.key,
    required this.label,
    required this.level,
    required this.muted,
    required this.onLevel,
    required this.onMute,
    this.onLetGo,
  });

  final String label;
  final double level;
  final bool muted;
  final ValueChanged<double> onLevel;
  final VoidCallback onMute;
  final VoidCallback? onLetGo;

  @override
  Widget build(BuildContext context) {
    final pct = (level * 100).round();
    return Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 112),
          child: OfficeButton(
            label: muted ? '🔊 Unmute' : '🔇 Mute',
            kind: muted ? BtnKind.danger : BtnKind.plain,
            onPressed: onMute,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Opacity(
            opacity: muted ? 0.45 : 1,
            child: _Slider(label: label, value: level, onChanged: onLevel, onChangeEnd: onLetGo),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 52,
          child: Opacity(
            opacity: muted ? 0.45 : 1,
            child: Text(
              muted ? 'Muted' : '$pct%',
              textAlign: TextAlign.right,
              style: heavy(14, weight: FontWeight.w900),
            ),
          ),
        ),
      ],
    );
  }
}

/// The range input: a 14px track with a 3px ink border, orange up to the thumb, and a paper thumb.
class _Slider extends StatelessWidget {
  const _Slider({required this.label, required this.value, required this.onChanged, this.onChangeEnd});

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    slider: true,
    value: '${(value * 100).round()}%',
    child: LayoutBuilder(
      builder: (context, box) {
        const thumb = 24.0;
        final w = box.maxWidth;
        double at(double x) => ((x - thumb / 2) / (w - thumb)).clamp(0.0, 1.0);
        void set(double x) => onChanged((at(x) * 100).round() / 100);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => set(d.localPosition.dx),
            onTapUp: (_) => onChangeEnd?.call(),
            onHorizontalDragUpdate: (d) => set(d.localPosition.dx),
            onHorizontalDragEnd: (_) => onChangeEnd?.call(),
            child: SizedBox(height: 28, child: CustomPaint(painter: _SliderPainter(value))),
          ),
        );
      },
    ),
  );
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    const thumb = 24.0;
    final cy = size.height / 2;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - 7, size.width, 14), const Radius.circular(999));
    final x = thumb / 2 + value * (size.width - thumb);
    canvas.save();
    canvas.clipRRect(track);
    canvas.drawRect(Rect.fromLTWH(0, cy - 7, size.width, 14), Paint()..color = Colors.white);
    canvas.drawRect(Rect.fromLTWH(0, cy - 7, x, 14), Paint()..color = Swatch.accent);
    canvas.restore();
    canvas.drawRRect(
      track.deflate(1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Swatch.ink,
    );
    final c = Offset(x, cy);
    canvas.drawCircle(c + const Offset(0, 2), thumb / 2, Paint()..color = Swatch.ink);
    canvas.drawCircle(c, thumb / 2, Paint()..color = Swatch.paper);
    canvas.drawCircle(
      c,
      thumb / 2 - 1.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Swatch.ink,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) => old.value != value;
}
