// 🍸 The rooftop bar's menu: pick a drink and the bartender pours it (ui/bar.ts).

import 'package:flutter/material.dart';

import 'package:office_shared/rooftop.dart';

import '../booze.dart' show drinkKick;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// Opens the menu. [cutOff]: had enough, nothing stronger than water or a mocktail.
ModalHandle openBar({required bool cutOff, required void Function(Drink d) order}) =>
    ModalStack.instance.show((modal) => _BarWindow(modal: modal, cutOff: cutOff, order: order));

class _BarWindow extends StatelessWidget {
  const _BarWindow({required this.modal, required this.cutOff, required this.order});
  final ModalHandle modal;
  final bool cutOff;
  final void Function(Drink d) order;

  @override
  Widget build(BuildContext context) => ModalWindow(
    modal: modal,
    width: 480,
    title: const Text('🍸 Sky Bar'),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cutOff)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              "🙅 The bartender thinks you've had enough. Water's on the house.",
              style: heavy(14, weight: FontWeight.w800),
            ),
          ),
        for (final (i, d) in drinks.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
            child: _DrinkRow(
              drink: d,
              refused: cutOff && d.strength > 0,
              autofocus: i == (cutOff ? drinks.indexWhere((x) => x.strength <= 0) : 0),
              onPick: () {
                modal.close();
                order(d);
              },
            ),
          ),
      ],
    ),
    footer: const FooterNote(
      'Drinks go to your head for a minute or so, and the view goes with them. Everything is on the house.',
    ),
  );
}

class _DrinkRow extends StatefulWidget {
  const _DrinkRow({required this.drink, required this.refused, required this.autofocus, required this.onPick});
  final Drink drink;
  final bool refused;
  final bool autofocus;
  final VoidCallback onPick;

  @override
  State<_DrinkRow> createState() => _DrinkRowState();
}

class _DrinkRowState extends State<_DrinkRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.drink;
    final refused = widget.refused;
    return Tooltip(
      message: refused ? "The bartender won't pour you another" : 'Order a ${d.name.toLowerCase()}',
      waitDuration: const Duration(milliseconds: 700),
      child: FocusableActionDetector(
        autofocus: widget.autofocus && !refused,
        enabled: !refused,
        mouseCursor: refused ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _hover = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => refused ? null : widget.onPick())},
        child: GestureDetector(
          onTap: refused ? null : widget.onPick,
          child: Opacity(
            opacity: refused ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _hover && !refused ? Swatch.paper2 : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Swatch.ink, width: kBorder),
                boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
              ),
              child: Row(
                children: [
                  Text(d.emoji, style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, style: heavy(16, weight: FontWeight.w900)),
                        Text(
                          '${d.blurb} · ${drinkKick(d)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
