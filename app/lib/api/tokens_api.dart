import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 一張發出去的存取 token。
///
/// 權限範圍與 `.env` 的主 token 相同——token 是信任邊界，房間不是。這張表
/// 買到的是**可撤銷**與**可追溯**，不是隔離；要真隔離得開不同的 Hub 實例。
@immutable
class AccessToken {
  const AccessToken({
    required this.token,
    required this.label,
    required this.createdAt,
    this.audience = 'human',
    this.party = '',
    this.lastUsedAt,
    this.revokedAt,
  });

  final String token;

  /// 這張發給誰。純標註，用來認出「這張還要不要留著」。
  final String label;

  /// `human`（貼進 App）或 `agent`（填進 mcp-kit 安裝器的「Agent token」）。
  /// 兩者的交付方式不同——agent 那張是裸 token，不是 `CHATROOM-INVITE-`
  /// 邀請碼，貼錯欄位的症狀是「一切正常就是連不上」。
  final String audience;

  /// 所屬的群（一個人連同他的 agent）。加發的 agent 憑證與發它的那張同群。
  /// 空字串＝這張自己就是一群（Hub 端由 token 的 hash 推導，不外流明碼）。
  final String party;
  final String createdAt;

  /// 從沒用過的是 null——那通常表示邀請沒送到，而不是對方不想用。
  final String? lastUsedAt;
  final String? revokedAt;

  bool get revoked => revokedAt != null;

  factory AccessToken.fromJson(Map<String, dynamic> json) => AccessToken(
        token: json['token'] as String,
        label: (json['label'] as String?) ?? '',
        audience: (json['audience'] as String?) ?? 'human',
        party: (json['party'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        lastUsedAt: json['last_used_at'] as String?,
        revokedAt: json['revoked_at'] as String?,
      );
}

class TokensApi {
  TokensApi(this._dio);

  final Dio _dio;

  /// 發一張新的邀請 token。只有主 token（Hub 主持人那台）能呼叫，
  /// 其餘會拿到 403 root_token_required。
  ///
  /// 🔴 **這個入口發的一律是給人的**（`audience: 'human'`）。Hub 那端的預設
  /// 是 `agent`——保守的預設在 API 層是對的，不動它。但 App 這個入口的產物是
  /// `CHATROOM-INVITE-` 邀請碼，而那個格式**只有 App 認得**，mcp-kit 讀的是
  /// 裸 token 字串，所以「在 App 上發一張 agent 邀請碼」這條路從來走不完。
  ///
  /// 不明講的後果是靜默的：分離期的 Hub 會在 `role=human` 那一刻把每一張
  /// App 發出的邀請擋下（403 `human_token_required`），而發的人以為自己
  /// 給了對方一把鑰匙，收的人看到的是「所有房間我都沒份」。
  /// [parentToken] 給值時發的是**掛在那張邀請底下的 agent 憑證**：對方的
  /// bridge 拿它接入，於是他的 agent 與他本人算同一個人，他指派得動、
  /// 別人（含主持人）指派不動。那一串是裸 token，填進 mcp-kit 安裝器問的
  /// 「Agent token」那一格——不是 `CHATROOM-INVITE-` 邀請碼，那個格式只有
  /// App 認得。
  Future<AccessToken> create({String label = '', String parentToken = ''}) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/tokens',
          data: {
            'label': label,
            'audience': parentToken.isEmpty ? 'human' : 'agent',
            if (parentToken.isNotEmpty) 'parent_token': parentToken,
          },
        );
        return AccessToken(
          token: res.data!['token'] as String,
          label: (res.data!['label'] as String?) ?? label,
          audience: (res.data!['audience'] as String?) ??
              (parentToken.isEmpty ? 'human' : 'agent'),
          party: (res.data!['party'] as String?) ?? '',
          createdAt: '',
        );
      });

  Future<List<AccessToken>> list({bool includeRevoked = false}) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/tokens',
          queryParameters: {if (includeRevoked) 'include_revoked': true},
        );
        return ((res.data?['tokens'] as List?) ?? const [])
            .map((e) => AccessToken.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  Future<void> revoke(String token) =>
      unwrap(() => _dio.delete('/api/tokens/$token'));
}
