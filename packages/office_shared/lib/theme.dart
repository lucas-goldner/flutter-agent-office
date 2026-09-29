// Holiday themes: the whole building dresses up for Halloween or Christmas. The server keeps
// what's picked (server/theme.ts); every browser dresses its own scene up from that.
// Port of src/shared/theme.ts. The types (HolidayTheme, ThemePick, ThemeState) are in protocol.dart.

import 'protocol.dart' show HolidayTheme, ThemePick;

const List<ThemePick> themePicks = [ThemePick.auto, ThemePick.halloween, ThemePick.christmas, ThemePick.off];

/// The holiday it is on the office's calendar, if any: Halloween all through October, Christmas all
/// through December. [utcOffset] is the office's clock in minutes east of UTC (see SkyState).
HolidayTheme? calendarTheme(int ms, int utcOffset) {
  final month = DateTime.fromMillisecondsSinceEpoch(ms + utcOffset * 60000, isUtc: true).month;
  return month == 10 ? HolidayTheme.halloween : (month == 12 ? HolidayTheme.christmas : null);
}

/// What a pick puts up at [ms] on the office's clock.
HolidayTheme? activeTheme(ThemePick pick, int ms, int utcOffset) => switch (pick) {
  ThemePick.auto => calendarTheme(ms, utcOffset),
  ThemePick.off => null,
  ThemePick.halloween => HolidayTheme.halloween,
  ThemePick.christmas => HolidayTheme.christmas,
};

bool isThemePick(Object? v) => ThemePick.tryParse(v) != null;
