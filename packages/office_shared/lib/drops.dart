// Files dropped or pasted into a worker's terminal: the browser sends them to the office, which keeps
// them on its own machine (see server/drops.ts), and the terminal types where they are, as a terminal
// does with a file dragged into it. Claude Code and Codex turn a pasted picture's path into an image.
// Ported from src/shared/drops.ts.

/// The biggest file that can be dropped into a terminal: plenty for a screenshot of a big screen.
const int dropMaxBytes = 25 * 1024 * 1024;

final RegExp _windowsPath = RegExp(r'^[a-z]:[\\/]', caseSensitive: false);
final RegExp _space = RegExp(r'\s');
final RegExp _shellSpecial = RegExp(r'[^\p{L}\p{N}_@%+=:,./-]', unicode: true);

/// What a terminal types for files dragged into it, one path after another: a Windows path in quotes
/// when it has spaces, any other with a backslash before each character a shell would split it on.
String droppedPaths(List<String> paths) => paths
    .map(
      (p) => _windowsPath.hasMatch(p)
          ? (_space.hasMatch(p) ? '"$p"' : p)
          : p.replaceAllMapped(_shellSpecial, (m) => '\\${m[0]}'),
    )
    .join(' ');
