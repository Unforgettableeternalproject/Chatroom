import 'package:flutter/foundation.dart';

/// 可用的表情。鏡像 Hub 的 `REACTION_EMOJIS`（server/chatroom_server/app.py，
/// 唯一定義處）——兩邊要一起改；Hub 會拒絕白名單外的表情。
const List<String> kReactionEmojis = [
  '\u{1F44D}', // 👍
  '❤️', // ❤️
  '\u{1F602}', // 😂
  '\u{1F62E}', // 😮
  '\u{1F622}', // 😢
  '\u{1F64F}', // 🙏
  '\u{1F440}', // 👀
  '✅', // ✅
];

/// 一則訊息上某個表情的彙總。
@immutable
class ReactionSummary {
  const ReactionSummary({
    required this.emoji,
    required this.count,
    required this.mine,
    this.names = const [],
  });

  final String emoji;
  final int count;

  /// 我是不是按了這個表情。
  final bool mine;

  /// 誰按的（Hub 會截斷，所以可能少於 [count]；tooltip 用）。
  final List<String> names;

  factory ReactionSummary.fromJson(Map<String, dynamic> json) =>
      ReactionSummary(
        emoji: (json['emoji'] as String?) ?? '',
        count: (json['count'] as int?) ?? 0,
        mine: (json['mine'] as bool?) ?? false,
        names: ((json['names'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
      );

  static List<ReactionSummary> listFromJson(Object? raw) => ((raw as List?) ??
          const [])
      .map((e) => ReactionSummary.fromJson((e as Map).cast<String, dynamic>()))
      .where((r) => r.emoji.isNotEmpty && r.count > 0)
      .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is ReactionSummary &&
      other.emoji == emoji &&
      other.count == count &&
      other.mine == mine &&
      listEquals(other.names, names);

  @override
  int get hashCode => Object.hash(emoji, count, mine, Object.hashAll(names));
}

/// 名單面板上的一列：誰按了哪個表情。
@immutable
class Reactor {
  const Reactor({
    required this.participantId,
    required this.name,
    required this.kind,
    required this.role,
    required this.emoji,
    required this.mine,
  });

  final String participantId;
  final String name;

  /// participant.kind（claude / codex / human / other），給 KindBadge 用。
  final String kind;
  final String role; // human | agent
  final String emoji;
  final bool mine;

  bool get isAgent => role != 'human';

  factory Reactor.fromJson(Map<String, dynamic> json) => Reactor(
        participantId: (json['participant_id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'agent',
        emoji: (json['emoji'] as String?) ?? '',
        mine: (json['mine'] as bool?) ?? false,
      );
}

/// 我目前在這則訊息上選的表情（沒有則 null）。
String? myReactionOf(List<ReactionSummary> reactions) {
  for (final r in reactions) {
    if (r.mine) return r.emoji;
  }
  return null;
}

/// 樂觀更新用：把「我的表情」改成 [toEmoji]（null＝取消）後的彙總。
///
/// 每人每則只有一個表情，所以先拿掉我原本的、再加新的——與 Hub 的替換語意
/// 一致。順序保持穩定（既有的表情維持原位，新的接在後面）。
List<ReactionSummary> reactionsAfter(
  List<ReactionSummary> current, {
  required String? toEmoji,
  required String myName,
}) {
  final out = <ReactionSummary>[];
  var added = false;
  for (final r in current) {
    var item = r;
    if (r.mine) {
      final names = [...r.names]..remove(myName);
      item = ReactionSummary(
          emoji: r.emoji, count: r.count - 1, mine: false, names: names);
    }
    if (r.emoji == toEmoji) {
      item = ReactionSummary(
        emoji: item.emoji,
        count: item.count + 1,
        mine: true,
        names: [...item.names, myName],
      );
      added = true;
    }
    if (item.count > 0) out.add(item);
  }
  if (toEmoji != null && !added) {
    out.add(ReactionSummary(
        emoji: toEmoji, count: 1, mine: true, names: [myName]));
  }
  return List.unmodifiable(out);
}
