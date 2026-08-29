import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../core/errors/api_exception.dart';
import '../core/logging/redacting_logger.dart';

final _log = Logger('api');

/// dio 實例工廠：集中處理 auth header、錯誤轉譯、token 遮蔽 log。
/// API 方法本體（rooms_api 等）保持乾淨，不重複 if (statusCode == ...)。
Dio createApiDio({
  required String baseUrl,
  required String? token,
  Duration connectTimeout = const Duration(seconds: 6),
  Duration receiveTimeout = const Duration(seconds: 30),
}) {
  final dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: connectTimeout,
    receiveTimeout: receiveTimeout,
  ));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
    onError: (e, handler) {
      _log.fine(() => redact('API 錯誤: ${e.requestOptions.method} '
          '${e.requestOptions.path} → ${e.response?.statusCode}'));
      handler.reject(e.copyWith(error: translateError(e)));
    },
  ));
  return dio;
}

/// DioException → app 層例外（UI-DESIGN §3.4 的轉譯表）。
ApiException translateError(DioException e) {
  final res = e.response;
  if (res == null) {
    return const NetworkException();
  }
  final code = _detailCode(res.data);
  switch (res.statusCode) {
    case 401:
      // 401 有兩種：token 無效、缺 X-Participant-Id 標頭。
      // 後者是程式錯不是設定錯，但對使用者一樣導向設定檢查。
      return AuthException(code ?? 'invalid_token');
    case 403:
      return ParticipantInvalidException(code ?? 'participant_not_active');
    case 404:
      return NotFoundException(code ?? 'not_found');
    case 409:
      return RoomArchivedException(code ?? 'room_archived');
    case 410:
      return AttachmentGoneException(code ?? 'attachment_blob_missing');
    case 413:
      // Hub 的訊息含實際上限（「超過 25 MB」），比我們自己編的準
      return AttachmentTooLargeException(_detailMessage(res.data));
    case 422:
      return ValidationException(
          code ?? 'validation', _detailMessage(res.data) ?? '請求內容不合法');
    default:
      return ServerException(res.statusCode ?? 0);
  }
}

String? _detailCode(dynamic data) {
  if (data is Map && data['detail'] is Map) {
    return (data['detail'] as Map)['code'] as String?;
  }
  return null;
}

String? _detailMessage(dynamic data) {
  if (data is Map && data['detail'] is Map) {
    return (data['detail'] as Map)['message'] as String?;
  }
  return null;
}

/// 統一的請求包裝：把 DioException 內夾帶的 ApiException 拋出來。
Future<T> unwrap<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on DioException catch (e) {
    final err = e.error;
    if (err is ApiException) throw err;
    throw translateError(e);
  }
}
