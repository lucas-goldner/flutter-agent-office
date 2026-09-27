{{flutter_js}}
{{flutter_build_config}}

// Glyphs the bundled fonts lack would make the engine fetch Noto fonts from fonts.gstatic.com.
// The office runs on private networks too, so it never reaches out: those fonts are looked for
// next to the app instead (and simply don't render if they aren't there).
_flutter.loader.load({
  config: { fontFallbackBaseUrl: 'assets/fonts/fallback/' },
});
