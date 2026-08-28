import 'package:flutter/material.dart';

import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
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
          MonoLabel('EMPTY', color: s.inkMute.withValues(alpha: .6)),
          const SizedBox(height: 10),
          Text(title, style: UepText.serif(size: 14, color: s.inkSoft)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: UepText.serif(size: 12.5, color: s.inkMute),
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
    final message = error is ApiException
        ? (error as ApiException).message
        : '發生未預期的錯誤';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MonoLabel('ERROR', color: UepColors.errorText),
          const SizedBox(height: 10),
          Text(message,
              style: UepText.serif(size: 14, color: s.inkSoft),
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
              child: Text('重試', style: UepText.sans(size: 12.5)),
            ),
          ],
        ],
      ),
    );
  }
}
