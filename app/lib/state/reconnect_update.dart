import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/build_info.dart';
import '../core/config/invite_code.dart';
import '../widgets/version_banner.dart';
import '../ws/realtime_service.dart';
import 'app_providers.dart';
import 'app_updater.dart';
import 'host_kit_providers.dart';
import 'kit_installer.dart';
import 'kit_prereq.dart';

/// 重連後要問使用者的那一件事。
enum ReconnectUpdateKind { app, hub }

@immutable
class ReconnectUpdatePrompt {
  const ReconnectUpdatePrompt(this.kind, this.tag);

  final ReconnectUpdateKind kind;

  /// 新版的 tag（`v1.2.8-hotfix1`）。
  final String tag;
}

/// 斷線後重新連上時，順便看一眼 App 與 Hub 誰較舊，有可更新的就提出來問。
///
/// 只新增「重連成功後觸發」這一段，其餘全沿用既有流程：
/// - App 較舊：[AppUpdate]（查 latest → 下載 → 重新啟動）。
/// - 本機 Hub 較舊：[KitInstalls.installHub]（設定頁「更新」按鈕同一條）。
///
/// ## 觸發條件
///
/// 「連上過 → 斷線（Disconnected／Reconnecting）→ 又連上」才算重連。
/// 首次連上不算——啟動時既有機制沒有自動檢查，這裡也不補。同一次重連
/// 只評估一次（評估中的重連事件直接略過）。
///
/// ## 誰較舊
///
/// 與版本橫幅同一份判斷（[olderVersionSide]：建置時間；commit 相同視為同步）。
/// 講不出建置時間時才退回比 `x.y.z`。熱修版與原版 `x.y.z` 相同，靠建置時間分辨。
/// 判出較舊之後，有沒有更新的 Release 仍交給既有的 `check()`／`kitReleaseProvider`。
///
/// ## 問過就不再問
///
/// 選「稍後」或已經選了更新（不論成敗）的 tag 記在記憶體裡，這次 App 執行
/// 期間不再問同一種對象的同一個版本。失敗了也不重問——重連會一直發生，
/// 失敗的更新不該變成每次重連都彈一次。
class ReconnectUpdate extends Notifier<ReconnectUpdatePrompt?> {
  bool _everConnected = false;
  bool _dropped = false;
  bool _evaluating = false;
  final Set<String> _handled = {};
  KitRelease? _hubRelease;
  String _hubTarget = '';

  @override
  ReconnectUpdatePrompt? build() {
    ref.listen(connectionStatusProvider, (previous, next) {
      final status = next.value;
      if (status is Connected) {
        final reconnect = _everConnected && _dropped;
        _everConnected = true;
        _dropped = false;
        if (reconnect) unawaited(evaluate());
      } else if (_everConnected &&
          (status is Disconnected || status is Reconnecting)) {
        _dropped = true;
      }
    });
    return null;
  }

  String _key(ReconnectUpdateKind kind, String tag) => '${kind.name}:$tag';

  /// 評估一次。公開是為了測試能直接驅動；正式路徑只由重連觸發。
  Future<void> evaluate() async {
    if (_evaluating || state != null) return;
    _evaluating = true;
    try {
      final prompt = await _decide();
      if (prompt != null && ref.mounted) state = prompt;
    } on Object {
      // 查不到就當沒有：這條路徑不該打斷使用者
    } finally {
      _evaluating = false;
    }
  }

  Future<ReconnectUpdatePrompt?> _decide() async {
    final app = AppVersion.ofBuild(ref.read(appBuildProvider));
    if (app == null) return null;
    final health = await ref.read(roomsApiProvider).health();
    final hub = AppVersion.tryParse('${health.build?['version'] ?? ''}');
    if (hub == null) return null;

    // 誰較舊：與版本橫幅同一份判斷（建置時間），不另寫一份
    final build = health.build;
    final appBuild = ref.read(appBuildProvider);
    if (BuildInfo.compare(appBuild, build) == VersionMatch.same) return null;
    var older = olderVersionSide(appBuild, build);
    // 講不出建置時間時退回比 x.y.z（Hub 不回熱修序號）
    older ??= switch (_base(app).compareTo(hub)) {
      < 0 => VersionSide.app,
      > 0 => VersionSide.hub,
      _ => null,
    };
    return switch (older) {
      VersionSide.app => _decideApp(),
      VersionSide.hub => _decideHub(hub),
      null => null,
    };
  }

  static AppVersion _base(AppVersion v) =>
      AppVersion(v.major, v.minor, v.patch);

  Future<ReconnectUpdatePrompt?> _decideApp() async {
    if (!ref.read(appUpdateEnabledProvider)) return null;
    final phase = ref.read(appUpdateProvider).phase;
    // 使用者已經在更新途中，別去重置它
    if (phase == AppUpdatePhase.checking ||
        phase == AppUpdatePhase.downloading ||
        phase == AppUpdatePhase.ready ||
        phase == AppUpdatePhase.applying) {
      return null;
    }
    await ref.read(appUpdateProvider.notifier).check();
    final next = ref.read(appUpdateProvider);
    if (next.phase != AppUpdatePhase.available) return null;
    if (_handled.contains(_key(ReconnectUpdateKind.app, next.tag))) return null;
    return ReconnectUpdatePrompt(ReconnectUpdateKind.app, next.tag);
  }

  Future<ReconnectUpdatePrompt?> _decideHub(AppVersion hub) async {
    // 本機 Hub＝這台機器登記了 Hub 主持包，且 App 連的就是它
    if (!ref.read(kitInstallSupportedProvider)) return null;
    final kit = await ref.read(hostKitProvider.future);
    if (kit == null) return null;
    if (!await _connectsToLocalHub()) return null;

    // 設定頁「更新」按鈕的保護：忙碌中、前置條件不過（沒有 Python）都不動
    if (ref.read(kitInstallsProvider.notifier).of(KitId.hub).busy) return null;
    final prereqs = await ref.read(kitPrereqsProvider(KitId.hub).future);
    if (prereqs.any((p) => !p.ok)) return null;

    // 與設定頁同一份 Release：anchored 在這份 App 的版本
    final release = await ref.read(kitReleaseProvider.future);
    if (release == null || release.assetFor(KitId.hub) == null) return null;
    final target = AppVersion.tryParse(release.tag);
    // Hub 不回熱修序號，視為 0；同 x.y.z 的熱修版 Release 比它新
    if (target == null || target.compareTo(_base(hub)) <= 0) return null;
    if (_handled.contains(_key(ReconnectUpdateKind.hub, release.tag))) {
      return null;
    }
    _hubRelease = release;
    _hubTarget = kit.kitRoot;
    return ReconnectUpdatePrompt(ReconnectUpdateKind.hub, release.tag);
  }

  Future<bool> _connectsToLocalHub() async {
    final url = ref.read(appConfigProvider).serverUrl;
    if (isLoopbackUrl(url)) return true;
    // 綁在特定介面（VPN／LAN IP）的本機 Hub：位址等於 `.env` 的 host
    final env = await ref.read(hostEnvProvider.future);
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    return env != null && env.host.isNotEmpty && env.host.toLowerCase() == host;
  }

  /// 使用者選「稍後」。
  void decline() {
    final p = state;
    if (p == null) return;
    _handled.add(_key(p.kind, p.tag));
    state = null;
  }

  /// 使用者選「更新」。回 `true`＝流程走到底沒出錯（App 是走到交給重啟腳本）。
  Future<bool> accept() async {
    final p = state;
    if (p == null) return false;
    _handled.add(_key(p.kind, p.tag));
    state = null;
    switch (p.kind) {
      case ReconnectUpdateKind.app:
        final notifier = ref.read(appUpdateProvider.notifier);
        await notifier.download();
        if (ref.read(appUpdateProvider).phase != AppUpdatePhase.ready) {
          return false;
        }
        await notifier.restart();
        return ref.read(appUpdateProvider).phase != AppUpdatePhase.failed;
      case ReconnectUpdateKind.hub:
        final release = _hubRelease;
        if (release == null) return false;
        await ref.read(kitInstallsProvider.notifier).installHub(
            release: release, targetDir: _hubTarget, restart: true);
        return ref.read(kitInstallsProvider.notifier).of(KitId.hub).phase ==
            KitInstallPhase.done;
    }
  }
}

final reconnectUpdateProvider =
    NotifierProvider<ReconnectUpdate, ReconnectUpdatePrompt?>(
        ReconnectUpdate.new);
