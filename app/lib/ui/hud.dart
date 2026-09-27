// The HUD over the office: the top bar (the project/elevator panel and the buttons), the people
// and workers panels, the chat, toasts, banners, the hint bar, the crosshair and the coffee meter.
// A port of index.html's #hud, ui/hud.ts and the HUD parts of main.ts.
//
// The office page owns the keyboard: it calls [HudController.handleKey] for the HUD's own keys
// (T/Enter chat, / search, H help, V/M voice) and feeds the frame loop's state in through the
// ValueListenables (hint, crosshair, voice, connection).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../caffeine.dart';
import '../interop/browser.dart';
import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'hud_parts.dart';
import 'limits.dart';
import 'modal.dart';
import 'provider.dart';
import 'theme.dart';
import 'title.dart';
import 'usage.dart';

export 'hud_parts.dart' show CrosshairState, HintAside, HintCost, HintKey, HintPart, HintTitle;

/// Voice chat and screen sharing, as the buttons show them.
@immutable
class VoiceState {
  const VoiceState({this.inVoice = false, this.muted = false, this.sharing = false, this.available = true});

  final bool inVoice;
  final bool muted;
  final bool sharing;

  /// False outside a secure context (https or localhost), where the browser has no microphone.
  final bool available;

  @override
  bool operator ==(Object other) =>
      other is VoiceState &&
      other.inVoice == inVoice &&
      other.muted == muted &&
      other.sharing == sharing &&
      other.available == available;
  @override
  int get hashCode => Object.hash(inVoice, muted, sharing, available);
}

/// What the top bar's buttons and panels do. Each is the old main.ts handler of the same name.
class HudCallbacks {
  const HudCallbacks({
    required this.onElevator,
    required this.onVoice,
    required this.onMute,
    required this.onShare,
    required this.onIssues,
    required this.onPulls,
    required this.onServices,
    required this.onQueue,
    required this.onTeam,
    required this.onAccounts,
    required this.onUpgrade,
    required this.onSearch,
    required this.onWhiteboard,
    required this.onDecor,
    required this.onSettings,
    required this.onHelp,
    required this.onOpenWorker,
    required this.onEditProfile,
  });

  final VoidCallback onElevator;
  final VoidCallback onVoice;
  final VoidCallback onMute;
  final VoidCallback onShare;
  final VoidCallback onIssues;
  final VoidCallback onPulls;
  final VoidCallback onServices;
  final VoidCallback onQueue;
  final VoidCallback onTeam;
  final VoidCallback onAccounts;
  final VoidCallback onUpgrade;
  final VoidCallback onSearch;
  final VoidCallback onWhiteboard;

  /// 🖼️: start hanging a picture, or stop.
  final VoidCallback onDecor;
  final VoidCallback onSettings;
  final VoidCallback onHelp;
  final void Function(String workerId) onOpenWorker;

  /// Clicking yourself in the people list.
  final VoidCallback onEditProfile;
}

/// The HUD's keyboard: the office page calls these.
class HudController {
  HudController(this.callbacks);

  final HudCallbacks callbacks;

  /// The chat box's focus; while it has it, keys are for typing.
  final FocusNode chatFocus = FocusNode(debugLabel: 'chat');

  bool get typing => chatFocus.hasFocus;

  /// T / Enter.
  void focusChat() => chatFocus.requestFocus();
  void blurChat() => chatFocus.unfocus();

  /// /
  void search() => callbacks.onSearch();

  /// H
  void help() => callbacks.onHelp();

  /// V
  void toggleVoice() => callbacks.onVoice();

  /// M
  void toggleMute() => callbacks.onMute();

  /// The HUD's keys (T or Enter to chat, / to search, H for help, V voice, M mute). True when the
  /// key was one of them. Call it only when no window is open and nobody is typing.
  bool handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyT || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      focusChat();
      return true;
    }
    if (k == LogicalKeyboardKey.keyV) {
      toggleVoice();
      return true;
    }
    if (k == LogicalKeyboardKey.keyM) {
      toggleMute();
      return true;
    }
    if (k == LogicalKeyboardKey.keyH) {
      help();
      return true;
    }
    // By the character, so it's / on any keyboard layout.
    if (e.character == '/') {
      search();
      return true;
    }
    return false;
  }

  void dispose() => chatFocus.dispose();
}

class Hud extends StatelessWidget {
  const Hud({
    super.key,
    required this.controller,
    required this.voice,
    required this.connected,
    required this.hint,
    required this.crosshair,
    required this.hanging,
    required this.caffeine,
    required this.clock,
    this.speaking,
    this.shares,
  });

  final HudController controller;
  final ValueListenable<VoiceState> voice;

  /// The socket is up; false shows "Reconnecting…".
  final ValueListenable<bool> connected;

  /// What the hint bar says; null hides it.
  final ValueListenable<List<HintPart>?> hint;
  final ValueListenable<CrosshairState> crosshair;

  /// Hanging a picture: the 🖼️ button is on.
  final ValueListenable<bool> hanging;
  final Caffeine caffeine;

  /// Seconds, on the clock coffee is drunk on.
  final double Function() clock;

  /// Peer ids talking right now.
  final ValueListenable<Set<String>>? speaking;

  /// The screen-share thumbnails, from whoever owns voice.
  final Widget? shares;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width <= 800;
    final cb = controller.callbacks;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Center(
            child: ValueListenableBuilder(valueListenable: crosshair, builder: (_, s, _) => Crosshair(s)),
          ),
        ),
        Positioned(
          left: 12,
          top: 90,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CaffeineMeter(caffeine: caffeine, clock: clock, gapBelow: 16),
              ?shares,
            ],
          ),
        ),
        if (!narrow)
          Positioned(
            top: 90,
            right: 12,
            width: 250,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height - 110),
              child: _SidePanels(callbacks: cb, speaking: speaking),
            ),
          ),
        Positioned(
          left: 12,
          bottom: 12,
          width: narrow ? size.width - 24 : 330,
          child: _Chat(controller: controller),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: narrow ? 190 : 28,
          child: Center(
            child: ListenableBuilder(
              listenable: Listenable.merge([hint, ModalStack.instance.changes]),
              builder: (_, _) {
                final parts = hint.value;
                return parts == null || parts.isEmpty || ModalStack.instance.open
                    ? const SizedBox.shrink()
                    : HintBar(parts);
              },
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: _TopBar(callbacks: cb, voice: voice, hanging: hanging, narrow: narrow),
        ),
        const Positioned(top: 90, left: 0, right: 0, child: Center(child: ToastLayer())),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Center(child: _Banners(connected: connected)),
        ),
      ],
    );
  }
}

// ---- The top bar -----------------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.callbacks, required this.voice, required this.hanging, required this.narrow});

  final HudCallbacks callbacks;
  final ValueListenable<VoiceState> voice;
  final ValueListenable<bool> hanging;
  final bool narrow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // The project name gives way (ellipsis) before the buttons wrap under the side panel.
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
            child: _ProjectPanel(onTap: callbacks.onElevator),
          ),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          // The project keeps room for its name (the CSS would squeeze it to nothing).
          constraints: BoxConstraints(maxWidth: box.maxWidth - 12 - (narrow ? 60 : 130)),
          child: _Controls(callbacks: callbacks, voice: voice, hanging: hanging, narrow: narrow),
        ),
      ],
    ),
  );
}

/// The project in the corner is the floor you're on; click it for the others.
class _ProjectPanel extends StatefulWidget {
  const _ProjectPanel({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<_ProjectPanel> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: store.topics(const [Topic.project, Topic.floors, Topic.floor]),
      builder: (context, _) {
        final p = store.project;
        final elsewhere = waitingElsewhere(store.floors, store.floor);
        final meta = projectMeta(
          project: p,
          floors: store.floors,
          floor: store.floor,
          defaultProvider: p == null ? '' : providerLabel(p.defaultProvider, p),
        );
        return Tooltip(
          message: projectTooltip(elsewhere),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: Panel(
                color: _hover ? Swatch.paper2 : Swatch.paper,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '🏢 ${p?.name ?? 'Agent Office'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: heavy(18, weight: FontWeight.w900),
                          ),
                        ),
                        if (elsewhere > 0) CountBadge(elsewhere),
                      ],
                    ),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: heavy(12, color: Swatch.muted, weight: FontWeight.w400),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.callbacks, required this.voice, required this.hanging, required this.narrow});

  final HudCallbacks callbacks;
  final ValueListenable<VoiceState> voice;
  final ValueListenable<bool> hanging;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    final cb = callbacks;
    return Panel(
      padding: const EdgeInsets.all(8),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          voice,
          hanging,
          store.topics(const [Topic.me, Topic.upgrade, Topic.services, Topic.queue, Topic.floors]),
        ]),
        builder: (context, _) {
          final v = voice.value;
          final noVoice = desktopApp
              ? notInDesktopApp('Voice chat and screen sharing')
              : 'Voice and screen sharing need HTTPS or localhost — use a TLS proxy, --self-signed, or an SSH tunnel';
          final u = store.upgrade;
          final services = store.services.items.length;
          final queued = store.queue.tasks.where((t) => t.status != TaskStatus.done).length;
          final hangingNow = hanging.value;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              _TopButton(
                icon: '🎙️',
                label: v.inVoice ? 'Leave voice' : 'Join voice',
                kind: v.inVoice ? BtnKind.on : BtnKind.plain,
                tooltip: v.available ? 'Join voice (V)' : noVoice,
                dim: !v.available,
                narrow: narrow,
                onTap: cb.onVoice,
              ),
              if (v.inVoice)
                _TopButton(
                  icon: v.muted ? '🔇' : '🎙️',
                  kind: v.muted ? BtnKind.danger : BtnKind.plain,
                  tooltip: 'Mute (M)',
                  onTap: cb.onMute,
                ),
              _TopButton(
                icon: '🖥️',
                label: v.sharing ? 'Stop sharing' : 'Share screen',
                kind: v.sharing ? BtnKind.on : BtnKind.plain,
                tooltip: v.available ? 'Share your screen' : noVoice,
                dim: !v.available,
                narrow: narrow,
                onTap: cb.onShare,
              ),
              _TopButton(icon: '📌', label: 'Issues', tooltip: 'Issues board', onTap: cb.onIssues, narrow: narrow),
              _TopButton(icon: '🔀', label: 'PRs', tooltip: 'Pull requests board', onTap: cb.onPulls, narrow: narrow),
              _TopButton(
                icon: '🌐',
                label: 'Services',
                count: services,
                tooltip: 'Web servers the workers are running',
                onTap: cb.onServices,
                narrow: narrow,
              ),
              _TopButton(
                icon: '📋',
                label: 'Queue',
                count: queued,
                tooltip: 'Task queue: issues and tasks waiting for a worker',
                onTap: cb.onQueue,
                narrow: narrow,
              ),
              if (store.invites)
                _TopButton(icon: '👥', label: 'Invite', tooltip: 'Invite teammates', onTap: cb.onTeam, narrow: narrow),
              if (store.me.admin)
                _TopButton(
                  icon: '🔑',
                  label: 'Accounts',
                  tooltip: 'Accounts: invite people, see who has one, revoke them',
                  onTap: cb.onAccounts,
                  narrow: narrow,
                ),
              if (u.available)
                _TopButton(
                  icon: u.phase == UpgradePhase.building
                      ? '🛠️ Upgrading…'
                      : u.latest != null
                      ? '⬆️ Update'
                      : '⬆️',
                  kind: u.latest != null && u.phase != UpgradePhase.building ? BtnKind.primary : BtnKind.plain,
                  tooltip: u.latest != null ? 'New version: ${u.latest!.subject}' : 'Upgrade the office',
                  onTap: cb.onUpgrade,
                ),
              _TopButton(icon: '🔎', tooltip: 'Search the chat and every terminal (/)', onTap: cb.onSearch),
              _TopButton(icon: '📝', tooltip: 'Whiteboard: draw together, live', onTap: cb.onWhiteboard),
              _TopButton(
                icon: '🖼️',
                kind: hangingNow ? BtnKind.on : BtnKind.plain,
                tooltip: hangingNow ? 'Stop hanging the picture (Esc)' : 'Hang a picture on a wall (F)',
                onTap: cb.onDecor,
              ),
              _TopButton(icon: '⚙️', tooltip: 'Settings', onTap: cb.onSettings),
              _TopButton(icon: '❓', tooltip: 'Controls (H)', onTap: cb.onHelp),
            ],
          );
        },
      ),
    );
  }
}

/// A top-bar .btn: an emoji, a label that hides on a phone, and maybe a count.
class _TopButton extends StatefulWidget {
  const _TopButton({
    required this.icon,
    required this.onTap,
    this.label,
    this.kind = BtnKind.plain,
    this.tooltip,
    this.count = 0,
    this.dim = false,
    this.narrow = false,
  });

  final String icon;
  final String? label;
  final VoidCallback onTap;
  final BtnKind kind;
  final String? tooltip;
  final int count;
  final bool dim;
  final bool narrow;

  @override
  State<_TopButton> createState() => _TopButtonState();
}

class _TopButtonState extends State<_TopButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (Swatch.accent, Colors.white),
      BtnKind.on => (Swatch.good, Colors.white),
      BtnKind.danger => (Swatch.bad, Colors.white),
      BtnKind.plain => (_hover ? Swatch.paper2 : Colors.white, Swatch.ink),
    };
    final style = heavy(14, color: fg);
    final label = widget.label;
    Widget b = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Opacity(
          opacity: widget.dim ? 0.55 : 1,
          child: Container(
            transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Swatch.ink, width: kBorder),
              boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, _down ? 1 : 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.icon, style: style),
                if (label != null && !widget.narrow) ...[const SizedBox(width: 6), Text(label, style: style)],
                if (widget.count > 0) CountBadge(widget.count),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

// ---- The side panels ------------------------------------------------------------------------------

class _SidePanels extends StatelessWidget {
  const _SidePanels({required this.callbacks, this.speaking});

  final HudCallbacks callbacks;
  final ValueListenable<Set<String>>? speaking;

  @override
  Widget build(BuildContext context) {
    final scope = OfficeScope.of(context);
    final store = scope.store;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: _PeoplePanel(onEditProfile: callbacks.onEditProfile, speaking: speaking),
        ),
        const SizedBox(height: 12),
        Flexible(child: _WorkersPanel(onOpen: callbacks.onOpenWorker)),
        ListenableBuilder(
          listenable: store.topic(Topic.limits),
          builder: (context, _) => store.limits.windows.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _LimitsPanel(limits: store.limits, onTap: () => scope.net.send(const LimitsRefreshCmd())),
                ),
        ),
      ],
    );
  }
}

/// A side panel's heading: "IN THE OFFICE 3".
class _PanelHeading extends StatelessWidget {
  const _PanelHeading(this.title, {this.count = '', this.trailing});

  final String title;
  final String count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(title.toUpperCase(), style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.56)),
        if (count.isNotEmpty) ...[
          const SizedBox(width: 5),
          Text(
            count,
            style: heavy(14, color: Swatch.muted, weight: FontWeight.w700).copyWith(letterSpacing: 0.56),
          ),
        ],
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    ),
  );
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.heading, required this.children});

  final Widget heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [heading, ...children],
      ),
    ),
  );
}

/// "In the office": you first, then everyone by name.
class _PeoplePanel extends StatelessWidget {
  const _PeoplePanel({required this.onEditProfile, this.speaking});

  final VoidCallback onEditProfile;
  final ValueListenable<Set<String>>? speaking;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: Listenable.merge([
        store.topics(const [Topic.peers, Topic.floors, Topic.floor]),
        ?speaking,
      ]),
      builder: (context, _) {
        final peers = store.peers.values.toList()
          ..sort(
            (a, b) => a.id == store.you
                ? -1
                : b.id == store.you
                ? 1
                : a.name.compareTo(b.name),
          );
        final talking = speaking?.value ?? const <String>{};
        return _SidePanel(
          heading: _PanelHeading('In the office', count: '${peers.length}'),
          children: [
            for (final (i, p) in peers.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                child: _PersonRow(p, store: store, speaking: talking.contains(p.id), onEditProfile: onEditProfile),
              ),
          ],
        );
      },
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow(this.p, {required this.store, required this.speaking, required this.onEditProfile});

  final PeerInfo p;
  final Store store;
  final bool speaking;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    final you = p.id == store.you;
    final mic = !p.voice
        ? ''
        : p.muted
        ? '🔇'
        : '🎙️';
    String? where;
    if (!you && !store.onMyFloor(p)) {
      where = '🛗 lobby';
      for (final f in store.floors) {
        if (f.id == p.floor) where = '🛗 ${f.name}';
      }
    }
    final color = speaking ? Swatch.good : Swatch.ink;
    Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          Dot(cssColor(p.color)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: heavy(14, color: color, weight: FontWeight.w700),
            ),
          ),
          if (p.account == true) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'Signed in with ${you ? 'your' : 'their'} own account',
              child: Text(
                '✓',
                style: heavy(11, color: Swatch.good, weight: FontWeight.w900),
              ),
            ),
          ],
          if (you) ...[
            const SizedBox(width: 8),
            Text(
              '(you)',
              style: heavy(14, color: Swatch.muted, weight: FontWeight.w600),
            ),
          ],
          if (where != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Tooltip(
                message: 'On another floor',
                child: Text(
                  where,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(11, color: Swatch.muted),
                ),
              ),
            ),
          ],
          if (p.sharing) ...[const SizedBox(width: 8), const Tooltip(message: 'Sharing screen', child: Text('🖥️'))],
          const Spacer(),
          Text(mic, style: heavy(12)),
        ],
      ),
    );
    if (!you) return Tooltip(message: p.name, child: row);
    return Tooltip(
      message: 'Change your character',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onEditProfile, child: row),
      ),
    );
  }
}

/// "Workers": everyone at a desk, oldest first, with what they cost and the office's spend under them.
class _WorkersPanel extends StatelessWidget {
  const _WorkersPanel({required this.onOpen});

  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: store.topics(const [Topic.workers, Topic.usage, Topic.project]),
      builder: (context, _) {
        final workers = store.workers.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        final usage = summarizeUsage(store.usage, workers, store.project);
        return _SidePanel(
          heading: _PanelHeading(
            'Workers',
            count: workers.isEmpty ? '' : '${workers.length}',
            trailing: usage.headCost.isEmpty
                ? null
                : Tooltip(
                    message: 'Spent by the workers at their desks',
                    child: Text(
                      usage.headCost,
                      style: heavy(
                        12,
                        color: Swatch.muted,
                      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
          ),
          children: [
            for (final (i, w) in workers.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                child: _WorkerRow(w, project: store.project, onOpen: onOpen),
              ),
            if (workers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Text(
                  'Walk up to a desk and press E to hire one',
                  style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
                ),
              ),
            UsagePanel(usage),
          ],
        );
      },
    );
  }
}

/// The line under a worker's name: provider, branch, PR, and what it's doing.
String workerSub(WorkerInfo w, ProjectInfo? project) {
  final agent = w.kind == WorkerKind.agent;
  final provider = agent ? providerLabel(w.provider, project) : null;
  final kind = agent ? resolvedProvider(w.provider, project) : null;
  final state = agent ? providerUsageState(w.provider, project, w.usage) : null;
  final note = state == ProviderUsageState.untracked
      ? ' · usage untracked'
      : state == ProviderUsageState.waiting && kind == AgentProvider.opencode
      ? ' · waiting for metrics'
      : state == ProviderUsageState.waiting && kind == AgentProvider.codex
      ? ' · waiting for first report'
      : '';
  final doing = [w.activity, w.title, w.prompt].firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
  return [
    if (provider != null) '⚙️ $provider$note',
    if (w.worktree != null) '🌿 ${w.worktree!.branch}',
    if (w.pr != null) '🔀 PR #${w.pr!.number}',
    ?doing,
  ].join(' · ');
}

class _WorkerRow extends StatefulWidget {
  const _WorkerRow(this.w, {required this.project, required this.onOpen});

  final WorkerInfo w;
  final ProjectInfo? project;
  final void Function(String id) onOpen;

  @override
  State<_WorkerRow> createState() => _WorkerRowState();
}

class _WorkerRowState extends State<_WorkerRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.w;
    final sub = workerSub(w, widget.project);
    final agent = w.kind == WorkerKind.agent;
    final kind = agent ? resolvedProvider(w.provider, widget.project) : AgentProvider.claude;
    final tracked =
        agent &&
        providerUsageState(w.provider, widget.project, w.usage) == ProviderUsageState.tracked &&
        w.usage != null;
    return Tooltip(
      message: "Open ${w.name}'s terminal",
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => widget.onOpen(w.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(color: _hover ? Swatch.paper2 : null, borderRadius: BorderRadius.circular(8)),
            child: Row(
              children: [
                Dot(cssColor(w.color)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: heavy(14, weight: FontWeight.w700),
                      ),
                      if (sub.isNotEmpty)
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: heavy(11, color: Swatch.muted, weight: FontWeight.w600),
                        ),
                      if (tracked)
                        Tooltip(
                          message: usageTitle(w.usage!, kind),
                          child: Text(
                            usageLabel(w.usage!, kind),
                            style: heavy(
                              11,
                              color: Swatch.muted,
                            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(w.status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LimitsPanel extends StatelessWidget {
  const _LimitsPanel({required this.limits, required this.onTap});

  final PlanLimits limits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Read again now',
    waitDuration: const Duration(milliseconds: 800),
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Panel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          // The reset countdowns tick down between reads.
          child: StreamBuilder(
            stream: Stream.periodic(const Duration(seconds: 30)),
            builder: (context, _) => LimitsView(limits),
          ),
        ),
      ),
    ),
  );
}

// ---- The chat ------------------------------------------------------------------------------------

class _Chat extends StatefulWidget {
  const _Chat({required this.controller});

  final HudController controller;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final _input = TextEditingController();

  FocusNode get _focus => widget.controller.chatFocus;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_repaint);
  }

  void _repaint() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_repaint);
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isNotEmpty) OfficeScope.read(context).net.send(ChatCmd(text));
    _input.clear();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    final focused = _focus.hasFocus;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: c, width: 2),
    );
    return Panel(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: store.topic(Topic.chat),
            builder: (context, _) => store.chat.isEmpty
                ? const SizedBox.shrink()
                : Padding(padding: const EdgeInsets.only(bottom: 6), child: ChatLog(List.of(store.chat))),
          ),
          CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus},
            child: TextField(
              controller: _input,
              focusNode: _focus,
              maxLength: 500,
              autocorrect: false,
              enableSuggestions: false,
              style: heavy(14, weight: FontWeight.w400),
              cursorColor: Swatch.ink,
              decoration: InputDecoration(
                hintText: 'Press T to chat',
                hintStyle: heavy(14, color: Swatch.muted, weight: FontWeight.w400),
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                border: border(Swatch.ink),
                enabledBorder: border(Swatch.ink),
                focusedBorder: border(focused ? Swatch.accent : Swatch.ink),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Banners -------------------------------------------------------------------------------------

class _Banners extends StatelessWidget {
  const _Banners({required this.connected});

  final ValueListenable<bool> connected;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: Listenable.merge([connected, store.topic(Topic.upgrade)]),
      builder: (context, _) {
        final u = store.upgrade;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!connected.value) const ConnBanner('Reconnecting…'),
            if (u.phase == UpgradePhase.building)
              ConnBanner(
                '🛠️ ${u.by ?? 'Someone'} is upgrading the office. It restarts on the new version in a minute or two.',
                upgrading: true,
              ),
          ],
        );
      },
    );
  }
}

// ---- Watchers: the tab title and the floors waiting ---------------------------------------------------

/// Keeps the tab title counting the workers waiting on someone (renderTitle in main.ts). Returns a remover.
VoidCallback watchTabTitle(Store store) {
  void render() => documentTitle = officeTitle(
    project: store.project?.name,
    floors: store.floors,
    floor: store.floor,
    workers: store.workers.values,
  );
  final l = store.topics(const [Topic.workers, Topic.floors, Topic.floor, Topic.project]);
  l.addListener(render);
  render();
  return () => l.removeListener(render);
}

/// Someone's waiting on another floor: say so, since you can't see or hear it from here (noticeWaiting
/// in main.ts). [ding] plays the needs-input sound. Returns a remover.
VoidCallback watchFloorsWaiting(Store store, {VoidCallback? ding}) {
  final watch = FloorWaitWatch();
  void check() {
    for (final f in watch.update(store.floors, store.floor)) {
      toast('🙋 A worker on the ${f.name} floor is waiting on someone — take the elevator up', ToastKind.warn);
      ding?.call();
    }
  }

  final l = store.topics(const [Topic.floors, Topic.floor]);
  l.addListener(check);
  check();
  return () => l.removeListener(check);
}
