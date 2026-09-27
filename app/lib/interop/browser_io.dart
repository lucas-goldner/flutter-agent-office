// The desktop app's stand-ins for the browser (interop/browser_web.dart): there's no address bar,
// so the page to show is an in-app route main.dart listens to; there's no same-origin office, so
// the office's address is a setting; and localStorage is a small JSON file in the user's
// Application Support folder. Until initPlatform() runs (it never does in widget tests) storage
// stays in memory and links aren't handed to the system.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the desktop app looks for its office until you pick another on the sign-in page.
const String defaultServerOrigin = 'http://localhost:4600';
const String _serverKey = 'agent-office.server';

/// The app has started for real (not a widget test): storage goes to disk, links to the browser.
bool _live = false;

// ---- Where you are -----------------------------------------------------------------------------

class _Navigation extends ChangeNotifier {
  Uri location = Uri(path: '/login');

  /// Bumped by [reloadPage], so the same page is built afresh.
  int generation = 0;

  void go(String url) {
    final u = Uri.parse(url);
    location = Uri(
      path: u.path.isEmpty ? '/' : u.path,
      query: u.hasQuery ? u.query : null,
      fragment: u.hasFragment ? u.fragment : null,
    );
    notifyListeners();
  }

  void reload() {
    generation++;
    notifyListeners();
  }
}

final _Navigation _nav = _Navigation();

/// The in-app route changed: main.dart rebuilds the page.
Listenable? get navigation => _nav;

/// Which page is showing, for keying it so a new route (or a reload) starts it afresh.
String get pageKey => '${_nav.location.path}#${_nav.generation}';

String get locationPath => _nav.location.path;
String get locationHash => _nav.location.hasFragment ? '#${_nav.location.fragment}' : '';
String get locationSearch => _nav.location.hasQuery ? '?${_nav.location.query}' : '';

/// No address to read dev switches from.
final Map<String, String> startupQuery = const {};

/// The office's host (with its port), as a page it served would see its own.
String get locationHost => Uri.parse(serverOrigin).authority;
bool get isSecure => Uri.parse(serverOrigin).scheme == 'https';

/// The office the app talks to, e.g. `http://localhost:4600`.
String get serverOrigin => storageGet(_serverKey) ?? defaultServerOrigin;

/// Picks the office to talk to ([origin] already normalised, see net/server.dart).
void setServerOrigin(String origin) => storageSet(_serverKey, origin);

void goReplace(String url) => _nav.go(url);
void goTo(String url) => _nav.go(url);

/// Updates the route without starting its page over (a page tidying its own address).
void replaceUrl(String url) {
  final u = Uri.parse(url);
  _nav.location = Uri(path: u.path, query: u.hasQuery ? u.query : null, fragment: u.hasFragment ? u.fragment : null);
}

void reloadPage() => _nav.reload();

// ---- Storage -------------------------------------------------------------------------------------

final Map<String, String> _storage = {};
File? _file;

/// The folder the app keeps its things in. Under the macOS sandbox HOME is the app's container,
/// so this lands in `~/Library/Containers/<bundle id>/Data/Library/Application Support`.
String _supportDir() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Application Support/Agent Office';
  if (Platform.isWindows) return '${env['APPDATA'] ?? home}\\Agent Office';
  return '${env['XDG_CONFIG_HOME'] ?? '$home/.config'}/agent-office';
}

/// Reads what the app saved last time (synchronously, so the first frame already has it) and
/// from then on saves to disk and opens links in the browser. main() calls it once.
void initPlatform() {
  _live = true;
  final file = _file = File('${_supportDir()}${Platform.pathSeparator}storage.json');
  try {
    if (!file.existsSync()) return;
    final v = jsonDecode(file.readAsStringSync());
    if (v is Map) {
      for (final e in v.entries) {
        if (e.value is String) _storage['${e.key}'] = e.value as String;
      }
    }
  } catch (e) {
    debugPrint('storage: $e');
  }
}

/// Written straight away: it's a few kilobytes, and a quit right after a change must not lose it.
void _save() {
  final file = _file;
  if (file == null) return;
  try {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(_storage), flush: true);
    tmp.renameSync(file.path);
  } catch (e) {
    debugPrint('storage: $e');
  }
}

String? storageGet(String key) => _storage[key];

void storageSet(String key, String value) {
  if (_storage[key] == value) return;
  _storage[key] = value;
  _save();
}

void storageRemove(String key) {
  if (_storage.remove(key) != null) _save();
}

// ---- The window ----------------------------------------------------------------------------------

/// Nothing asks before the app quits (stage 2: AppLifecycleListener.onExitRequested).
void Function() warnBeforeUnload(bool Function() shouldWarn) => () {};

/// The window keeps the app's own title (setting it needs a plugin).
set documentTitle(String title) {}

/// Whether the app is out of sight (minimised, or another app's full screen in front).
bool get pageHidden {
  final s = WidgetsBinding.instance.lifecycleState;
  return s == AppLifecycleState.hidden || s == AppLifecycleState.paused;
}

/// Opens [url] in the system's browser (relative ones on the office). A no-op in widget tests.
void openExternal(String url) {
  if (!_live) return;
  final uri = Uri.parse(serverOrigin).resolve(url);
  launchUrl(uri, mode: LaunchMode.externalApplication).catchError((Object e) {
    debugPrint("couldn't open $uri: $e");
    return false;
  });
}
