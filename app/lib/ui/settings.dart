// ⚙️ Settings (ui/settings.ts): the categories down the side (You, Sound & voice, Notifications, Building,
// Workers), the one picked on the right, a card per setting labelled with who it's for. The cards come from
// [settingsCards] (settings_rows.dart); the office's own are put in here, and other parts add theirs.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/browser.dart' show desktopApp, notInDesktopApp;
import '../notify.dart';
import '../office_scope.dart';

import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/theme.dart' show themePicks;

import '../state/store.dart';
import 'prompts.dart';
import 'provider.dart';
import 'settings_rows.dart';
import 'worker_limit.dart';
import '../world/player.dart' show ViewMode;
import '../world/sky_model.dart' show describeSky, outsideNote;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

export 'settings_rows.dart';

const List<(ViewMode, String, String)> _views = [
  (
    ViewMode.first,
    '👀 First person',
    'See through your own eyes. Click the office to look around with the mouse and click things to use them. Esc frees the mouse.',
  ),
  (
    ViewMode.third,
    '🎥 Third person',
    'Follow your character from behind. Drag to orbit the camera, scroll to zoom, and click things to use them.',
  ),
];

const Map<ThemePick, String> _themeLabel = {
  ThemePick.auto: '📅 By the calendar',
  ThemePick.halloween: '🎃 Halloween',
  ThemePick.christmas: '🎄 Christmas',
  ThemePick.off: 'Off',
};

/// What the holiday theme note says: what's up now, how auto picks, and who chose it.
String themeNote(ThemeState t, {String Function(int at)? ago}) {
  final now = switch (t.active) {
    HolidayTheme.halloween => 'Halloween: the workers are zombies, your hands are an undead warlock’s, the dog’s in costume, the sky’s gone creepy and there are jack-o’-lanterns everywhere.',
    HolidayTheme.christmas =>
      'Christmas: the workers are elves, your hands are in mittens, the dog’s Rudolph, and it’s snowing outside.',
    null => 'No decorations up right now.',
  };
  final how = t.pick == ThemePick.auto
      ? ' By the calendar it’s Halloween through October and Christmas through December.'
      : '';
  final by = t.by != null ? ', set by ${t.by}${t.at != null && ago != null ? ' ${ago(t.at!)}' : ''}' : '';
  return '$now$how It’s the same for everyone in the building$by.';
}

/// What the leave-on-merge note says.
String leaveOnMergeNote(LeaveOnMergeState l, {String Function(int at)? ago}) {
  final now = l.on
      ? 'Once a worker’s pull request merges, it goes home as soon as it isn’t working or waiting on you and nobody has its terminal open, and its worktree and branch are deleted. A worktree with uncommitted changes, or commits that aren’t on GitHub, is kept.'
      : 'A worker whose pull request merged stays at its desk, outlined in purple, until someone sends it home. Turned on, the ones already merged go too.';
  final by = l.by != null ? ', set by ${l.by}${l.at != null && ago != null ? ' ${ago(l.at!)}' : ''}' : '';
  return '$now It’s the same for everyone in the building$by.';
}

const Map<WebhookKind, String> _webhookName = {
  WebhookKind.slack: 'Slack',
  WebhookKind.discord: 'Discord',
  WebhookKind.other: 'a webhook',
};

/// Where ⚙️ Settings was last, so it opens there again.
SettingsPane lastSettingsPane = SettingsPane.you;

/// What the window's own cards need from the office that isn't in the store.
class _Hooks {
  _Hooks({
    required this.onCharacter,
    required this.previewSound,
    required this.previewNeedsYou,
    required this.notifier,
    required this.onSignOut,
  });
  final VoidCallback onCharacter;
  final VoidCallback previewSound;
  final VoidCallback previewNeedsYou;
  final DesktopNotifier notifier;
  final VoidCallback onSignOut;
}

/// The open window's hooks, for the built-in cards (only one ⚙️ Settings is open at a time).
_Hooks? _hooks;

/// `outside` describes the sky over the office (see describeSky), once the server has said. [first] opens on
/// that category instead of the last one.
ModalHandle openSettings(
  OfficeScope scope, {
  required Settings settings,
  required ValueChanged<Settings> onChange,
  required VoidCallback onCharacter,
  required VoidCallback previewSound,
  VoidCallback? previewNeedsYou,
  required DesktopNotifier notifier,
  required VoidCallback onSignOut,
  ({String now, bool live})? outside,
  SettingsPane? first,
}) {
  _builtInCards();
  _hooks = _Hooks(
    onCharacter: onCharacter,
    previewSound: previewSound,
    previewNeedsYou: previewNeedsYou ?? previewSound,
    notifier: notifier,
    onSignOut: onSignOut,
  );
  final modal = ModalStack.instance.show(
    (modal) => SettingsWindow(
      scope: scope,
      modal: modal,
      settings: settings.copy(),
      onChange: onChange,
      outside: outside,
      first: first ?? lastSettingsPane,
    ),
  );
  modal.doing = '⚙️ in settings';
  return modal;
}

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.scope,
    required this.modal,
    required this.settings,
    required this.onChange,
    required this.first,
    this.outside,
  });

  final OfficeScope scope;
  final ModalHandle modal;
  final Settings settings;
  final ValueChanged<Settings> onChange;
  final SettingsPane first;
  final ({String now, bool live})? outside;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> with ListenTo {
  late Settings _s = widget.settings;
  late SettingsPane _pane = widget.first;
  final _scroll = ScrollController();
  final _navFocus = FocusNode(debugLabel: 'settings-nav');
  late final SettingsContext _context = SettingsContext(
    scope: widget.scope,
    modal: widget.modal,
    current: () => _s,
    change: _change,
    outside: widget.outside,
  );

  @override
  void initState() {
    super.initState();
    lastSettingsPane = _pane;
    listenTo(widget.scope.store.topics({..._redrawOn, ...settingsCards.topics}), () => setState(() {}));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _navFocus.dispose();
    super.dispose();
  }

  void _change(void Function(Settings s) edit) {
    final next = _s.copy();
    edit(next);
    setState(() => _s = next);
    widget.onChange(next);
  }

  void _show(SettingsPane p) {
    lastSettingsPane = p;
    setState(() => _pane = p);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  KeyEventResult _onNavKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final step = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowLeft => -1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    _show(stepPane(_pane, step));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width <= 720;
    final pane = settingsPanes[_pane]!;
    final cards = [
      for (final c in settingsCards.of(_pane))
        if (c.builder(_context) case final Widget w) KeyedSubtree(key: ValueKey('card-${c.id}'), child: w),
    ];
    final body = SingleChildScrollView(
      key: ValueKey('pane-${_pane.name}'),
      controller: _scroll,
      padding: narrow ? const EdgeInsets.all(14) : const EdgeInsets.fromLTRB(22, 18, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${pane.icon} ${pane.label}', style: heavy(20, weight: FontWeight.w900)),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(
              pane.blurb,
              style: heavy(13.5, color: Swatch.muted, weight: FontWeight.w600),
            ),
          ),
          for (final (i, c) in cards.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: c,
            ),
        ],
      ),
    );
    final nav = Focus(
      focusNode: _navFocus,
      onKeyEvent: _onNavKey,
      child: Container(
        decoration: BoxDecoration(
          color: Swatch.paper2,
          border: narrow
              ? const Border(
                  bottom: BorderSide(color: Swatch.ink, width: kBorder),
                )
              : const Border(
                  right: BorderSide(color: Swatch.ink, width: kBorder),
                ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: narrow
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [for (final p in SettingsPane.values) _tab(p, narrow)]),
              )
            : ListView(children: [for (final p in SettingsPane.values) _tab(p, narrow)]),
      ),
    );
    return ModalWindow(
      modal: widget.modal,
      title: const Text('⚙️ Settings'),
      width: 960,
      height: 760,
      scrollBody: false,
      bodyPadding: EdgeInsets.zero,
      body: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                nav,
                Expanded(child: body),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 220, child: nav),
                Expanded(child: body),
              ],
            ),
    );
  }

  Widget _tab(SettingsPane p, bool narrow) {
    final on = p == _pane;
    final info = settingsPanes[p]!;
    return Padding(
      padding: narrow ? const EdgeInsets.only(right: 4) : const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: on,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('settings-tab-${p.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _navFocus.requestFocus();
              _show(p);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: on ? Colors.white : null,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: on ? Swatch.ink : Colors.transparent, width: 2),
                boxShadow: on ? const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))] : null,
              ),
              child: Row(
                mainAxisSize: narrow ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(info.icon, textAlign: TextAlign.center, style: heavy(18)),
                  ),
                  const SizedBox(width: 10),
                  if (narrow)
                    Text(info.label, style: heavy(15))
                  else
                    Flexible(
                      child: Text(info.label, style: heavy(15), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the built-in cards redraw on.
const _redrawOn = [
  Topic.notify,
  Topic.dog,
  Topic.me,
  Topic.theme,
  Topic.leaveOnMerge,
  Topic.machine,
  Topic.projectsDir,
  Topic.prompts,
  Topic.sky,
];

bool _builtIn = false;

/// The office's own cards, in the order upstream shows them.
void _builtInCards() {
  if (_builtIn) return;
  _builtIn = true;
  final cards = settingsCards;

  // You.
  cards.add(SettingsPane.you, id: 'character', order: 10, (c) {
    final account = c.store.me.account;
    return SettingCard(
      title: 'Your character',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OfficeButton(
            label: account != null ? '🧍 Change your look' : '🧍 Change your look & name',
            onPressed: () {
              c.modal.close();
              _hooks?.onCharacter();
            },
          ),
        ),
      ],
    );
  });
  cards.add(SettingsPane.you, id: 'view', order: 20, (c) {
    final view = c.settings.view;
    return SettingCard(
      title: 'Camera view',
      scope: SettingScope.you,
      children: [
        ChoiceRow<ViewMode>(
          options: [for (final (v, label, _) in _views) (v, label)],
          value: view,
          onPick: (v) => c.change((s) => s.view = v),
        ),
        Note(_views.firstWhere((v) => v.$1 == view).$3),
      ],
    );
  });
  cards.add(SettingsPane.you, id: 'signed-in', order: 30, (c) {
    final account = c.store.me.account;
    return SettingCard(
      title: 'Signed in',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OfficeButton(label: '🚪 Sign out', onPressed: () => _hooks?.onSignOut()),
        ),
        Note(
          account != null
              ? 'As ${account.name}, with your own account (${account.role.wire}).'
              : 'With the shared office password.',
        ),
      ],
    );
  });

  // Sound & voice.
  cards.add(SettingsPane.sound, id: 'sounds', order: 10, (c) {
    final s = c.settings;
    return SettingCard(
      title: 'Office sounds',
      scope: SettingScope.you,
      children: [
        VolumeRow(
          label: 'Office sounds volume',
          level: s.volume,
          muted: s.muted,
          onLevel: (v) => c.change(
            (s) => s
              ..volume = v
              ..muted = false,
          ),
          onMute: () {
            c.change((s) => s.muted = !s.muted);
            if (!c.settings.muted) _hooks?.previewSound();
          },
          onLetGo: () => _hooks?.previewSound(),
        ),
        const Note(
          'Workers typing, footsteps, the coffee machine, birds and rain outside, the dog, the ding when a worker is done and the alarm when one needs you. Voice chat isn’t affected.',
        ),
      ],
    );
  });
  cards.add(SettingsPane.sound, id: 'needs-you', order: 20, (c) {
    return SettingCard(
      title: 'When a worker needs you',
      scope: SettingScope.you,
      children: [
        ChoiceRow<NeedsYouSound>(
          options: const [
            (NeedsYouSound.once, '🔔 Ring once'),
            (NeedsYouSound.remind, '🔁 Keep reminding me'),
            (NeedsYouSound.off, '🔕 Off'),
          ],
          value: c.settings.needsYouSound,
          onPick: (v) {
            c.change((s) => s.needsYouSound = v);
            if (v != NeedsYouSound.off) _hooks?.previewNeedsYou();
          },
        ),
        const Note(
          'An alarm the moment a worker stops to ask you something or wants a permission. Keep reminding me rings it again, softly, every 30 seconds until someone opens that worker’s terminal. It’s as loud as the office sounds are.',
        ),
      ],
    );
  });
  cards.add(SettingsPane.sound, id: 'page-turns', order: 30, (c) {
    return SettingCard(
      title: 'Page turns at the bookshelf',
      scope: SettingScope.you,
      children: [
        ChoiceRow<bool>(
          options: const [(true, '📖 On'), (false, 'Off')],
          value: c.settings.pageTurns,
          onPick: (v) => c.change((s) => s.pageTurns = v),
        ),
        const Note(
          'A soft swish each time the book in your hands turns a page, as you open a doc or scroll through one. The 🔈 at the top of the bookshelf turns it off too.',
        ),
      ],
    );
  });
  cards.add(SettingsPane.sound, id: 'jukebox', order: 40, (c) {
    final s = c.settings;
    return SettingCard(
      title: 'Jukebox',
      scope: SettingScope.you,
      children: [
        VolumeRow(
          label: 'Jukebox volume',
          level: s.music,
          muted: s.musicMuted,
          onLevel: (v) => c.change(
            (s) => s
              ..music = v
              ..musicMuted = false,
          ),
          onMute: () => c.change((s) => s.musicMuted = !s.musicMuted),
        ),
        const Note(
          'The jukebox in the lounge. Everyone on the floor hears the same song, louder the closer they are to it; this is how loud it is for you alone.',
        ),
      ],
    );
  });
  cards.add(SettingsPane.sound, id: 'voice', order: 50, (c) {
    return SettingCard(
      title: 'Voice chat',
      scope: SettingScope.you,
      children: [
        ChoiceRow<bool>(
          options: const [(false, '🎙️ Open mic'), (true, '✋ Push to talk')],
          value: c.settings.pushToTalk,
          onPick: (v) => c.change((s) => s.pushToTalk = v),
        ),
        const Note(
          'Either way, V joins voice, holding V talks and you’re muted once you let go, and M mutes or unmutes. With push to talk you join muted. Leave voice from the ☰ menu.',
        ),
      ],
    );
  });

  // Notifications.
  cards.add(SettingsPane.notify, id: 'desktop', order: 10, (c) {
    final hooks = _hooks;
    if (hooks == null) return null;
    return _DesktopCard(c: c, notifier: hooks.notifier);
  });
  cards.add(SettingsPane.notify, id: 'webhook', order: 20, (c) => _WebhookCard(c: c));

  // Building. The map (C2's settings_map) goes in before the theme.
  cards.add(SettingsPane.building, id: 'theme', order: 20, (c) {
    final theme = c.store.theme;
    return SettingCard(
      title: 'Holiday theme',
      scope: SettingScope.office,
      children: [
        ChoiceRow<ThemePick>(
          options: [for (final p in themePicks) (p, _themeLabel[p]!)],
          value: theme.pick,
          onPick: (p) => c.net.send(ThemeSetCmd(p)),
        ),
        Note(themeNote(theme, ago: timeAgo)),
      ],
    );
  });
  // What the sky's doing, and which clock it keeps, for everyone (upstream's settings-sky.ts).
  cards.add(SettingsPane.building, id: 'outside', order: 30, topics: const [Topic.sky], (c) {
    final sky = c.store.sky;
    if (sky == null) return null;
    final real = sky.realTime == true;
    return SettingCard(
      title: 'Outside',
      scope: SettingScope.office,
      children: [
        Text(describeSky(sky, c.store.officeNow()), style: heavy(15)),
        ChoiceRow<bool>(
          options: const [(true, '🕰️ Real time (24 h)'), (false, '⏩ A day every hour')],
          value: real,
          onPick: (r) {
            if (r != real) c.net.send(SkyClockCmd(r));
          },
        ),
        Note(outsideNote(real: real, live: sky.city != null)),
      ],
    );
  });
  cards.add(SettingsPane.building, id: 'dog', order: 40, (c) => c.store.dog == null ? null : _DogCard(c: c));
  cards.add(SettingsPane.building, id: 'workspace', order: 50, (c) => _DirCard(c: c));

  // Workers.
  cards.add(SettingsPane.workers, id: 'default-worker', order: 10, (c) => _AgentCard(c: c));
  cards.add(SettingsPane.workers, id: 'limit', order: 20, (c) => _LimitCard(c: c));
  cards.add(SettingsPane.workers, id: 'leave-on-merge', order: 30, (c) {
    final l = c.store.leaveOnMerge;
    return SettingCard(
      title: 'Workers whose pull request merged',
      scope: SettingScope.office,
      children: [
        ChoiceRow<bool>(
          options: const [(true, '🏠 Go home by themselves'), (false, '🪑 Stay until sent home')],
          value: l.on,
          onPick: (v) => c.net.send(LeaveOnMergeSetCmd(v)),
        ),
        Note(leaveOnMergeNote(l, ago: timeAgo)),
      ],
    );
  });
  cards.add(SettingsPane.workers, id: 'prompts', order: 40, (c) {
    final admin = c.store.me.admin;
    final n = rewrittenPrompts(c.store);
    return SettingCard(
      title: 'Prompts',
      scope: SettingScope.office,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OfficeButton(
            key: const ValueKey('open-prompts'),
            label: admin ? '📝 Edit the prompts…' : '📝 Read the prompts…',
            onPressed: () => openPromptEditor(c.scope),
          ),
        ),
        Note(
          'What 🤖 Hand to a worker, 🔍 Review and the boards’ other buttons tell a worker, the note the queue adds to a task, the board agents’ briefs, the meeting room’s parts and the sign writer’s instructions. '
          '${n > 0 ? '$n of them rewritten.' : 'All as the office wrote them.'}'
          '${admin ? '' : ' Admins can rewrite them.'}',
        ),
      ],
    );
  });
}

/// Desktop notifications: this browser's permission, then your own on/off.
class _DesktopCard extends StatefulWidget {
  const _DesktopCard({required this.c, required this.notifier});
  final SettingsContext c;
  final DesktopNotifier notifier;

  @override
  State<_DesktopCard> createState() => _DesktopCardState();
}

class _DesktopCardState extends State<_DesktopCard> {
  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final perm = widget.notifier.permission;
    final on = perm == NotifyPermission.granted && c.settings.notify;
    final buttons = <Widget>[
      if (perm == NotifyPermission.ask)
        OfficeButton(
          label: '🔔 Turn on notifications',
          kind: BtnKind.primary,
          onPressed: () async {
            if (await widget.notifier.askPermission() == NotifyPermission.granted) {
              c.change((s) => s.notify = true);
              widget.notifier.sample();
            }
            if (mounted) setState(() {});
          },
        )
      else if (perm == NotifyPermission.granted) ...[
        OfficeButton(
          label: '🔔 On',
          kind: on ? BtnKind.on : BtnKind.plain,
          onPressed: () => c.change((s) => s.notify = true),
        ),
        OfficeButton(
          label: '🔕 Off',
          kind: !on ? BtnKind.on : BtnKind.plain,
          onPressed: () => c.change((s) => s.notify = false),
        ),
        if (on) OfficeButton(label: 'Show me one', onPressed: widget.notifier.sample),
      ],
    ];
    return SettingCard(
      title: 'Desktop notifications',
      scope: SettingScope.you,
      children: [
        if (buttons.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: buttons),
        Note(switch (perm) {
          NotifyPermission.unsupported when desktopApp => notInDesktopApp('Desktop notifications'),
          NotifyPermission.unsupported => 'This browser can’t show notifications from the office here. They need https or localhost (an SSH tunnel counts).',
          NotifyPermission.denied => 'Your browser blocks notifications from the office. Allow them in the site settings (the icon left of the address), then open this again.',
          _ => 'When a worker needs you or finishes while you’re in another tab or app, you get a notification. Click it to go straight to that worker: you’re put at its desk with its terminal open. The tab title counts the workers waiting on someone either way.',
        }),
      ],
    );
  }
}

/// The office's Slack / Discord webhook, shared by everyone.
class _WebhookCard extends StatefulWidget {
  const _WebhookCard({required this.c});
  final SettingsContext c;

  @override
  State<_WebhookCard> createState() => _WebhookCardState();
}

class _WebhookCardState extends State<_WebhookCard> {
  final _hook = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _hook.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final url = _hook.text.trim();
    if (url.isEmpty) return _focus.requestFocus();
    widget.c.net.send(NotifyWebhookCmd(url));
    _hook.clear();
  }

  @override
  Widget build(BuildContext context) {
    final net = widget.c.net;
    final n = widget.c.store.notify;
    final webhook = n.webhook;
    final error = n.error;
    final status = webhook == null
        ? 'Paste an incoming webhook from Slack or Discord, and the office posts to that channel when a worker needs input or finishes and nobody has its terminal open. It’s for everyone in the office.'
        : error != null
        ? '⚠️ Posting to ${_webhookName[webhook.kind]} (${webhook.hint}) failed: $error'
        : '📣 Posting to ${_webhookName[webhook.kind]} (${webhook.hint}), set by ${webhook.by} ${timeAgo(webhook.at)}${n.lastSentAt != null ? ' · last message ${timeAgo(n.lastSentAt!)}' : ''}.';
    return SettingCard(
      title: 'Team notifications (Slack / Discord)',
      scope: SettingScope.office,
      children: [
        Row(
          children: [
            Expanded(
              child: BoxInput(
                controller: _hook,
                focusNode: _focus,
                hint: 'https://hooks.slack.com/services/…',
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            OfficeButton(label: webhook != null ? 'Replace' : 'Save', kind: BtnKind.primary, onPressed: _save),
          ],
        ),
        if (webhook != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OfficeButton(label: 'Send a test', onPressed: () => net.send(const NotifyTestCmd())),
                OfficeButton(
                  label: 'Remove',
                  kind: BtnKind.danger,
                  onPressed: () => net.send(const NotifyWebhookCmd('')),
                ),
              ],
            ),
          ),
        Note(status, bad: error != null),
      ],
    );
  }
}

/// The dog on this floor, named for everyone here.
class _DogCard extends StatefulWidget {
  const _DogCard({required this.c});
  final SettingsContext c;

  @override
  State<_DogCard> createState() => _DogCardState();
}

class _DogCardState extends State<_DogCard> {
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
    final dog = widget.c.store.dog!;
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
        Note(
          '${dog.name} lives on this floor. When a worker needs input, ${dog.name} runs to its desk and barks. Walk up and press E to pet it. A new name is for everyone on this floor.',
        ),
      ],
    );
  }
}

/// Where the elevator clones new projects on the office's machine. Admins move it.
class _DirCard extends StatefulWidget {
  const _DirCard({required this.c});
  final SettingsContext c;

  @override
  State<_DirCard> createState() => _DirCardState();
}

class _DirCardState extends State<_DirCard> {
  final _dir = TextEditingController();
  final _focus = FocusNode();
  String? _shown;

  @override
  void dispose() {
    _dir.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final d = _dir.text.trim();
    if (d.isEmpty) return _focus.requestFocus();
    if (d != widget.c.store.projectsDir.dir) widget.c.net.send(FloorProjectsDirCmd(d));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final admin = c.store.me.admin;
    final dir = c.store.projectsDir;
    // The folder moved (here or by someone else): show where it is now.
    if (dir.dir != _shown) {
      _shown = dir.dir;
      _dir.text = dir.dir;
    }
    return SettingCard(
      title: 'Workspace folder',
      scope: SettingScope.office,
      children: [
        if (admin) ...[
          Row(
            children: [
              Expanded(
                child: BoxInput(
                  key: const ValueKey('dir-input'),
                  controller: _dir,
                  focusNode: _focus,
                  hint: '~/Workspace',
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              OfficeButton(label: 'Save', kind: BtnKind.primary, onPressed: _save),
            ],
          ),
          if (dir.custom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OfficeButton(
                  label: 'Use the default',
                  onPressed: () => c.net.send(const FloorProjectsDirCmd('')),
                ),
              ),
            ),
        ],
        Note(
          'New projects from the elevator are cloned into ${dir.dir}/<owner>/<repo> on the office’s machine.'
          '${dir.custom && dir.by != null && dir.at != null ? ' Set by ${dir.by} ${timeAgo(dir.at!)}.' : ''}'
          '${admin ? ' A checkout of the same repository that’s already there is used as it is. Floors you already have stay where they are.' : ' An admin can move it.'}',
        ),
      ],
    );
  }
}

/// The worker everyone starts on, unless whoever starts one picks another. Admins pick it.
class _AgentCard extends StatefulWidget {
  const _AgentCard({required this.c});
  final SettingsContext c;

  @override
  State<_AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<_AgentCard> {
  Store get store => widget.c.store;

  /// The default worker's fields (admins), on the default as it is until someone touches them.
  late final ProviderPickerController _agent = ProviderPickerController(
    store.project,
    office: store.prompts.agent,
    fields: true,
  )..addListener(_touched);
  bool _edited = false;
  bool _setting = false;
  Object? _seen;

  @override
  void initState() {
    super.initState();
    _seen = store.prompts.agent;
  }

  void _touched() {
    if (!_setting) _edited = true;
  }

  @override
  void dispose() {
    _agent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final net = widget.c.net;
    final admin = store.me.admin;
    final picked = store.prompts.agent;
    // The default worker changed (here or by someone else): the fields show it unless you're editing.
    if (!identical(picked, _seen)) {
      _seen = picked;
      if (!_edited) {
        _setting = true;
        _agent.office = picked;
        _agent.set(officeChoice(store.project, picked));
        _setting = false;
      }
    }
    return SettingCard(
      title: 'Default worker',
      scope: SettingScope.office,
      children: [
        if (admin) ...[
          ProviderPicker(controller: _agent, label: 'Provider'),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OfficeButton(
                  key: const ValueKey('agent-save'),
                  label: 'Save',
                  kind: BtnKind.primary,
                  onPressed: () {
                    if (!_agent.valid()) return;
                    _edited = false;
                    net.send(PromptsAgentCmd(_agent.choice()));
                  },
                ),
                if (picked != null)
                  OfficeButton(
                    label:
                        'Back to ${store.project?.agentCmd.split(' ').first.split(RegExp(r'[\\/]')).last ?? 'the --agent'}',
                    onPressed: () {
                      _edited = false;
                      net.send(const PromptsAgentCmd(null));
                    },
                  ),
              ],
            ),
          ),
        ] else
          Text(choiceLabel(officeChoice(store.project, picked)), style: heavy(15)),
        Note(
          'Every worker starts on this: hired at a desk, handed an issue or a pull request from the boards, taken off the queue, the board agents and meetings. Where you start one, ✏️ Edit picks another just for it.'
          '${picked != null ? ' Set by ${picked.by} ${timeAgo(picked.at)}.' : ' It’s the agent the office was started with, on its own default model.'}'
          '${admin ? '' : ' Admins can change it.'}',
        ),
      ],
    );
  }
}

/// The most workers the office runs at once, across every floor. Admins set it.
class _LimitCard extends StatefulWidget {
  const _LimitCard({required this.c});
  final SettingsContext c;

  @override
  State<_LimitCard> createState() => _LimitCardState();
}

class _LimitCardState extends State<_LimitCard> {
  final _limit = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _limit.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final v = parseLimit(_limit.text);
    if (v == null) return _focus.requestFocus();
    widget.c.net.send(MachineLimitCmd(v));
    _limit.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final admin = c.store.me.admin;
    final m = c.store.machine;
    return SettingCard(
      title: 'Worker limit',
      scope: SettingScope.office,
      children: [
        if (admin)
          Row(
            children: [
              Expanded(
                child: BoxInput(
                  key: const ValueKey('limit-input'),
                  controller: _limit,
                  focusNode: _focus,
                  hint: m.ceiling != null ? '1 to ${m.ceiling}' : 'e.g. 6',
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              OfficeButton(label: 'Set limit', kind: BtnKind.primary, onPressed: _save),
              if (m.set != null) ...[
                const SizedBox(width: 8),
                OfficeButton(
                  label: m.ceiling != null ? 'Back to ${m.ceiling}' : 'No limit',
                  onPressed: () => c.net.send(const MachineLimitCmd(null)),
                ),
              ],
            ],
          ),
        Note(limitNote(m, admin: admin, ago: timeAgo)),
      ],
    );
  }
}
