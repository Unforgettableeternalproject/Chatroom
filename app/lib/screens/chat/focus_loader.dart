/// 捲到接近頂端時，要不要自動載入更舊的歷史。
///
/// [focusing] 為真（跳轉進行中）一律不載：跳轉自己會控制載入，而自動載入
/// 讓 feed 在動畫途中長高，目標的落點會跟著漂移。
bool shouldAutoLoadOlder({
  required bool loading,
  required bool focusing,
  required bool hasClients,
  required double pixels,
  required double maxScrollExtent,
}) =>
    !loading && !focusing && hasClients && pixels > maxScrollExtent - 400;
