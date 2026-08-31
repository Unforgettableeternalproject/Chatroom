import 'package:chatroom_app/api/assignments_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_headers_test.dart' show Recorder;

/// dispatcher 輪詢指派時會**順便把那把 key 登記進 Hub 的 session 名錄**
/// （`/api/assignments` 會 `_touch_session`）。那是刻意的——Codex 不會自己
/// join，不登記就沒有指派目標，整條喚醒鏈是死的。
///
/// 但登記時**沒有帶 host**，而指派 UI 的分組規則是「空的 host 不能當成本機」
/// （那條規則本身是對的：把別人機器上的 agent 指派進私人房，等於把房裡的
/// 內容送出去）。於是每個開過的 Codex thread 都以「其他裝置」的身分出現在
/// 清單上，而那一區預設收起——**使用者看得到自己的 agent，但在他不會展開的
/// 地方**。
void main() {
  late Recorder rec;
  late AssignmentsApi api;

  setUp(() {
    rec = Recorder();
    api = AssignmentsApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
  });

  group('登記進名錄時要說清楚自己在哪台機器', () {
    test('host 帶得出去', () async {
      await api.listForSession('01a05774-2650', kind: 'codex',
          label: 'Codex-1', host: 'TheFantasias');
      expect(rec.seen.single.queryParameters['host'], 'TheFantasias');
    });

    test('讀不到主機名時不送空字串——空值在 Hub 那端是「未知」，'
        '硬寫一個空的等於主動宣告未知', () async {
      await api.listForSession('01a05774-2650', kind: 'codex',
          label: 'Codex-1', host: '');
      expect(rec.seen.single.queryParameters.containsKey('host'), isFalse);
    });

    test('kind 與 label 仍照舊帶——那兩個本來就對，不要改壞', () async {
      await api.listForSession('01a05774-2650', kind: 'codex',
          label: 'Codex-2650', host: 'TheFantasias');
      final q = rec.seen.single.queryParameters;
      expect(q['kind'], 'codex');
      expect(q['label'], 'Codex-2650');
      expect(q['session_key'], '01a05774-2650');
    });
  });
}
