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
import 'package:office_shared/rooftop.dart' show roof, roofName;
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'hud_parts.dart';
import 'limits.dart';
import 'menu.dart';
import 'modal.dart';
import 'provider.dart';
import 'theme.dart';
import 'title.dart';
import 'usage.dart';
import 'whereabouts.dart';

export 'hud_parts.dart' show CrosshairState, HintAside, HintCost, HintKey, HintPart, HintTitle;
export 'menu.dart' show HudAction, HudPrefs, HudSection, HudTone;

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
    this.onFloors,
    this.onTalk,
    this.onWalkTo,
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

  /// The project in the corner: the floors dropdown under it (else the elevator).
  final void Function(Rect? anchor)? onFloors;

  /// V in voice is push to talk: held down it's true, let go it's false. Without it V toggles voice.
  final bool Function(bool down)? onTalk;
  /// Clicking anyone else there: walk over to them (riding the elevator first if they're on another floor).
  final void Function(String peerId)? onWalkTo;
}

/// The HUD's keyboard: the office page calls these.
class HudController {
  HudController(this.callbacks, {HudPrefs? prefs}) : prefs = prefs ?? HudPrefs();

  final HudCallbacks callbacks;

  /// Your panels and pins, and the ☰ menu's actions.
  final HudPrefs prefs;

  /// On the ☰ button and the project, for the dropdowns to hang under.
  final GlobalKey menuKey = GlobalKey(debugLabel: 'menu');
  final GlobalKey projectKey = GlobalKey(debugLabel: 'project');

  /// Tab, or ☰.
  void toggleMenu() => toggleHudMenu(prefs, anchor: menuKey);

  /// The project in the corner: the floors dropdown under it.
  void floors() {
    final on = callbacks.onFloors;
    if (on == null) return callbacks.onElevator();
    final box = projectKey.currentContext?.findRenderObject();
    on(box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null);
  }

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

  /// The HUD's keys (T or Enter to chat, / to search, H for help, V voice, M mute, Tab the ☰ menu).
  /// True when the key was one of them. Call it only when no window is open and nobody is typing.
  bool handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.tab) {
      toggleMenu();
      return true;
    }
    // Joins voice; in it, it's push to talk (the office lets go of it on the key coming up).
    if (k == LogicalKeyboardKey.keyV && callbacks.onTalk != null && callbacks.onTalk!(true)) return true;
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
              child: _SidePanels(callbacks: cb, prefs: controller.prefs, speaking: speaking),
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
          child: _TopBar(controller: controller, voice: voice, hanging: hanging, narrow: narrow),
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
  const _TopBar({required this.controller, required this.voice, required this.hanging, required this.narrow});

  final HudController controller;
  final ValueListenable<VoiceState> voice;
  final ValueListenable<bool> hanging;
  final bool narrow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // The project name gives way (ellipsis) before the dock wraps.
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
            child: _ProjectPanel(key: controller.projectKey, prefs: controller.prefs, onTap: controller.floors),
          ),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth - 12 - (narrow ? 60 : 130)),
          child: Dock(
            prefs: controller.prefs,
            menuKey: controller.menuKey,
            narrow: narrow,
            extra: Listenable.merge([voice, hanging]),
            onMenu: controller.toggleMenu,
          ),
        ),
      ],
    ),
  );
}

/// The project in the corner is the floor you're on; click it for the others. Its details (branch,
/// folder, default agent) show when you turn them on.
class _ProjectPanel extends StatefulWidget {
  const _ProjectPanel({super.key, required this.prefs, required this.onTap});

  final HudPrefs prefs;
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
      listenable: Listenable.merge([
        widget.prefs,
        store.topics(const [Topic.project, Topic.floors, Topic.floor, Topic.prompts]),
      ]),
      builder: (context, _) {
        final p = store.project;
        final elsewhere = waitingElsewhere(store.floors, store.floor);
        final details = widget.prefs.panel(HudPanel.floor);
        final meta = projectMeta(
          project: p,
          floors: store.floors,
          floor: store.floor,
          defaultProvider: p == null ? '' : choiceLabel(officeChoice(p, store.prompts.agent)),
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
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('▾', style: heavy(14, color: Swatch.muted)),
                        ),
                      ],
                    ),
                    if (details)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: heavy(12, color: Swatch.muted, weight: FontWeight.w400),
                            ),
                          ),
                          PanelHide(prefs: widget.prefs, panel: HudPanel.floor),
                        ],
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

// ---- The side panels ------------------------------------------------------------------------------

class _SidePanels extends StatelessWidget {
  const _SidePanels({required this.callbacks, required this.prefs, this.speaking});

  final HudCallbacks callbacks;
  final HudPrefs prefs;
  final ValueListenable<Set<String>>? speaking;

  @override
  Widget build(BuildContext context) {
    final scope = OfficeScope.of(context);
    final store = scope.store;
    return ListenableBuilder(
      listenable: Listenable.merge([prefs, store.topics(const [Topic.limits, Topic.usage, Topic.workers])]),
      builder: (context, _) {
        final panels = <Widget>[
          if (prefs.panel(HudPanel.people))
            Flexible(
              child: _PeoplePanel(
                prefs: prefs,
                onEditProfile: callbacks.onEditProfile,
                onWalkTo: callbacks.onWalkTo,
                speaking: speaking,
              ),
            ),
          if (prefs.panel(HudPanel.workers)) Flexible(child: _WorkersPanel(prefs: prefs, onOpen: callbacks.onOpenWorker)),
          if (prefs.panel(HudPanel.spend)) _SpendPanel(prefs: prefs),
          if (prefs.panel(HudPanel.limits) && store.limits.windows.isNotEmpty)
            _LimitsPanel(prefs: prefs, limits: store.limits, onTap: () => scope.net.send(const LimitsRefreshCmd())),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, p) in panels.indexed) ...[if (i > 0) const SizedBox(height: 12), p],
          ],
        );
      },
    );
  }
}

/// A side panel's heading: "IN THE OFFICE 3".
class _PanelHeading extends StatelessWidget {
  const _PanelHeading(this.title, {this.count = '', this.trailing, this.hide});

  final String title;
  final String count;
  final Widget? trailing;

  /// Its ✕, which hides the panel until the ☰ menu turns it back on.
  final Widget? hide;

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
        if (trailing != null || hide != null) const Spacer(),
        ?trailing,
        ?hide,
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
  const _PeoplePanel({required this.prefs, required this.onEditProfile, this.onWalkTo, this.speaking});

  final HudPrefs prefs;
  final VoidCallback onEditProfile;
  final void Function(String peerId)? onWalkTo;
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
          heading: _PanelHeading(
            'In the office',
            count: '${peers.length}',
            hide: PanelHide(prefs: prefs, panel: HudPanel.people),
          ),
          children: [
            for (final (i, p) in peers.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                child: _PersonRow(p, store: store, speaking: talking.contains(p.id), onEditProfile: onEditProfile, onWalkTo: onWalkTo),
              ),
          ],
        );
      },
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow(this.p, {required this.store, required this.speaking, required this.onEditProfile, this.onWalkTo});

  final PeerInfo p;
  final Store store;
  final bool speaking;
  final VoidCallback onEditProfile;
  final void Function(String peerId)? onWalkTo;

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
      if (p.floor == roof) where = '🍸 $roofName';
    }
    final color = speaking ? Swatch.good : Swatch.ink;
    final sub = you ? null : whereabouts(p);
    Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          Dot(cssColor(p.color)),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(14, color: color, weight: FontWeight.w700),
                ),
                // What they have open, or where they are (see whereabouts).
                if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: heavy(11, color: Swatch.muted, weight: FontWeight.w700)),
              ],
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
    if (!you) {
      final walk = onWalkTo;
      final tip = '${store.onMyFloor(p) ? 'Walk over to' : 'Take the elevator to'} ${p.name}${sub != null ? ' ($sub)' : ''}';
      if (walk == null) return Tooltip(message: p.name, child: row);
      return Tooltip(
        message: tip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => walk(p.id), child: row),
        ),
      );
    }
    return Tooltip(
      message: 'Change your character',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onEditProfile, child: row),
      ),
    );
  }
}

/// "Workers": everyone at a desk, oldest first, with what they cost.
class _WorkersPanel extends StatelessWidget {
  const _WorkersPanel({required this.prefs, required this.onOpen});

  final HudPrefs prefs;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: store.topics(const [Topic.workers, Topic.usage, Topic.project]),
      builder: (context, _) {
        final workers = store.workers.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        final usage = summarizeUsage(store.usage, workers, store.project);
        // The board agents at their kiosks are listed but not counted.
        final hired = hiredCount(workers);
        return _SidePanel(
          heading: _PanelHeading(
            'Workers',
            count: hired == 0 ? '' : '$hired',
            hide: PanelHide(prefs: prefs, panel: HudPanel.workers),
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
          ],
        );
      },
    );
  }
}

/// "Spend": today, the budget and all time.
class _SpendPanel extends StatelessWidget {
  const _SpendPanel({required this.prefs});

  final HudPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: store.topics(const [Topic.workers, Topic.usage, Topic.project]),
      builder: (context, _) {
        final usage = summarizeUsage(store.usage, store.workers.values.toList(), store.project);
        return _SidePanel(
          heading: _PanelHeading('Spend', hide: PanelHide(prefs: prefs, panel: HudPanel.spend)),
          children: [
            if (usage.visible)
              UsagePanel(usage)
            else
              Text('Nothing spent yet', style: heavy(13, color: Swatch.muted, weight: FontWeight.w600)),
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
  final badge = agent ? modelBadge(kind, w.model, w.effort) : null;
  final note = state == ProviderUsageState.untracked
      ? ' · usage untracked'
      : state == ProviderUsageState.waiting && kind == AgentProvider.opencode
      ? ' · waiting for metrics'
      : state == ProviderUsageState.waiting && kind == AgentProvider.codex
      ? ' · waiting for first report'
      : '';
  final doing = [w.activity, w.title, w.prompt].firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
  return [
    if (provider != null) '⚙️ $provider${badge != null ? ' · $badge' : ''}$note',
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
  const _LimitsPanel({required this.prefs, required this.limits, required this.onTap});

  final HudPrefs prefs;
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
          child: Stack(
            children: [
              StreamBuilder(
                stream: Stream.periodic(const Duration(seconds: 30)),
                builder: (context, _) => LimitsView(limits),
              ),
              Positioned(top: 0, right: 0, child: PanelHide(prefs: prefs, panel: HudPanel.limits)),
            ],
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
  bool _hover = false;

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
    final prefs = widget.controller.prefs;
    final focused = _focus.hasFocus;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: c, width: 2),
    );
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        // Turned off, it's out of sight until T opens it.
        final shown = prefs.panel(HudPanel.chat) || focused;
        return IgnorePointer(
          ignoring: !shown,
          child: Opacity(
            opacity: shown ? 1 : 0,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: Panel(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListenableBuilder(
                      listenable: store.topic(Topic.chat),
                      builder: (context, _) => store.chat.isEmpty
                          ? const SizedBox.shrink()
                          // Lines fade after a while; hovering the chat or typing in it brings them back.
                          : ChatLog(List.of(store.chat), fade: !_hover && !focused, bottomGap: 6),
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
              ),
            ),
          ),
        );
      },
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
