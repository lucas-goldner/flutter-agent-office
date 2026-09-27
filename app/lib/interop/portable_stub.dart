final Map<String, String> _storage = {};

String? storageGet(String key) => _storage[key];
void storageSet(String key, String value) => _storage[key] = value;

/// The URLs [openInNewTab] was asked to open (for tests).
final List<String> openedUrls = [];
void openInNewTab(String url) => openedUrls.add(url);

void Function() interceptPaste(bool Function() active, void Function(String text) onText) => () {};
