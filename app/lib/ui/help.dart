// 🎮 Controls: every key and what it does (openHelp in ui/hud.ts).

import 'package:flutter/material.dart';

import 'hud_parts.dart' show KeyCap;
import 'modal.dart';
import 'theme.dart';

const List<(String, String)> helpRows = [
  ('W A S D', 'Walk (hold Shift to run)'),
  ('Space', 'Jump'),
  (
    '☕',
    'Press E at the coffee machine in the kitchen for a minute of quicker walking and higher jumps. Three cups in a row gives you the jitters',
  ),
  ('Mouse', 'Look around in first person (click to capture the mouse, Esc to free it)'),
  (
    'Click / E',
    'Use what you look at: hire a worker, open its terminal, read a board, watch the TV, put a song on the jukebox, sit on a couch, a beanbag, a chair or the balcony bench (walk off to get up)',
  ),
  (
    '🛗',
    'Every project is a floor: step into the elevator on the north wall and press E (or click the project name, top left) to go to another one or add a project',
  ),
  (
    '📝',
    'The whiteboard on wheels between the desks and the lounge: press E to draw on it with everyone on your floor, live. What you draw stays up on the board',
  ),
  (
    '🎉',
    'The gong next to the PR board rings, and confetti flies over the desk, whenever a pull request merges. Walk up and press E to bang it yourself',
  ),
  (
    '🍸',
    'The elevator goes up to the rooftop bar: a DJ playing drum and bass under the lights, and the city all around. Press E at the bar for a drink (it goes to your head for a bit) and at the DJ booth for the air horn',
  ),
  ('Drag / wheel', 'Orbit and zoom the camera in third person'),
  ('P', 'Prompt: give a task to a new or existing worker at the desk you face'),
  ('C', 'Changes: what the worker at the desk you face changed — files and diff, commit, discard, open a PR'),
  ('B', 'Open a shared shell (dev servers, git, tests) at an empty desk'),
  ('R', 'Resume a sleeping worker'),
  ('X', 'Send a worker home (frees the desk)'),
  ('F', 'Hang a picture from the web on a wall. Look at a picture and press E to move, edit or take it down'),
  (
    '🐶',
    'Walk up to the office dog and press E to pet it. When a worker needs input, it runs to that desk and barks. Name it in ⚙️ Settings',
  ),
  ('O', 'Open a pull request for a worker on its own branch, or see the one it has'),
  ('T', 'Chat'),
  ('/', 'Search the chat and every terminal on your floor, back to before the office last restarted'),
  ('V / M', 'Join voice / mute'),
  ('Esc', 'Close any window and get back to looking around'),
  ('Ctrl + [', 'Send Esc to a terminal (e.g. to interrupt Claude)'),
  ('⚙️', 'Settings: switch between first and third person'),
];

ModalHandle openHelp() => ModalStack.instance.show(
  (modal) => ModalWindow(modal: modal, title: const Text('🎮 Controls'), body: const _HelpGrid()),
);

/// .help-grid: keys in a column sized to the widest, what they do beside them.
class _HelpGrid extends StatelessWidget {
  const _HelpGrid();

  @override
  Widget build(BuildContext context) => Table(
    columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
    children: [
      for (final (i, (k, v)) in helpRows.indexed)
        TableRow(
          children: [
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8, right: 14),
              child: Align(alignment: Alignment.centerLeft, child: KeyCap(k, size: 16)),
            ),
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: Text(v, style: heavy(16, weight: FontWeight.w700)),
            ),
          ],
        ),
    ],
  );
}
