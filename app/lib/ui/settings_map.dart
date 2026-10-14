// ⚙️ Settings → Building → Map: the building's map, for everyone (the office, the castle, the space
// station, or one of your own), and why a map of your own won't load. Opening Settings has the office
// read its folder of maps again, so one you just added or fixed shows up. The map card of upstream's
// ui/settings.ts, registered with the settings cards (settings_rows.dart).

import 'package:flutter/material.dart';
import 'package:office_shared/maps/maps.dart' show MapChoice, mapChoices;
import 'package:office_shared/protocol.dart' show MapSetCmd, MapState;

import '../state/store.dart' show Topic;
import 'modal.dart' show timeAgo;
import 'settings_rows.dart';
import 'theme.dart' show BtnKind;
import 'window_parts.dart';

/// What the note under the map buttons says: what the map is, who picked it and when, and where your own go.
String mapNote(MapState m, List<MapChoice> choices, {String Function(int at)? ago}) {
  final now = choices.where((c) => c.id == m.pick).firstOrNull ?? choices.first;
  final by = m.by;
  final when = m.at != null && ago != null ? ' ${ago(m.at!)}' : '';
  final picked = by != null ? ', picked by $by$when' : '';
  return '${now.description} It’s the same on every floor, for everyone in the building$picked. Maps of your own go in '
      'the office’s .agent-office/maps/ folder as JSON (see docs/maps.md).';
}

/// The maps of your own that won't load, and why, a line each.
String brokenMaps(List<MapChoice> choices) => [
  for (final m in choices)
    if (m.error != null) "⚠️ ${m.id} won't load: ${m.error}",
].join('\n');

/// Puts the map card in Settings → Building, before the holiday theme.
void registerMapSettings() {
  settingsCards.add(SettingsPane.building, id: 'map', order: 5, topics: const [Topic.map], (c) => _MapCard(c));
}

class _MapCard extends StatefulWidget {
  const _MapCard(this.c);
  final SettingsContext c;

  @override
  State<_MapCard> createState() => _MapCardState();
}

class _MapCardState extends State<_MapCard> {
  @override
  void initState() {
    super.initState();
    // Read the folder of maps again, so one you just added or fixed shows up.
    widget.c.net.send(const MapSetCmd());
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final m = c.store.map;
    final choices = mapChoices(m.custom);
    final broken = brokenMaps(choices);
    return SettingCard(
      title: 'Map',
      scope: SettingScope.office,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in choices)
              SmallButton(
                label: '${choice.icon} ${choice.name}',
                small: false,
                kind: m.pick == choice.id ? BtnKind.on : BtnKind.plain,
                tooltip: choice.error != null ? "${choice.id} won't load: ${choice.error}" : choice.description,
                onPressed: choice.error != null
                    ? null
                    : () {
                        if (c.store.map.pick != choice.id) c.net.send(MapSetCmd(choice.id));
                      },
              ),
          ],
        ),
        Note(mapNote(m, choices, ago: timeAgo)),
        if (broken.isNotEmpty) Note(broken, bad: true),
      ],
    );
  }
}
