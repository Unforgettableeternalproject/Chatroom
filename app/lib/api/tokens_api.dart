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
    this.lastUsedAt,
    this.revokedAt,
  });

  final String token;

  /// 這張發給誰。純標註，用來認出「這張還要不要留著」。
  final String label;
  final String createdAt;

  /// 從沒用過的是 null——那通常表示邀請沒送到，而不是對方不想用。
  final String? lastUsedAt;
  final String? revokedAt;

  bool get revoked => revokedAt != null;

  factory AccessToken.fromJson(Map<String, dynamic> json) => AccessToken(
        token: json['token'] as String,
        label: (json['label'] as String?) ?? '',
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
  Future<AccessToken> create({String label = ''}) => unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/tokens',
          data: {'label': label},
        );
        return AccessToken(
          token: res.data!['token'] as String,
          label: (res.data!['label'] as String?) ?? label,
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
