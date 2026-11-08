import 'package:flutter/material.dart';

/// Modal confirmation for destructive or hard-to-undo actions.
///
/// Presentation only — callers own auth, MLS, and API side effects.
Future<bool> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Confirm',
  bool isDestructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          TextButton(
            style: isDestructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(dialogContext).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
