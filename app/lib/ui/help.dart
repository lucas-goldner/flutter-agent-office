// 🎮 Controls: every key and what it does (openHelp in ui/hud.ts).

import 'package:flutter/material.dart';

import 'hud_parts.dart' show KeyCap;
import 'modal.dart';
import 'terminal_logic.dart' show isMacKeyboard;
import 'theme.dart';

final List<(String, String)> helpRows = [
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
    'Whenever a pull request merges, the gong next to the PR board rings, confetti rains down all over the floor and every worker gets up on its desk for a quick dance. Walk up to the gong and press E to bang it yourself',
  ),
  (
    '🤖',
    'An agent stands by the issues board, the PR board and the task queue. Press E at one and type what you want: it runs as an agent that knows that board. O there opens its terminal; Hide, ✕ or Esc closes the terminal without sending it home; X sends it home',
  ),
  (
    '🕹️',
    'The arcade cabinet in the lounge: E plays BLOCKFALL (arrows move and turn, Space drops, C holds, P pauses), or watches whoever is on it',
  ),
  (
    '🏀',
    'The ball under the hoop on the west wall: E picks it up, hold E (or click) and let go in the green to shoot, Q drops it',
  ),
  (
    '⛳',
    'The golf tee on the balcony: E steps up, A/D aim, W/S loft, hold Space and let go to swing, E puts the club back',
  ),
  (
    '🎯',
    'Up on the roof, in the corner past the DJ: a dart board and an axe-throwing lane. E at either steps up to the line. The mouse (or the arrow keys) aims, and your hand wanders more after a few drinks. Hold Space (or the mouse button) and let go in the green: three darts a visit, five axes a round, chalked up for everyone up there. E steps back',
  ),
  ('🔭', 'The telescope up in the boss office: E looks through it, the mouse aims it, Esc steps back'),
  ('📚', "The bookshelf on the south wall: E reads the project's Markdown docs"),
  (
    '🤝',
    'The meeting room under the boss office: E at its table calls a meeting of 2 to 5 workers, or shows how it is going',
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
  (
    '👥',
    'Click someone under "In the office" to walk over to them (on another floor, you ride the elevator first). The line under their name says what they have open or where they are',
  ),
  (
    'N',
    "Next worker that needs you: go to whoever needs input (they have a red beacon over their desk, and a banner up top says what each is asking), then whoever is done and nobody's looked at, longest-waiting first, and again for the next one. Arrows at the edge of the screen point to the ones out of sight",
  ),
  (
    'Q',
    'Put back the issue card in your hands (E at a note on the issues board, or ✋ Pick it up in an issue; then E at an empty desk, a worker or the queue board)',
  ),
  ('F', 'Hang a picture from the web on a wall. Look at a picture and press E to move, edit or take it down'),
  (
    '🐶',
    'Walk up to the office dog and press E to pet it. When a worker needs input, it runs to that desk and barks. Name it in ⚙️ Settings',
  ),
  ('O', 'Open a pull request for a worker on its own branch, or see the one it has'),
  ('T', 'Chat'),
  (
    'G / 1–6',
    'Emote: hold G, point at one and let go (or tap G and click one), or press 1–6: wave, thumbs up, clap, dance, point, facepalm. Everyone on your floor sees it',
  ),
  ('/', 'Search the chat and every terminal on your floor, back to before the office last restarted'),
  (
    isMacKeyboard ? '⌘K' : 'Ctrl+K',
    'Command palette: type a few letters to find a worker, issue, PR, service, board, teammate or action. Enter opens it, Shift+Enter walks you over to it first',
  ),
  (
    'V',
    'Join voice. In voice, hold V to talk (push to talk): you’re muted once you let go. Leave voice from the ☰ menu',
  ),
  ('M', 'Mute or unmute your mic in voice. ⚙️ Settings can have you join muted, for push to talk'),
  (
    'Ctrl+Space',
    'Dictate: in a worker’s terminal or a prompt box, hold Ctrl+Space (or the 🎤) and talk, and what you said is typed in when you let go, for you to read over and send. A quick tap leaves it listening until you tap again. The browser does the listening (Chrome, Edge and Safari can), so there’s nothing to install',
  ),
  ('Tab', 'The ☰ menu, top right: every window, and what shows on screen. Pin what you use most to the top bar'),
  ('Esc', 'Close any window and get back to looking around'),
  (
    'Ctrl + [',
    'Send Esc to a terminal instead, to close a menu like Claude’s /skills or interrupt Claude. ⎋ Esc in the terminal’s header does the same',
  ),
  ('⚙️', 'Settings (in the ☰ menu): switch between first and third person'),
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
