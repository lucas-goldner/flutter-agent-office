// Offering the 2D view (ui/lite_suggest.dart): once a page, never again once this browser said to stay in
// 3D, and the HUD's ☰ menu has it either way.

import 'package:agent_office/ui/lite_suggest.dart';
import 'package:agent_office/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offered once a page, and not once the browser said to stay in 3D', () {
    var declined = false;
    final offer = LiteOffer(declined: () => declined, decline: () => declined = true);
    offer.offer(LiteWhy.touch);
    expect(offer.showing.value, LiteWhy.touch);
    offer.stay();
    expect(offer.showing.value, isNull);
    expect(declined, isTrue);
    offer.offer(LiteWhy.slow);
    expect(offer.showing.value, isNull);
    final again = LiteOffer(declined: () => declined, decline: () {});
    again.offer(LiteWhy.slow);
    expect(again.showing.value, isNull);
  });

  test('a slow computer is offered it once, even if it stays slow', () {
    final offer = LiteOffer(declined: () => false, decline: () {});
    offer.offer(LiteWhy.slow);
    offer.showing.value = null;
    offer.offer(LiteWhy.slow);
    expect(offer.showing.value, isNull);
  });

  testWidgets('the offer says why, and Stay in 3D takes it down', (tester) async {
    var declined = false;
    final offer = LiteOffer(declined: () => declined, decline: () => declined = true)..offer(LiteWhy.slow);
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Stack(
          children: [Positioned.fill(child: LiteOfferView(offer: offer))],
        ),
      ),
    );
    expect(find.text(liteOfferText(LiteWhy.slow)), findsOneWidget);
    expect(find.byKey(const ValueKey('lite-open')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lite-stay')));
    await tester.pump();
    expect(find.text(liteOfferText(LiteWhy.slow)), findsNothing);
    expect(declined, isTrue);
  });
}
