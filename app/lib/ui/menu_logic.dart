// The rules behind the quiet HUD (ui/menu.ts): what one ☰ menu action is, which of them sit on the
// top bar, and the counts the top bar shows. Widgets are in menu.dart.

import 'package:flutter/foundation.dart';
import 'package:office_shared/layout.dart' show deskById;
import 'package:office_shared/protocol.dart';

import '../notify.dart' show waitingOnSomeone;
import '../state/store.dart';

enum HudSection { open, together, office }

const Map<HudSection, String> kHudSectionName = {
  HudSection.open: 'Open',
  HudSection.together: 'Together',
  HudSection.office: 'Office',
};

/// How an action stands out: an update to install, a muted mic.
enum HudTone { primary, danger }

/// One thing the ☰ menu does. Any of them can be pinned to the top bar. The `…Of` getters are for
/// the parts that change (voice's label while you're in it); the plain ones are fixed.
@immutable
class HudAction {
  const HudAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.section,
    required this.run,
    this.iconOf,
    this.labelOf,
    this.key,
    this.keyOf,
    this.count,
    this.on,
    this.tone,
    this.shown,
    this.status,
    this.chip,
    this.blocked,
    this.title,
  });

  /// Pins are saved by it, so it never changes.
  final String id;
  final String icon;
  final String Function()? iconOf;
  final String label;
  final String Function()? labelOf;
  final HudSection section;

  /// Its keyboard shortcut, if it has one; [keyOf] when that depends (V leaves voice only from here).
  final String? key;
  final String? Function()? keyOf;

  /// A number worth knowing before you open it: open issues, tasks waiting…
  final int Function()? count;

  /// Pressed, like voice while you're in it.
  final bool Function()? on;
  final HudTone? Function()? tone;

  /// Only offered some of the time (Invite, Accounts, Upgrade).
  final bool Function()? shown;

  /// Up on the top bar by itself while true, pinned or not: you're sharing your screen, an update is out.
  final bool Function()? status;

  /// Its words on the top bar while [status] put it there; a pinned one is just its icon.
  final String Function()? chip;

  /// Why it can't work here: it's greyed out and says so.
  final String? Function()? blocked;
  final String Function()? title;
  final VoidCallback run;

  String get iconNow => iconOf?.call() ?? icon;
  String get labelNow => labelOf?.call() ?? label;
  String? get keyNow => keyOf != null ? keyOf!() : key;
  bool get offered => shown?.call() ?? true;
  bool get isOn => on?.call() ?? false;
  HudTone? get toneNow => tone?.call();
  String? get blockedNow => blocked?.call();
  int get countNow => count?.call() ?? 0;

  /// The tooltip on the top bar: why it can't, what it is, or its label and key.
  String get tooltip {
    final b = blockedNow;
    if (b != null) return b;
    final t = title?.call();
    if (t != null) return t;
    final k = keyNow;
    return k == null ? labelNow : '$labelNow ($k)';
  }
}

/// One of the panels you can show, as the ☰ menu lists it.
typedef HudPanelInfo = ({HudPanel id, String icon, String label, String what});

const List<HudPanelInfo> kHudPanels = [
  (id: HudPanel.workers, icon: '🤖', label: 'Workers', what: 'Every desk and what it’s up to'),
  (id: HudPanel.people, icon: '👥', label: 'People', what: 'Who’s here, on which floor'),
  (id: HudPanel.spend, icon: '💸', label: 'Spend', what: 'Today, the budget, all time'),
  (id: HudPanel.limits, icon: '⏳', label: 'Claude limits', what: 'The plan’s 5-hour and week'),
  (id: HudPanel.chat, icon: '💬', label: 'Chat', what: 'T opens it either way'),
  (id: HudPanel.floor, icon: '🏢', label: 'Floor details', what: 'Branch, folder, default agent'),
];

bool panelOn(Settings s, HudPanel p) => s.hud[p] ?? kHudDefaults[p]!;

/// The actions up on the top bar, in the menu's order: the offered ones you pinned, and the ones
/// whose status puts them there by themselves.
List<HudAction> dockActions(Iterable<HudAction> actions, Settings s) => [
  for (final a in actions)
    if (a.offered && (s.pins.contains(a.id) || (a.status?.call() ?? false))) a,
];

/// What a dock button says beside its icon: the chip while its status put it there, nothing when pinned.
String? dockChip(HudAction a, Settings s) => s.pins.contains(a.id) ? null : a.chip?.call();

/// Pins [id], or unpins it.
List<String> togglePin(List<String> pins, String id) =>
    pins.contains(id) ? [...pins.where((p) => p != id)] : [...pins, id];

/// The ☰ menu's sections, each with its offered actions, in order.
List<(HudSection, List<HudAction>)> menuSections(Iterable<HudAction> actions) => [
  for (final s in HudSection.values)
    (
      s,
      [
        for (final a in actions)
          if (a.section == s && a.offered) a,
      ],
    ),
];

/// Workers hired onto desks, bean bags and the meeting room's table; the board agents at their
/// kiosks don't count.
int hiredCount(Iterable<WorkerInfo> workers) => workers.where((w) => deskById[w.deskId]?.station == null).length;

/// The Workers chip's tooltip.
String workersTitle(Iterable<WorkerInfo> workers) {
  final hired = hiredCount(workers);
  final waiting = workers.where(waitingOnSomeone).length;
  if (hired == 0 && waiting == 0) return 'No workers on this floor yet';
  return '$hired worker${hired == 1 ? '' : 's'} on this floor${waiting > 0 ? ', $waiting waiting on someone' : ''}';
}

/// The People chip shows once you're not alone, or while its panel is on.
bool peopleChipShown(int people, Settings s) => people > 1 || panelOn(s, HudPanel.people);

/// Workers waiting on someone, whoever has waited longest first.
List<WorkerInfo> waitingInOrder(Iterable<WorkerInfo> workers) {
  int since(WorkerInfo w) => w.waitingSince ?? w.createdAt;
  return workers.where(waitingOnSomeone).toList()..sort((a, b) {
    final d = since(a).compareTo(since(b));
    if (d != 0) return d;
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
}

/// "🙋 2 waiting · ✅ 1 done": the ones that need input, then the ones that finished.
String waitingLabel(List<WorkerInfo> waiting) {
  final needs = waiting.where((w) => w.status == WorkerStatus.needsInput).length;
  final done = waiting.length - needs;
  return [if (needs > 0) '🙋 $needs waiting', if (done > 0) '✅ $done done'].join(' · ');
}
