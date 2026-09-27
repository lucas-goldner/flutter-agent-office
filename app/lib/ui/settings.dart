// ⚙️ Settings: the camera, the volumes, desktop and team notifications, the dog's name, the sky,
// your character and signing out (ui/settings.ts).

import 'package:flutter/material.dart';

import '../notify.dart';
import '../office_scope.dart';
import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import '../world/player.dart' show ViewMode;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

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

const Map<WebhookKind, String> _webhookName = {
  WebhookKind.slack: 'Slack',
  WebhookKind.discord: 'Discord',
  WebhookKind.other: 'a webhook',
};

/// A copy to change, the way the TS spread `{ ...settings }`.
Settings _copy(Settings s) => Settings()
  ..view = s.view
  ..volume = s.volume
  ..muted = s.muted
  ..music = s.music
  ..musicMuted = s.musicMuted
  ..notify = s.notify;

/// `outside` describes the sky over the office (see describeSky), once the server has said.
ModalHandle openSettings(
  OfficeScope scope, {
  required Settings settings,
  required ValueChanged<Settings> onChange,
  required VoidCallback onCharacter,
  required VoidCallback previewSound,
  required DesktopNotifier notifier,
  required VoidCallback onSignOut,
  ({String now, bool live})? outside,
}) => ModalStack.instance.show(
  (modal) => _SettingsWindow(
    scope: scope,
    modal: modal,
    settings: _copy(settings),
    onChange: onChange,
    onCharacter: onCharacter,
    previewSound: previewSound,
    notifier: notifier,
    onSignOut: onSignOut,
    outside: outside,
  ),
);

class _SettingsWindow extends StatefulWidget {
  const _SettingsWindow({
    required this.scope,
    required this.modal,
    required this.settings,
    required this.onChange,
    required this.onCharacter,
    required this.previewSound,
    required this.notifier,
    required this.onSignOut,
    this.outside,
  });

  final OfficeScope scope;
  final ModalHandle modal;
  final Settings settings;
  final ValueChanged<Settings> onChange;
  final VoidCallback onCharacter;
  final VoidCallback previewSound;
  final DesktopNotifier notifier;
  final VoidCallback onSignOut;
  final ({String now, bool live})? outside;

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> with ListenTo {
  late Settings _s = widget.settings;
  final _hook = TextEditingController();
  final _hookFocus = FocusNode();
  final _dog = TextEditingController();
  final _dogFocus = FocusNode();

  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topics(const [Topic.notify, Topic.dog, Topic.me]), () => setState(() {}));
  }

  @override
  void dispose() {
    _hook.dispose();
    _hookFocus.dispose();
    _dog.dispose();
    _dogFocus.dispose();
    super.dispose();
  }

  void _change(void Function(Settings s) edit) {
    final next = _copy(_s);
    edit(next);
    setState(() => _s = next);
    widget.onChange(next);
  }

  void _saveHook() {
    final url = _hook.text.trim();
    if (url.isEmpty) return _hookFocus.requestFocus();
    widget.scope.net.send(NotifyWebhookCmd(url));
    _hook.clear();
  }

  void _renameDog() {
    final name = cleanDogName(_dog.text);
    if (name.isEmpty) return _dogFocus.requestFocus();
    widget.scope.net.send(DogNameCmd(name));
    _dog.clear();
  }

  @override
  Widget build(BuildContext context) {
    final account = store.me.account;
    final outside = widget.outside;
    return ModalWindow(
      modal: widget.modal,
      title: const Text('⚙️ Settings'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Camera view'),
          SegButtons<ViewMode>(
            small: false,
            gap: 8,
            options: [for (final (v, label, _) in _views) (v, label)],
            value: _s.view,
            onPick: (v) {
              if (_s.view != v) _change((s) => s.view = v);
            },
          ),
          Note(_views.firstWhere((v) => v.$1 == _s.view).$3),
          const FieldLabel('Office sounds', top: 18),
          _VolumeRow(
            label: 'Office sounds volume',
            level: _s.volume,
            muted: _s.muted,
            onLevel: (v) => _change(
              (s) => s
                ..volume = v
                ..muted = false,
            ),
            onMute: () {
              _change((s) => s.muted = !s.muted);
              if (!_s.muted) widget.previewSound();
            },
            onLetGo: widget.previewSound,
          ),
          const Note(
            'Workers typing, footsteps, the coffee machine, birds and rain outside, the dog, and the ding when a worker is done. Voice chat isn’t affected.',
          ),
          const FieldLabel('🎵 Jukebox', top: 18),
          _VolumeRow(
            label: 'Jukebox volume',
            level: _s.music,
            muted: _s.musicMuted,
            onLevel: (v) => _change(
              (s) => s
                ..music = v
                ..musicMuted = false,
            ),
            onMute: () => _change((s) => s.musicMuted = !s.musicMuted),
          ),
          const Note(
            'The jukebox in the lounge. Everyone on the floor hears the same song, louder the closer they are to it; this is how loud it is for you alone.',
          ),
          if (outside != null) ...[
            const FieldLabel('Outside', top: 18),
            Text(outside.now, style: heavy(15)),
            Note(
              outside.live ? 'Everyone sees the same sky: the office’s clock and the live weather where it is.' : 'Everyone sees the same sky: the office’s clock, and weather that comes and goes. Start the office with --city to use a real city’s forecast.',
            ),
          ],
          const FieldLabel('Desktop notifications', top: 18),
          ..._notifications(),
          const FieldLabel('Team notifications (Slack / Discord)', top: 18),
          ..._webhook(),
          ..._dogSection(),
          const FieldLabel('Your character', top: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: OfficeButton(
              label: account != null ? '🧍 Change your look' : '🧍 Change your look & name',
              onPressed: () {
                widget.modal.close();
                widget.onCharacter();
              },
            ),
          ),
          const FieldLabel('Signed in', top: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: OfficeButton(label: '🚪 Sign out', onPressed: widget.onSignOut),
          ),
          Note(
            account != null
                ? 'As ${account.name}, with your own account (${account.role.wire}).'
                : 'With the shared office password.',
          ),
        ],
      ),
    );
  }

  /// This browser's permission, then your own on/off.
  List<Widget> _notifications() {
    final perm = widget.notifier.permission;
    final on = perm == NotifyPermission.granted && _s.notify;
    final buttons = <Widget>[
      if (perm == NotifyPermission.ask)
        OfficeButton(
          label: '🔔 Turn on notifications',
          kind: BtnKind.primary,
          onPressed: () async {
            if (await widget.notifier.askPermission() == NotifyPermission.granted) {
              _change((s) => s.notify = true);
              widget.notifier.sample();
            }
            if (mounted) setState(() {});
          },
        )
      else if (perm == NotifyPermission.granted) ...[
        OfficeButton(
          label: '🔔 On',
          kind: on ? BtnKind.on : BtnKind.plain,
          onPressed: () => _change((s) => s.notify = true),
        ),
        OfficeButton(
          label: '🔕 Off',
          kind: !on ? BtnKind.on : BtnKind.plain,
          onPressed: () => _change((s) => s.notify = false),
        ),
        if (on) OfficeButton(label: 'Show me one', onPressed: widget.notifier.sample),
      ],
    ];
    return [
      if (buttons.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: buttons),
      Note(switch (perm) {
        NotifyPermission.unsupported => 'This browser can’t show notifications from the office here. They need https or localhost (an SSH tunnel counts).',
        NotifyPermission.denied => 'Your browser blocks notifications from the office. Allow them in the site settings (the icon left of the address), then open this again.',
        _ => 'When a worker needs input or finishes while you’re in another tab or app, you get a notification. Click it to jump to that worker’s terminal. The tab title counts the workers waiting on someone either way.',
      }),
    ];
  }

  /// The office's Slack / Discord webhook, shared by everyone.
  List<Widget> _webhook() {
    final n = store.notify;
    final webhook = n.webhook;
    final error = n.error;
    final status = webhook == null
        ? 'Paste an incoming webhook from Slack or Discord, and the office posts to that channel when a worker needs input or finishes and nobody has its terminal open. It’s for everyone in the office.'
        : error != null
        ? '⚠️ Posting to ${_webhookName[webhook.kind]} (${webhook.hint}) failed: $error'
        : '📣 Posting to ${_webhookName[webhook.kind]} (${webhook.hint}), set by ${webhook.by} ${timeAgo(webhook.at)}${n.lastSentAt != null ? ' · last message ${timeAgo(n.lastSentAt!)}' : ''}.';
    return [
      Row(
        children: [
          Expanded(
            child: BoxInput(
              controller: _hook,
              focusNode: _hookFocus,
              hint: 'https://hooks.slack.com/services/…',
              onSubmitted: (_) => _saveHook(),
            ),
          ),
          const SizedBox(width: 8),
          OfficeButton(label: webhook != null ? 'Replace' : 'Save', kind: BtnKind.primary, onPressed: _saveHook),
        ],
      ),
      if (webhook != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            children: [
              OfficeButton(label: 'Send a test', onPressed: () => widget.scope.net.send(const NotifyTestCmd())),
              OfficeButton(
                label: 'Remove',
                kind: BtnKind.danger,
                onPressed: () => widget.scope.net.send(const NotifyWebhookCmd('')),
              ),
            ],
          ),
        ),
      Note(status, bad: error != null),
    ];
  }

  /// The dog on this floor, named for everyone here.
  List<Widget> _dogSection() {
    final dog = store.dog;
    if (dog == null) return const [];
    return [
      const FieldLabel('Office dog', top: 18),
      Row(
        children: [
          Expanded(
            child: BoxInput(
              controller: _dog,
              focusNode: _dogFocus,
              maxLength: dogNameMax,
              hint: dog.name,
              onSubmitted: (_) => _renameDog(),
            ),
          ),
          const SizedBox(width: 8),
          OfficeButton(label: 'Rename', kind: BtnKind.primary, onPressed: _renameDog),
        ],
      ),
      Note(
        '${dog.name} lives on this floor. When a worker needs input, ${dog.name} runs to its desk and barks. Walk up and press E to pet it. A new name is for everyone on this floor.',
      ),
    ];
  }
}

/// A volume slider with its mute button. Dragging it turns the sound back on; letting go calls [onLetGo].
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
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
