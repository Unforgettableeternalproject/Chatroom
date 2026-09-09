import 'package:flutter/foundation.dart';

/// 這台機器上裝著的 Hub 主持包（`host-kit`）。
///
/// ## 它是指路牌，不是設定
///
/// `host-kit/install.py` 安裝時寫下 `~/.chatroom/host-kit.json`，裡面只有
/// 「這一包在哪」。**token、實際的 host/port、跑不跑得起來，一律現查**——
/// 那份 `.env` 會被人手改，而改完不會有人回來更新註冊檔。
///
/// 把註冊檔當成設定來讀的話，畫面會講得很篤定而且是錯的，那比沒有這個
/// 分頁更糟。
@immutable
class HostKit {
  const HostKit({
    required this.kitRoot,
    required this.envFile,
    this.installedAt = '',
    this.installedHost = '',
    this.installedPort = '',
  });

  /// host-kit 解壓後的根目錄（裡面有 `server/`、`scripts/`、`.venv/`）。
  final String kitRoot;
  final String envFile;
  final String installedAt;

  /// 安裝當下填的值。**只是線索，不是現況**——Hub 現在綁在哪、有沒有在跑，
  /// 要去讀 `.env` 與實際打一次 health 才知道。
  final String installedHost;
  final String installedPort;

  factory HostKit.fromJson(Map<String, dynamic> json) => HostKit(
        kitRoot: (json['kit_root'] as String?) ?? '',
        envFile: (json['env_file'] as String?) ?? '',
        installedAt: (json['installed_at'] as String?) ?? '',
        installedHost: (json['installed_host'] as String?) ?? '',
        installedPort: (json['installed_port'] as String?) ?? '',
      );
}

/// Hub 現在的設定，**每次都從 `server/.env` 現讀**。
@immutable
class HostEnv {
  const HostEnv({this.host = '', this.port = '', this.token = ''});

  final String host;
  final String port;
  final String token;

  /// 綁 `0.0.0.0` 表示所有介面都收，那時「位址」要顯示這台機器的實際 IP，
  /// 不是字面上的 0.0.0.0——沒有人連得到 0.0.0.0。
  bool get bindsAllInterfaces => host == '0.0.0.0';

  bool get isComplete => port.isNotEmpty && token.isNotEmpty;
}
