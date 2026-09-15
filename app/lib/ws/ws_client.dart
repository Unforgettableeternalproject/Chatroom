import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WS 連線的最小抽象：realtime_service 只依賴這個介面，
/// 測試時以 fake 取代，不需要真的 socket。
abstract class WsConnection {
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();

  /// 連線關閉後可讀（server 的 4401 = token 驗證失敗）。
  int? get closeCode;
}

typedef WsConnector = Future<WsConnection> Function(Uri uri);

class _ChannelConnection implements WsConnection {
  _ChannelConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async => _channel.sink.close();

  @override
  int? get closeCode => _channel.closeCode;
}

/// 預設 connector：web_socket_channel。
/// `ready` 等到握手完成，失敗會在這裡拋出（進退避而非 silent）。
Future<WsConnection> defaultWsConnector(Uri uri) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return _ChannelConnection(channel);
}
