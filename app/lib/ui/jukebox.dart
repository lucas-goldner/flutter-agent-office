// 🎵 The jukebox: what's on, the tunes to pick from, skip and stop, and a box for a stream
// (ui/jukebox.ts).

import 'package:flutter/material.dart';

import '../office_scope.dart';
import 'package:office_shared/jukebox.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// [openVolume] opens your own volume (⚙️ Settings).
ModalHandle openJukebox(OfficeScope scope, {required VoidCallback openVolume}) =>
    ModalStack.instance.show((modal) => _JukeboxWindow(scope: scope, modal: modal, openVolume: openVolume));

class _JukeboxWindow extends StatefulWidget {
  const _JukeboxWindow({required this.scope, required this.modal, required this.openVolume});
  final OfficeScope scope;
  final ModalHandle modal;
  final VoidCallback openVolume;

  @override
  State<_JukeboxWindow> createState() => _JukeboxWindowState();
}

class _JukeboxWindowState extends State<_JukeboxWindow> with ListenTo {
  final _url = TextEditingController();
  final _urlFocus = FocusNode();

  Store get store => widget.scope.store;
  void _send(ClientMsg m) => widget.scope.net.send(m);

  @override
  void initState() {
    super.initState();
    listenTo(store.topic(Topic.jukebox), () => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _play() {
    final u = checkStreamUrl(_url.text);
    if (u.error != null) {
      toast(u.error!, ToastKind.warn);
      return _urlFocus.requestFocus();
    }
    _send(JukeboxPlayCmd(url: u.url));
    _url.clear();
  }

  @override
  Widget build(BuildContext context) {
    final j = store.jukebox;
    return ModalWindow(
      modal: widget.modal,
      width: 520,
      title: const Text('🎵 Jukebox'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _nowPlaying(j),
          const FieldLabel('Put on a tune', top: 16),
          for (final t in jukeboxTunes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TuneRow(
                tune: t,
                playing: j.on && j.track == t.id,
                onPick: () {
                  if (!(j.on && j.track == t.id)) _send(JukeboxPlayCmd(track: t.id));
                },
              ),
            ),
          const FieldLabel('Or play a stream', top: 8),
          Row(
            children: [
              Expanded(
                child: BoxInput(
                  controller: _url,
                  focusNode: _urlFocus,
                  hint: 'https://… internet radio, or a link to an .mp3',
                  onSubmitted: (_) => _play(),
                ),
              ),
              const SizedBox(width: 8),
              OfficeButton(label: '📻 Play', kind: BtnKind.primary, onPressed: _play),
            ],
          ),
          const Note('Internet radio or an audio file. It plays from the jukebox, for everyone on this floor.'),
        ],
      ),
      footer: Row(
        children: [
          const FooterNote('Everyone on this floor hears the same song, louder the closer they are to the lounge.'),
          const SizedBox(width: 8),
          OfficeButton(
            label: '🔈 Your volume',
            onPressed: () {
              widget.modal.close();
              widget.openVolume();
            },
          ),
        ],
      ),
    );
  }

  Widget _nowPlaying(JukeboxState j) {
    final stream = j.track == jukeboxStream;
    final title = trackTitle(j.track, j.url);
    final meta = j.on
        ? [
            stream ? 'a stream' : tuneById(j.track)?.mood,
            if (j.by != null) 'put on by ${j.by}',
          ].whereType<String>().join(' · ')
        : j.by != null
        ? '${j.by} turned it off'
        : 'Pick a tune to put it on';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Swatch.paper2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink, width: kBorder),
      ),
      child: Row(
        children: [
          _Disc(stream ? '📻' : '💿', spinning: j.on),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  j.on ? title : 'The jukebox is off',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(16, weight: FontWeight.w900),
                ),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (j.on) ...[
            SmallButton(
              label: '⏭️ Skip',
              tooltip: 'On to the next tune',
              onPressed: () => _send(const JukeboxSkipCmd()),
            ),
            const SizedBox(width: 12),
            SmallButton(
              label: '⏹️ Stop',
              tooltip: 'Turn the jukebox off',
              onPressed: () => _send(const JukeboxStopCmd()),
            ),
          ] else
            SmallButton(
              label: '▶️ Play',
              kind: BtnKind.primary,
              tooltip: 'Put $title back on',
              onPressed: () => _send(const JukeboxPlayCmd()),
            ),
        ],
      ),
    );
  }
}

class _TuneRow extends StatefulWidget {
  const _TuneRow({required this.tune, required this.playing, required this.onPick});
  final JukeboxTune tune;
  final bool playing;
  final VoidCallback onPick;

  @override
  State<_TuneRow> createState() => _TuneRowState();
}

class _TuneRowState extends State<_TuneRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tune;
    return Tooltip(
      message: widget.playing ? 'Playing now' : 'Put on ${t.title}',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPick,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: widget.playing || _hover ? Swatch.paper2 : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: widget.playing ? Swatch.accent : Swatch.ink, width: kBorder),
              boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
            ),
            child: Row(
              children: [
                Text(widget.playing ? '🔊' : '🎵', style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(16, weight: FontWeight.w900),
                      ),
                      Text(
                        t.mood,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The record, turning while something plays (unless the system asks for less motion).
class _Disc extends StatefulWidget {
  const _Disc(this.emoji, {required this.spinning});
  final String emoji;
  final bool spinning;

  @override
  State<_Disc> createState() => _DiscState();
}

class _DiscState extends State<_Disc> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.spinning && !calm) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
    return RotationTransition(
      turns: _c,
      child: Text(widget.emoji, style: const TextStyle(fontSize: 30, height: 1)),
    );
  }
}
