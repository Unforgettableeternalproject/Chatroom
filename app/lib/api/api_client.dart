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
  bool Function()? hostView,
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
      // 主持人視角。**每次請求現讀**而不是建 dio 時就決定——開關要能即時
      // 生效，而重建 dio 會把連線一起關掉。Hub 端仍會驗這把 token 是不是
      // 主 token，帶了不代表過得了
      if (hostView != null && hostView()) {
        options.headers['X-Host-View'] = '1';
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
      // 401 有兩種：token 無效、缺 X-Participant-Id 標頭。後者是程式錯不是
      // 設定錯——把它也講成「token 無效」，人就會去翻設定頁，而那裡什麼都
      // 不必改（釘選牆漏帶身分那次就是這樣浪費掉的）。
      if (code == 'participant_header_required') {
        return const ParticipantHeaderMissingException();
      }
      return AuthException(code ?? 'invalid_token');
    case 403:
      // 403 不是只有一種。權限不足與身分失效若共用型別，後者的自動 re-join
      // 就會被前者觸發——重新加入一百次也不會變成 Hub 主持人
      if (code == 'root_token_required') {
        return RootTokenRequiredException(_detailMessage(res.data));
      }
      // 板的成員資格與房內身分是兩件事。走 ParticipantInvalidException 的話
      // 會觸發自動 re-join，而重新加入聊天室一百次也不會讓你出現在板的
      // 成員列上——那是一個永遠不會成功、而且看起來像卡住的迴圈
      if (code == 'not_board_member' ||
          code == 'not_board_owner' ||
          code == 'not_board_supervisor') {
        return BoardAccessException(
            code!,
            _detailMessage(res.data) ?? '你還不是這塊板的成員',
            _detailMap(res.data));
      }
      // Hub 對每個 403 code 都寫了一句對應的話（「只有聊天室建立者可以…」、
      // 「你已經不在這個聊天室裡了…」）。丟掉它改用寫死的那句，等於把所有
      // 「你沒有資格做這件事」都講成「你的身分壞了」
      return ParticipantInvalidException(
          code ?? 'participant_not_active', _detailMessage(res.data));
    case 404:
      return NotFoundException(code ?? 'not_found');
    case 409:
      // 409 不是只有一種——同 403 那組的理由（見上）。認領衝突、狀態轉移
      // 不合法都是 409，把它們一律講成「此聊天室已封存」會讓人去找一個
      // 根本沒有封存的房間。沒帶 code 的舊 Hub 維持原本的封存語意
      if (code == null || code == 'room_archived') {
        return RoomArchivedException(code ?? 'room_archived');
      }
      return ConflictException(
        code,
        _detailMessage(res.data) ?? '目前的狀態不允許這個動作',
        allowed: _detailList(res.data, 'allowed'),
        // 其餘欄位原樣帶過去。Hub 把「往下走的資訊」放在拒絕裡
        // （`container_settled` 的 kind / item_id / reopen_to 就是這樣來的），
        // 每加一個欄位就改一次型別的話，那些資訊多半就不會有人接
        detail: _detailMap(res.data),
      );
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

/// 取 `detail` 裡的字串陣列（如 `invalid_transition` 的 `allowed`）。
/// 缺欄位、型別不對一律當成空——這是附帶資訊，不該讓整個錯誤轉譯失敗。
List<String> _detailList(dynamic data, String key) {
  if (data is Map && data['detail'] is Map) {
    final v = (data['detail'] as Map)[key];
    if (v is List) return v.whereType<String>().toList();
  }
  return const [];
}

/// `detail` 本身（不是某一個欄位）。取不到就是空的，不要讓呼叫端處理 null。
Map<String, dynamic> _detailMap(dynamic data) {
  if (data is Map && data['detail'] is Map) {
    return Map<String, dynamic>.from(data['detail'] as Map);
  }
  return const {};
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
