// The HUD's small pieces that don't need the store: the hint bar, the crosshair, the caffeine
// meter, the chat log, status pills and the banners. hud.dart puts them together over the office.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../caffeine.dart';
import '../shared/protocol.dart';
import 'theme.dart';

/// Parses '#rrggbb' (or '#rgb'); grey for anything else.
Color cssColor(String hex) {
  var h = hex.startsWith('#') ? hex.substring(1) : hex;
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  final v = int.tryParse(h, radix: 16);
  return v == null || h.length != 6 ? const Color(0xFF888888) : Color(0xFF000000 | v);
}

// ---- Status pills --------------------------------------------------------------------------------

const Map<WorkerStatus, String> statusLabels = {
  WorkerStatus.starting: 'starting',
  WorkerStatus.idle: 'ready',
  WorkerStatus.working: 'working',
  WorkerStatus.needsInput: 'needs input',
  WorkerStatus.done: 'done',
  WorkerStatus.exited: 'exited',
  WorkerStatus.offline: 'asleep',
};

String statusLabel(WorkerStatus s) => statusLabels[s]!;

/// The .pill for a worker's status; needs input pulses.
class StatusPill extends StatefulWidget {
  const StatusPill(this.status, {super.key});

  final WorkerStatus status;

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusPill old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.status == WorkerStatus.needsInput) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (widget.status) {
      WorkerStatus.starting || WorkerStatus.idle => (const Color(0xFFE0F2FE), Swatch.ink),
      WorkerStatus.working => (Swatch.warn, Swatch.ink),
      WorkerStatus.needsInput => (Swatch.bad, Colors.white),
      WorkerStatus.done => (Swatch.good, Colors.white),
      WorkerStatus.exited || WorkerStatus.offline => (const Color(0xFFDEE2E6), Swatch.ink),
    };
    final pill = Pill(statusLabel(widget.status), color: bg, textColor: fg);
    if (widget.status != WorkerStatus.needsInput) return pill;
    // @keyframes pulse { 50% { transform: scale(1.08) } }
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Transform.scale(scale: 1 + 0.08 * math.sin(_pulse.value * math.pi), child: child),
      child: pill,
    );
  }
}

/// The accent count bubble next to a button's label (.svc-count).
class CountBadge extends StatelessWidget {
  const CountBadge(this.n, {super.key});

  final int n;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 7),
    decoration: BoxDecoration(color: Swatch.accent, borderRadius: BorderRadius.circular(999)),
    child: Text('$n', style: heavy(12, color: Colors.white)),
  );
}

// ---- The hint bar --------------------------------------------------------------------------------

/// One piece of the hint bar: see [HintTitle], [HintKey], [HintAside], [HintCost].
sealed class HintPart {
  const HintPart();
}

/// What you're facing, in yellow.
class HintTitle extends HintPart {
  const HintTitle(this.text);
  final String text;
}

/// A key and what it does.
class HintKey extends HintPart {
  const HintKey(this.keyName, this.label);
  final String keyName;
  final String label;
}

/// Secondary text.
class HintAside extends HintPart {
  const HintAside(this.text);
  final String text;
}

/// Money, in pale blue.
class HintCost extends HintPart {
  const HintCost(this.text, {this.tooltip});
  final String text;
  final String? tooltip;
}

/// The .key: a paper keycap.
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key, this.size = 15});

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 26),
    margin: const EdgeInsets.only(right: 5),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: Swatch.paper,
      borderRadius: BorderRadius.circular(7),
      boxShadow: const [BoxShadow(color: Color(0xFF999999), offset: Offset(0, 2))],
    ),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: heavy(size, weight: FontWeight.w900),
    ),
  );
}

/// The bar at the bottom that says what you're facing and what the keys do (.hint).
class HintBar extends StatelessWidget {
  const HintBar(this.parts, {super.key});

  final List<HintPart> parts;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    // max-width: min(720px, 100vw - 380px), and the full width less the gutters on a phone.
    final max = screen <= 800 ? screen - 24 : math.min(720.0, screen - 380);
    return IgnorePointer(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.max(200, max)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Swatch.ink,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Swatch.paper, width: kBorder),
            boxShadow: const [BoxShadow(color: Color(0x59000000), offset: Offset(0, 4))],
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [for (final p in parts) _part(p)],
          ),
        ),
      ),
    );
  }

  Widget _part(HintPart p) => switch (p) {
    HintTitle(:final text) => Text(text, style: heavy(15, color: Swatch.warn)),
    HintKey(:final keyName, :final label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        KeyCap(keyName),
        Text(label, style: heavy(15, color: Swatch.paper)),
      ],
    ),
    HintAside(:final text) => Text(
      text,
      style: heavy(15, color: Swatch.paper.withValues(alpha: 0.75), weight: FontWeight.w600),
    ),
    HintCost(:final text, :final tooltip) => Text(
      text,
      style: heavy(15, color: const Color(0xFFA5ECFB), weight: FontWeight.w700),
      semanticsLabel: tooltip,
    ),
  };
}

// ---- The crosshair -------------------------------------------------------------------------------

/// Where the crosshair is at: shown only in first person with no window open; `on` when it's on
/// something you can use; `free` when the mouse isn't captured ("Click to look around").
@immutable
class CrosshairState {
  const CrosshairState({this.show = false, this.on = false, this.free = false});
  final bool show;
  final bool on;
  final bool free;

  @override
  bool operator ==(Object other) =>
      other is CrosshairState && other.show == show && other.on == on && other.free == free;
  @override
  int get hashCode => Object.hash(show, on, free);
}

class Crosshair extends StatelessWidget {
  const Crosshair(this.state, {super.key});

  final CrosshairState state;

  @override
  Widget build(BuildContext context) {
    if (!state.show) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox(
        width: 0,
        height: 0,
        child: OverflowBox(
          maxWidth: 400,
          maxHeight: 200,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: const Offset(0, -5),
                child: AnimatedScale(
                  scale: state.on ? 1.6 : 1,
                  duration: const Duration(milliseconds: 100),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: state.on ? Swatch.accent : Swatch.paper.withValues(alpha: 0.85),
                      border: Border.all(color: Swatch.ink.withValues(alpha: state.on ? 1 : 0.85), width: 2),
                    ),
                  ),
                ),
              ),
              if (state.free)
                Padding(
                  // The dot takes 0-10 in layout and is drawn at -5-5; the hint sits 15 below the middle.
                  padding: const EdgeInsets.only(top: 5),
                  child: Transform.scale(
                    scale: state.on ? 0.625 : 1,
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(10)),
                      child: Text('Click to look around', style: heavy(13, color: Swatch.paper)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- The caffeine meter --------------------------------------------------------------------------

/// The caffeine meter: a cup per coffee in a row, and a bar that drains over the buzz's minute.
/// [clock] is seconds on the same clock the coffee was drunk on.
class CaffeineMeter extends StatefulWidget {
  const CaffeineMeter({super.key, required this.caffeine, required this.clock, this.gapBelow = 0});

  final Caffeine caffeine;
  final double Function() clock;

  /// Space under it while it shows (the screen shares move down under it).
  final double gapBelow;

  @override
  State<CaffeineMeter> createState() => _CaffeineMeterState();
}

class _CaffeineMeterState extends State<CaffeineMeter> {
  Timer? _timer;
  String _key = '';
  int _shake = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  void _tick() {
    final now = widget.clock();
    final c = widget.caffeine;
    final jittery = c.jitter(now) > 0;
    final k = '${c.left(now).ceil()}|${c.cups}|$jittery';
    if (jittery) _shake++;
    if (k != _key || jittery) setState(() => _key = k);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    final c = widget.caffeine;
    final left = c.left(now);
    if (left <= 0) return const SizedBox.shrink();
    final jittery = c.jitter(now) > 0;
    // The bar eases down a second at a time, so aim for where it will be in one.
    final fill = (math.max(0, left - 1) / buzzSeconds).clamp(0.0, 1.0);
    final calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget meter = Panel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('☕' * math.min(c.cups, 3), style: heavy(13, weight: FontWeight.w900)),
          const SizedBox(width: 8),
          Container(
            width: 96,
            height: 12,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFFF1E4D3),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Swatch.ink, width: 2),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedFractionallySizedBox(
                duration: const Duration(seconds: 1),
                widthFactor: fill,
                heightFactor: 1,
                child: ColoredBox(color: jittery ? Swatch.bad : const Color(0xFF9C6644)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 24),
            child: Text(
              '${left.ceil()}s',
              style: heavy(13, weight: FontWeight.w900).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
    // @keyframes jitters { 50% { transform: translate(1px, -1px) rotate(-1.5deg) } }, in two steps.
    if (jittery && !calm && _shake.isOdd) {
      meter = Transform.translate(
        offset: const Offset(1, -1),
        child: Transform.rotate(angle: -1.5 * math.pi / 180, child: meter),
      );
    }
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.gapBelow),
        child: Semantics(label: 'Coffee buzz left', child: meter),
      ),
    );
  }
}

// ---- The chat log --------------------------------------------------------------------------------

/// The last 60 lines of chat, newest at the bottom (#chat-log).
class ChatLog extends StatefulWidget {
  const ChatLog(this.lines, {super.key});

  final List<ChatLine> lines;

  @override
  State<ChatLog> createState() => _ChatLogState();
}

class _ChatLogState extends State<ChatLog> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(ChatLog old) {
    super.didUpdateWidget(old);
    // A new line: back down to it.
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines.length > 60 ? widget.lines.sublist(widget.lines.length - 60) : widget.lines;
    if (lines.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      // Reversed, so it stays scrolled to the newest line whatever the lines measure.
      child: ListView.separated(
        controller: _scroll,
        reverse: true,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: lines.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, i) => _line(lines[lines.length - 1 - i]),
      ),
    );
  }

  Widget _line(ChatLine c) {
    final account = c.account == true;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: c.name,
            style: heavy(13, color: cssColor(c.color), weight: FontWeight.w900),
            semanticsLabel: account ? '${c.name}, signed in with their own account' : null,
          ),
          if (account)
            TextSpan(
              text: ' ✓',
              style: heavy(11, color: Swatch.good, weight: FontWeight.w900),
            ),
          TextSpan(text: ': ${c.text}'),
        ],
      ),
      style: heavy(13, weight: FontWeight.w400),
    );
  }
}

// ---- Banners -------------------------------------------------------------------------------------

/// The .conn banner at the top middle: red "Reconnecting…", or yellow while the office upgrades.
class ConnBanner extends StatelessWidget {
  const ConnBanner(this.text, {super.key, this.upgrading = false});

  final String text;
  final bool upgrading;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: upgrading ? Swatch.warn : Swatch.bad,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Swatch.ink, width: kBorder),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: heavy(16, color: upgrading ? Swatch.ink : Colors.white, weight: FontWeight.w900),
    ),
  );
}
