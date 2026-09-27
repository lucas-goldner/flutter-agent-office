// "Are you sure?" before something that can't be undone: confirmDialog from ui/prompt.ts, for the
// windows here (team, accounts, decor).

import 'package:flutter/material.dart';

import 'modal.dart';
import 'theme.dart';

ModalHandle confirmDialog(String title, String body, String confirmLabel, VoidCallback onConfirm) =>
    ModalStack.instance.show(
      (modal) => ModalWindow(
        modal: modal,
        closable: false,
        title: Text(title),
        body: Text(body, style: heavy(15, weight: FontWeight.w700)),
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OfficeButton(label: 'Never mind', onPressed: modal.close),
            const SizedBox(width: 8),
            OfficeButton(
              label: confirmLabel,
              kind: BtnKind.danger,
              onPressed: () {
                modal.close();
                onConfirm();
              },
            ),
          ],
        ),
      ),
    );
