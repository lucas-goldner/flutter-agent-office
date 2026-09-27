// The building: every project is a floor you ride the elevator to. Shared by the server (which
// assigns each floor its look) and the client (which paints it).

/// The most floors a building has.
const int maxFloors = 16;

/// How a floor looks: its walls, their trim, and its planks.
class FloorPalette {
  const FloorPalette({required this.name, required this.wall, required this.trim, required this.floor, required this.floorAlt, required this.seam});

  final String name;
  final String wall;
  final String trim;
  final String floor;
  final String floorAlt;

  /// The gaps between planks.
  final String seam;
}

/// The first is the office as it always looked; every new floor takes the next one nobody has.
const List<FloorPalette> floorPalettes = [
  FloorPalette(name: 'Maple', wall: '#fff6ea', trim: '#e8a87c', floor: '#f2d7b0', floorAlt: '#e9c89a', seam: '#d9b88c'),
  FloorPalette(name: 'Mint', wall: '#e3f6ec', trim: '#40a878', floor: '#cfe6d9', floorAlt: '#bcdcc9', seam: '#9fc6b0'),
  FloorPalette(name: 'Sky', wall: '#e7f0ff', trim: '#4f7fe0', floor: '#d6dde9', floorAlt: '#c5cedd', seam: '#aab5c8'),
  FloorPalette(name: 'Lavender', wall: '#f2eaff', trim: '#9470e0', floor: '#e1d7ef', floorAlt: '#d2c4e7', seam: '#b8a6d6'),
  FloorPalette(name: 'Peach', wall: '#ffefe6', trim: '#ea7352', floor: '#efc6a5', floorAlt: '#e5b48e', seam: '#cf9c76'),
  FloorPalette(name: 'Lemon', wall: '#fffbe0', trim: '#dcaa16', floor: '#e9d8a4', floorAlt: '#dec98b', seam: '#c8b271'),
  FloorPalette(name: 'Walnut', wall: '#f5eee5', trim: '#8b5e3c', floor: '#aa7650', floorAlt: '#9b6845', seam: '#7c5236'),
  FloorPalette(name: 'Slate', wall: '#edf1f5', trim: '#3d5a80', floor: '#b9c3cd', floorAlt: '#aab5c0', seam: '#8d99a6'),
  FloorPalette(name: 'Rose', wall: '#ffeaf0', trim: '#e0567f', floor: '#eed3da', floorAlt: '#e4c1cb', seam: '#cea5b2'),
  FloorPalette(name: 'Teal', wall: '#e1f7f6', trim: '#1a9a9a', floor: '#c3e2de', floorAlt: '#b0d7d2', seam: '#92c3bd'),
];

FloorPalette floorPalette(int i) => floorPalettes[i % floorPalettes.length]; // Dart's % is never negative here

final RegExp _githubPrefix = RegExp(r'^(?:https?://|ssh://)?(?:[\w.-]+@)?github\.com[/:]', caseSensitive: false);
final RegExp _queryOrHash = RegExp(r'[?#].*$');
final RegExp _trailingSlashes = RegExp(r'/+$');
final RegExp _dotGit = RegExp(r'\.git$', caseSensitive: false);
final RegExp _owner = RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$');
final RegExp _repo = RegExp(r'^[a-zA-Z0-9_.-]{1,100}$');

/// `owner/repo` from what someone typed or pasted: owner/repo, a github.com URL (https, ssh or
/// git@), with or without .git. Null for anything else, so it can never become a CLI option,
/// a path or another host.
String? normalizeRepo(Object? value) {
  if (value is! String) return null;
  var s = value.trim();
  if (s.length > 200) return null;
  s = s.replaceFirst(_githubPrefix, '');
  s = s.replaceFirst(_queryOrHash, '').replaceFirst(_trailingSlashes, '').replaceFirst(_dotGit, '');
  final parts = s.split('/');
  // A URL may go on past the repository (…/owner/repo/issues/12).
  if (parts.length < 2) return null;
  final owner = parts[0];
  final repo = parts[1];
  if (!_owner.hasMatch(owner)) return null;
  if (!_repo.hasMatch(repo) || repo == '.' || repo == '..') return null;
  return '$owner/$repo';
}

bool sameRepo(String? a, String? b) => a != null && a.isNotEmpty && b != null && b.isNotEmpty && a.toLowerCase() == b.toLowerCase();
