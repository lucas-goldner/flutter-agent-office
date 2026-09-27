// The Claude plan's 5-hour session and weekly limits, under the workers (a port of ui/limits.ts).
// Click the panel to read them again.

import 'package:flutter/material.dart';

import '../shared/protocol.dart';
import 'theme.dart';
import 'usage.dart' show Meter, MeterLevel;

/// Numbers older than this say when they were read.
const _staleMs = 10 * 60000;

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// "5:00 AM", in this browser's time zone.
String clockTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "Tue 5:00 AM" (or "Tuesday 5:00 AM" with [long]).
String weekdayTime(DateTime t, {bool long = false}) {
  final day = _weekdays[t.weekday - 1];
  return '${long ? day : day.substring(0, 3)} ${clockTime(t)}';
}

/// "in 12m", "in 2h 5m", or "Tue 5:00 AM" once it is more than a day out.
String fmtReset(int at, [int? now]) {
  final mins = ((at - (now ?? DateTime.now().millisecondsSinceEpoch)) / 60000).ceil();
  if (mins <= 0) return 'now';
  if (mins < 60) return 'in ${mins}m';
  if (mins < 24 * 60) return 'in ${mins ~/ 60}h ${mins % 60}m';
  return weekdayTime(DateTime.fromMillisecondsSinceEpoch(at));
}

MeterLevel limitLevel(double pct) => pct >= 90
    ? MeterLevel.over
    : pct >= 75
    ? MeterLevel.near
    : MeterLevel.ok;

/// A window's tooltip: "Week (all models): 42% used\nStarts over Tuesday 5:00 AM".
String limitTitle(PlanWindow w) {
  final pct = w.pct.round();
  final when = w.resetsAt == null ? '' : weekdayTime(DateTime.fromMillisecondsSinceEpoch(w.resetsAt!), long: true);
  final scope = w.label == 'Week' ? ' (all models)' : '';
  return '${w.label}$scope: $pct% used${when.isNotEmpty ? '\nStarts over $when' : ''}';
}

/// "Max" from "max".
String planName(String? plan) => plan == null || plan.isEmpty ? '' : plan[0].toUpperCase() + plan.substring(1);

/// "As of 5:03 PM" when the numbers are old, else null.
String? limitsAsOf(PlanLimits s, int now) =>
    now - s.at > _staleMs ? 'As of ${clockTime(DateTime.fromMillisecondsSinceEpoch(s.at))}' : null;

const _tabular = [FontFeature.tabularFigures()];

/// The panel's contents (it goes in the side column's panel, see hud.dart). Empty when there's no plan.
class LimitsView extends StatelessWidget {
  const LimitsView(this.limits, {super.key, this.now});

  final PlanLimits limits;

  /// For tests; else the clock.
  final int? now;

  @override
  Widget build(BuildContext context) {
    final now = this.now ?? DateTime.now().millisecondsSinceEpoch;
    final plan = planName(limits.plan);
    final asOf = limitsAsOf(limits, now);
    return DefaultTextStyle(
      style: heavy(12, weight: FontWeight.w700),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('CLAUDE LIMITS', style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.56)),
                const Spacer(),
                if (plan.isNotEmpty) Text(plan, style: heavy(12, color: Swatch.muted)),
              ],
            ),
          ),
          for (final (i, w) in limits.windows.indexed) ..._window(w, now, first: i == 0),
          if (asOf != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                asOf,
                style: heavy(12, color: Swatch.muted, weight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _window(PlanWindow w, int now, {required bool first}) {
    final pct = w.pct.round();
    final level = limitLevel(w.pct);
    final title = limitTitle(w);
    return [
      Padding(
        // .limits .meter + .row { margin-top: 3px } on top of the 4px gap.
        padding: EdgeInsets.only(top: first ? 4 : 7),
        child: Tooltip(
          message: title,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(child: Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 5),
              Text(
                '$pct%',
                style: heavy(
                  12,
                  weight: FontWeight.w900,
                  color: level == MeterLevel.over ? Swatch.bad : Swatch.ink,
                ).copyWith(fontFeatures: _tabular),
              ),
              const Spacer(),
              if (w.resetsAt != null)
                Text(
                  'resets ${fmtReset(w.resetsAt!, now)}',
                  style: heavy(11, color: Swatch.muted, weight: FontWeight.w600).copyWith(fontFeatures: _tabular),
                ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Meter(pct: w.pct, level: level, tooltip: title),
      ),
    ];
  }
}
