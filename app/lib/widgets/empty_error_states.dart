import 'package:flutter/material.dart';

import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../l10n/l10n.dart';
import 'kind_badge.dart';

/// 空狀態 / 錯誤狀態的中文文案集中處。

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MonoLabel(AppLocalizations.of(context).commonNoContent,
              color: s.inkMute.withValues(alpha: .6)),
          const SizedBox(height: 10),
          Text(title, style: UepText.serif(size: 15, color: s.inkSoft)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: UepText.serif(size: 13.5, color: s.inkMute),
                textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final message = error is ApiException
        ? (error as ApiException).message
        : l10n.errorUnexpected;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MonoLabel(l10n.commonError, color: UepColors.errorText),
          const SizedBox(height: 10),
          Text(message,
              style: UepText.serif(size: 15, color: s.inkSoft),
              textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: s.lineStrong),
                foregroundColor: s.inkSoft,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999)),
              ),
              child: Text(l10n.commonRetry, style: UepText.sans(size: 13.5)),
            ),
          ],
        ],
      ),
    );
  }
}
