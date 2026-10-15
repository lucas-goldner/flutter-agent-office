// Offering the 2D view (/lite) where the 3D office is hard going: on a phone, with no keys to walk
// with, or on a computer where frames come slowly (see framerate.dart). A port of ui/litesuggest.ts.

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import 'theme.dart';

export '../interop/browser.dart' show touchOnly;

/// Said to stay in 3D: this browser isn't offered the 2D view again (it's in the ☰ menu).
const kLiteDeclinedKey = 'agent-office.lite-declined';

/// Why the 2D view is offered.
enum LiteWhy { touch, slow }

/// What the offer says.
String liteOfferText(LiteWhy why) => switch (why) {
  LiteWhy.touch => '📱 On a phone? The 👾 2D office is made for it: tap to walk, pinch to zoom, everything a tap away.',
  LiteWhy.slow =>
    '🐢 The 3D office is running slowly on this computer. The 👾 2D office is the same office, without the 3D.',
};

/// The offer on the office page: up at most once a page, unless this browser said to stay in 3D before.
class LiteOffer {
  LiteOffer({this.declined = _declined, this.decline = _decline});

  final bool Function() declined;
  final void Function() decline;

  /// Switches to the 👾 2D map (the office controller sets it); without it, the page at /lite.
  VoidCallback? open;

  /// What's up now, if anything.
  final ValueNotifier<LiteWhy?> showing = ValueNotifier(null);
  bool _offered = false;

  /// Offers the 2D view, at most once a page, unless this browser said to stay in 3D before.
  void offer(LiteWhy why) {
    if (_offered || declined()) return;
    _offered = true;
    showing.value = why;
  }

  /// Stay in 3D: not offered again in this browser.
  void stay() {
    decline();
    showing.value = null;
  }

  static bool _declined() {
    try {
      return storageGet(kLiteDeclinedKey) == '1';
    } catch (_) {
      return false;
    }
  }

  static void _decline() {
    try {
      storageSet(kLiteDeclinedKey, '1');
    } catch (_) {
      // storage blocked: it's only this page then
    }
  }
}

/// The offer, near the bottom of the page and over the loading screen too.
class LiteOfferView extends StatelessWidget {
  const LiteOfferView({super.key, required this.offer});
  final LiteOffer offer;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<LiteWhy?>(
    valueListenable: offer.showing,
    builder: (context, why, _) {
      if (why == null) return const SizedBox.shrink();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Material(
                type: MaterialType.transparency,
                child: Semantics(
                  label: 'Try the 2D view',
                  child: Panel(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(liteOfferText(why), style: heavy(15).copyWith(height: 1.35)),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OfficeButton(
                              key: const ValueKey('lite-open'),
                              label: 'Open the 2D view',
                              kind: BtnKind.primary,
                              onPressed: () {
                                offer.showing.value = null;
                                (offer.open ?? () => goTo('/lite'))();
                              },
                            ),
                            OfficeButton(key: const ValueKey('lite-stay'), label: 'Stay in 3D', onPressed: offer.stay),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
