// The quiet HUD (ui/menu.ts): the top bar's dock (what you pinned, what needs you now, the People
// and Workers chips, and ☰), and the ☰ menu: every window, with counts and shortcuts, and switches
// for which panels show on screen. The rules are in menu_logic.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_scope.dart';
import '../state/store.dart';
import 'hud_parts.dart' show CountBadge;
import 'menu_logic.dart';
import 'modal.dart';
import 'theme.dart';

export 'menu_logic.dart';

/// Your HUD choices (panels, pins) and the actions: shared by the dock, the menu and the panels.
class HudPrefs extends ChangeNotifier {
  HudPrefs({Settings? settings, this.save}) : settings = settings ?? Settings();

  final Settings settings;

  /// Keeps the choices (in the browser).
  final VoidCallback? save;

  /// What the ☰ menu offers. The office fills it in; other parts of the office add their own.
  List<HudAction> actions = const [];

  bool panel(HudPanel p) => panelOn(settings, p);

  void setPanel(HudPanel p, bool on) {
    settings.hud = {...settings.hud, p: on};
    save?.call();
    notifyListeners();
  }

  bool pinned(String id) => settings.pins.contains(id);

  void togglePinned(String id) {
    settings.pins = togglePin(settings.pins, id);
    save?.call();
    notifyListeners();
  }

  /// Redraws the dock for a change the store doesn't announce (voice, hanging a picture).
  void refresh() => notifyListeners();
}

/// A top-bar button: an emoji, maybe a few words, maybe a count.
class DockButton extends StatefulWidget {
  const DockButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.kind = BtnKind.plain,
    this.tooltip,
    this.count = 0,
    this.dim = false,
    this.narrow = false,
    this.pressed,
    this.child,
  });

  final String icon;
  final String? label;
  final VoidCallback onTap;
  final BtnKind kind;
  final String? tooltip;
  final int count;
  final bool dim;
  final bool narrow;

  /// A panel chip's on/off: pressed in while its panel shows.
  final bool? pressed;

  /// In place of the icon (the ☰ burger).
  final Widget? child;

  @override
  State<DockButton> createState() => _DockButtonState();
}

class _DockButtonState extends State<DockButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final pressed = widget.pressed ?? false;
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (Swatch.accent, Colors.white),
      BtnKind.on => (Swatch.good, Colors.white),
      BtnKind.danger => (Swatch.bad, Colors.white),
      BtnKind.plain => (_hover || pressed ? Swatch.paper2 : Colors.white, Swatch.ink),
    };
    final style = heavy(14, color: fg);
    final label = widget.label;
    final down = _down || pressed;
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
            transform: Matrix4.translationValues(0, down ? 2 : 0, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Swatch.ink, width: kBorder),
              boxShadow: [BoxShadow(color: Swatch.ink, offset: Offset(0, down ? 1 : 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.child ?? Text(widget.icon, style: style),
                if (label != null && !widget.narrow) ...[const SizedBox(width: 6), Text(label, style: style)],
                if (widget.count > 0)
                  widget.pressed != null
                      ? Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('${widget.count}', style: heavy(13, color: Swatch.muted)),
                        )
                      : CountBadge(widget.count),
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

BtnKind _kindOf(HudAction a) => switch (a.toneNow) {
  HudTone.primary => BtnKind.primary,
  HudTone.danger => BtnKind.danger,
  null => a.isOn ? BtnKind.on : BtnKind.plain,
};

/// The three lines of ☰.
class _Burger extends StatelessWidget {
  const _Burger();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    height: 18,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            height: 3,
            decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(2)),
          ),
      ],
    ),
  );
}

/// The top bar's right side: pinned and status actions, the People and Workers chips, and ☰.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.prefs, required this.onMenu, this.menuKey, this.narrow = false, this.extra});

  final HudPrefs prefs;
  final VoidCallback onMenu;

  /// On the ☰ button, so the menu hangs under it.
  final GlobalKey? menuKey;
  final bool narrow;

  /// More to listen to for the actions' state (voice, hanging a picture).
  final Listenable? extra;

  @override
  Widget build(BuildContext context) {
    final store = OfficeScope.of(context).store;
    return ListenableBuilder(
      listenable: Listenable.merge([
        prefs,
        ?extra,
        store.topics(const [
          Topic.workers,
          Topic.peers,
          Topic.issues,
          Topic.pulls,
          Topic.services,
          Topic.queue,
          Topic.upgrade,
          Topic.me,
          Topic.floors,
          Topic.floor,
        ]),
      ]),
      builder: (context, _) {
        final s = prefs.settings;
        final people = store.peers.length;
        final workers = store.workers.values;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final a in dockActions(prefs.actions, s))
              DockButton(
                key: ValueKey('dock-${a.id}'),
                icon: a.iconNow,
                label: dockChip(a, s),
                kind: _kindOf(a),
                dim: a.blockedNow != null,
                count: a.countNow,
                tooltip: a.tooltip,
                onTap: a.run,
              ),
            if (peopleChipShown(people, s))
              DockButton(
                key: const ValueKey('dock-people'),
                icon: '👥',
                label: 'People',
                narrow: narrow,
                count: people,
                pressed: prefs.panel(HudPanel.people),
                tooltip:
                    '$people in the office${prefs.panel(HudPanel.people) ? ' · click to hide' : ' · click to show'}',
                onTap: () => prefs.setPanel(HudPanel.people, !prefs.panel(HudPanel.people)),
              ),
            DockButton(
              key: const ValueKey('dock-workers'),
              icon: '🤖',
              label: 'Workers',
              narrow: narrow,
              count: hiredCount(workers),
              pressed: prefs.panel(HudPanel.workers),
              tooltip:
                  '${workersTitle(workers)}${prefs.panel(HudPanel.workers) ? ' · click to hide' : ' · click to show'}',
              onTap: () => prefs.setPanel(HudPanel.workers, !prefs.panel(HudPanel.workers)),
            ),
            DockButton(
              key: menuKey,
              icon: '☰',
              tooltip: 'Menu: everything else, and what shows on screen (Tab)',
              onTap: onMenu,
              child: const _Burger(),
            ),
          ],
        );
      },
    );
  }
}

// ---- The ☰ menu --------------------------------------------------------------------------------------

ModalHandle? _menu;

bool hudMenuOpen() => _menu != null;

/// Opens the ☰ menu under [anchor] (the ☰ button), or closes it if it's open.
void toggleHudMenu(HudPrefs prefs, {GlobalKey? anchor}) {
  final open = _menu;
  if (open != null) return open.close();
  Rect? r;
  final box = anchor?.currentContext?.findRenderObject();
  if (box is RenderBox && box.hasSize) r = box.localToGlobal(Offset.zero) & box.size;
  _menu = ModalStack.instance.show(
    (modal) => _MenuLayer(prefs: prefs, modal: modal, anchor: r),
    clear: true,
    backdropCloses: false,
    onClose: () => _menu = null,
  );
}

void closeHudMenu() => _menu?.close();

class _MenuLayer extends StatelessWidget {
  const _MenuLayer({required this.prefs, required this.modal, this.anchor});

  final HudPrefs prefs;
  final ModalHandle modal;
  final Rect? anchor;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = (anchor?.bottom ?? 64) + 8;
    final right = anchor == null ? 12.0 : (size.width - anchor!.right).clamp(8.0, size.width);
    return Stack(
      children: [
        // A click anywhere else closes it, like any dropdown.
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTapDown: (_) => modal.close()),
        ),
        Positioned(
          top: top,
          right: right,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (size.height - top - 20).clamp(120, 2000),
              maxWidth: size.width - 16,
            ),
            child: HudMenu(prefs: prefs, close: modal.close),
          ),
        ),
      ],
    );
  }
}

/// The menu itself: Open and Together on the left; Show on screen and Office on the right.
class HudMenu extends StatelessWidget {
  const HudMenu({super.key, required this.prefs, required this.close});

  final HudPrefs prefs;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
      SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
      SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
    },
    // Tab closes it like Esc (and doesn't go on to the office's own Tab, which would open it again).
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.tab): close},
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) {
            final sections = {for (final (s, rows) in menuSections(prefs.actions)) s: rows};
            var first = true;
            Widget row(HudAction a) {
              final r = _MenuRow(action: a, prefs: prefs, close: close, autofocus: first);
              first = false;
              return r;
            }

            List<Widget> section(String name, List<Widget> rows) =>
                rows.isEmpty ? const [] : [_MenuHeading(name), ...rows];
            final left = [
              ...section('Open', [for (final a in sections[HudSection.open]!) row(a)]),
              ...section('Together', [for (final a in sections[HudSection.together]!) row(a)]),
            ];
            final right = [
              ...section('Show on screen', [for (final p in kHudPanels) _MenuToggle(panel: p, prefs: prefs)]),
              ...section('Office', [for (final a in sections[HudSection.office]!) row(a)]),
            ];
            final narrow = MediaQuery.sizeOf(context).width < 560;
            Widget col(List<Widget> c) => SizedBox(
              width: 250,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: c,
              ),
            );
            return Container(
              key: const ValueKey('hud-menu'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Swatch.paper,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Swatch.ink, width: kBorder),
                boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 5))],
              ),
              child: SingleChildScrollView(
                child: FocusTraversalGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (narrow)
                        col([...left, ...right])
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [col(left), const SizedBox(width: 14), col(right)],
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: SizedBox(
                          width: narrow ? 250 : 514,
                          child: Text(
                            'Pin what you use most to keep it on the top bar. Tab opens and closes this menu.',
                            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _MenuHeading extends StatelessWidget {
  const _MenuHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
    child: Text(
      text.toUpperCase(),
      style: heavy(11, color: Swatch.muted, weight: FontWeight.w900).copyWith(letterSpacing: 0.6),
    ),
  );
}

/// One action: its icon, label, count and key; and the pin that keeps it on the top bar.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.action, required this.prefs, required this.close, this.autofocus = false});

  final HudAction action;
  final HudPrefs prefs;
  final VoidCallback close;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final a = action;
    final blocked = a.blockedNow;
    final pinned = prefs.pinned(a.id);
    final kind = _kindOf(a);
    final key = a.keyNow;
    final count = a.countNow;
    final fg = kind == BtnKind.plain ? Swatch.ink : Colors.white;
    final bg = switch (kind) {
      BtnKind.primary => Swatch.accent,
      BtnKind.on => Swatch.good,
      BtnKind.danger => Swatch.bad,
      BtnKind.plain => Colors.transparent,
    };
    Widget item = InkWell(
      key: ValueKey('menu-${a.id}'),
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(10),
      hoverColor: Swatch.paper2,
      focusColor: Swatch.paper2,
      onTap: () {
        close();
        a.run();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Opacity(
          opacity: blocked != null ? 0.55 : 1,
          child: Row(
            children: [
              SizedBox(width: 26, child: Text(a.iconNow, style: heavy(15))),
              Expanded(
                child: Text(
                  a.labelNow,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: heavy(14, color: fg),
                ),
              ),
              if (count > 0) CountBadge(count),
              if (key != null)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Swatch.ink, width: 2),
                  ),
                  child: Text(key, style: heavy(11, weight: FontWeight.w900)),
                ),
            ],
          ),
        ),
      ),
    );
    final tip = blocked ?? a.title?.call();
    if (tip != null) item = Tooltip(message: tip, waitDuration: const Duration(milliseconds: 500), child: item);
    return Row(
      children: [
        Expanded(child: item),
        Tooltip(
          message: pinned ? 'Unpin from the top bar' : 'Pin to the top bar',
          child: InkWell(
            key: ValueKey('pin-${a.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => prefs.togglePinned(a.id),
            child: Semantics(
              label: 'Pin ${a.labelNow} to the top bar',
              toggled: pinned,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Opacity(
                  opacity: pinned ? 1 : 0.3,
                  child: Transform.rotate(
                    angle: pinned ? 0 : 0.6,
                    child: Text('📌', style: heavy(13)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A panel's switch.
class _MenuToggle extends StatelessWidget {
  const _MenuToggle({required this.panel, required this.prefs});

  final HudPanelInfo panel;
  final HudPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final on = prefs.panel(panel.id);
    return InkWell(
      key: ValueKey('toggle-${panel.id.name}'),
      borderRadius: BorderRadius.circular(10),
      hoverColor: Swatch.paper2,
      focusColor: Swatch.paper2,
      onTap: () => prefs.setPanel(panel.id, !on),
      child: Semantics(
        checked: on,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            children: [
              SizedBox(width: 26, child: Text(panel.icon, style: heavy(15))),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(panel.label, style: heavy(14)),
                    Text(
                      panel.what,
                      style: heavy(11, color: Swatch.muted, weight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              _Switch(on),
            ],
          ),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch(this.on);
  final bool on;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    width: 34,
    height: 20,
    padding: const EdgeInsets.all(2),
    alignment: on ? Alignment.centerRight : Alignment.centerLeft,
    decoration: BoxDecoration(
      color: on ? Swatch.good : Colors.white,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: on ? Colors.white : Swatch.ink, shape: BoxShape.circle),
    ),
  );
}

/// The ✕ in a panel's heading, which hides it until you turn it back on from the ☰ menu.
class PanelHide extends StatelessWidget {
  const PanelHide({super.key, required this.prefs, required this.panel});

  final HudPrefs prefs;
  final HudPanel panel;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Hide (☰ brings it back)',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('hide-${panel.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => prefs.setPanel(panel, false),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            '✕',
            style: heavy(13, color: Swatch.muted, weight: FontWeight.w900),
          ),
        ),
      ),
    ),
  );
}
