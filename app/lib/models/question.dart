import 'package:flutter/foundation.dart';

/// agent 向人類提出的問題選項。
@immutable
class QuestionOption {
  const QuestionOption({required this.label, this.description = ''});

  final String label;
  final String description;

  factory QuestionOption.fromJson(Map<String, dynamic> json) => QuestionOption(
        label: (json['label'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
      );
}

/// agent 向指定人類提出的問題。
///
/// 刻意不在訊息流裡——它是定向的，只會出現在被問的那個人的畫面上。
/// 房內其他 agent 查得到（避免重複發問），但 UI 不顯示不是問自己的題目。
@immutable
class Question {
  const Question({
    required this.id,
    required this.roomId,
    required this.prompt,
    required this.status,
    required this.createdAt,
    this.options = const [],
    this.allowFreeText = true,
    this.askerName,
    this.answer,
    this.answerKind,
  });

  final String id;
  final String roomId;
  final String prompt;

  /// pending / answered / skipped
  final String status;
  final String createdAt;
  final List<QuestionOption> options;

  /// false 時只能從 options 選，不能自己打字。
  final bool allowFreeText;
  final String? askerName;
  final String? answer;

  /// option / free_text
  final String? answerKind;

  bool get isPending => status == 'pending';

  factory Question.fromJson(Map<String, dynamic> json) => Question(
        id: json['id'] as String,
        roomId: (json['room_id'] as String?) ?? '',
        prompt: (json['prompt'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'pending',
        createdAt: (json['created_at'] as String?) ?? '',
        options: ((json['options'] as List?) ?? const [])
            .map((e) => QuestionOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        allowFreeText: (json['allow_free_text'] as bool?) ?? true,
        askerName: json['asker_name'] as String?,
        answer: json['answer'] as String?,
        answerKind: json['answer_kind'] as String?,
      );
}
