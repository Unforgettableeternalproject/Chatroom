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

  group('已經在房裡的人不該出現在候選名單', () {
    // 指派是「請一個還沒在場的人進來」。對已經在場的人再指派一次不會發生
    // 任何事（join 冪等），而清單不表態的話，那個錯誤要等送出去才發現。
    // Hub 從 09/12 就支援 exclude_room，App 一直沒接上——房裡坐著的 Codex
    // 照樣出現在候選清單（2026-09-14 艾斯維爾在畫面上抓到）。
    test('掃描候選時把目標房間排除掉', () async {
      await api.scanSessions(excludeRoom: 'r1');
      expect(rec.seen.single.queryParameters['exclude_room'], 'r1');
    });

    test('沒給房間就不送這個參數', () async {
      await api.scanSessions();
      expect(rec.seen.single.queryParameters.containsKey('exclude_room'),
          isFalse);
    });
  });

  group('探索到的名字不可以蓋掉 agent 自報的', () {
    // App 掃 writer lock 發現一個 thread 時，它**不知道那個 agent 叫什麼**。
    // 實測：Codex 以 CHATROOM_DEFAULT_NAME=Codex-Sol 自報身分，而這裡的輪詢
    // 每 10 秒帶著自己編的尾碼報到一次，Hub 的 label 規則是「帶了非空值就
    // 覆寫」——使用者設好的名字十秒內被洗掉，名單上永遠只看得到十六進位。
    test('探索用的登記要標記成 fallback', () async {
      await api.listForSession('01a05774-2650',
          kind: 'codex', label: 'Codex-1', host: 'TheFantasias',
          labelFallback: true);
      expect(rec.seen.single.queryParameters['label_fallback'], true);
    });

    test('沒標記時不送這個參數——舊 Hub 不認得，而它預設就是自報', () async {
      await api.listForSession('01a05774-2650',
          kind: 'codex', label: 'Codex-1', host: 'TheFantasias');
      expect(rec.seen.single.queryParameters.containsKey('label_fallback'),
          isFalse);
    });
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
    });

    test('憑證改走 header，kind/label/host 留在 query（87ec8297）', () async {
      // ⚠️ 這三個**不是憑證**：它們是向 session 名錄自報的資訊
      // （我是什麼、叫什麼、在哪台機器）。統一憑證位置那張卡搬的只有
      // `session_key`——照字串一起搬的話，名錄會少掉分辨機器的依據
      await api.listForSession('01a05774-2650', kind: 'codex',
          label: 'Codex-2650', host: 'TheFantasias');
      expect(rec.seen.single.queryParameters.containsKey('session_key'),
          isFalse);
      expect(rec.seen.single.headers['X-Session-Key'], '01a05774-2650');
    });
  });
}
