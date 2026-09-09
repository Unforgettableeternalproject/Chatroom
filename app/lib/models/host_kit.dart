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

/// 這台機器上裝著的 MCP 安裝包（`install-kit`）——agent 靠它連上 Hub。
///
/// 與 [HostKit] 同一個性質：**指路牌，不是設定**。URL 與 token 的真相在 kit
/// 根目錄的 `.env`，bridge 版本的真相在 `_build.json`。
@immutable
class McpKit {
  const McpKit({
    required this.kitRoot,
    required this.envFile,
    this.installedAt = '',
    this.targets = const [],
  });

  final String kitRoot;
  final String envFile;

  /// 安裝完成的時間。
  ///
  /// ⚠️ **這是有用途的欄位，不是裝飾。** Claude Code 若在這個時間之前就開著，
  /// 它連的是舊的 bridge 進程——設定檔更新了，跑著的那個沒有。那個落差
  /// 安裝器看得見、使用者看不見（2026-09-09 實際踩過：舊 bridge 沒有
  /// `card_refs` 參數，發文被 Hub 擋下，而錯誤訊息指向他手上沒有的東西）。
  final String installedAt;

  /// 裝到哪些 agent（`claude` / `codex`）。
  final List<String> targets;

  factory McpKit.fromJson(Map<String, dynamic> json) => McpKit(
        kitRoot: (json['kit_root'] as String?) ?? '',
        envFile: (json['env_file'] as String?) ?? '',
        installedAt: (json['installed_at'] as String?) ?? '',
        targets: ((json['targets'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// agent 連線用的設定，從 kit 根目錄的 `.env` **現讀**。
@immutable
class McpEnv {
  const McpEnv({this.url = '', this.token = ''});

  final String url;
  final String token;

  bool get isComplete => url.isNotEmpty;
}
