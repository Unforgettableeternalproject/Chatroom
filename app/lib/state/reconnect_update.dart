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
  const ReconnectUpdatePrompt(this.kind, this.tag, {this.unconfirmed = false});

  final ReconnectUpdateKind kind;

  /// 新版的 tag（`v1.2.8-hotfix1`）。
  final String tag;

  /// 本機 Hub：查不出 Hub 上有沒有進行中的 run（舊版 Hub 又逐房查失敗）。
  /// Dialog 內文要多講一句。
  final bool unconfirmed;
}

/// Release 比本機這一份新嗎（以時間為準，版本號之外的第二道門）。
///
/// 從 develop 建的測試版熱修序號是 0、版本號比已發布的 `-hotfixN` 小，
/// 但程式碼更新。本機建置時間不早於 Release 發布時間，就視為不需更新。
/// 任一邊講不出時間時不擋（退回只比版本）。
bool releaseNewerThanBuild(DateTime? publishedAt, String? builtAt) {
  final built = DateTime.tryParse(builtAt ?? '');
  if (publishedAt == null || built == null) return true;
  return built.isBefore(publishedAt);
}

/// Hub 上有進行中的 run 時，多久重查一次（直到歸零才問）。
final reconnectUpdateRecheckIntervalProvider =
    Provider<Duration>((ref) => const Duration(seconds: 30));

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
/// ## 有 run 進行中就延緩
///
/// 本機 Hub 較舊、但 Hub 上還有進行中的 agent run：不問、不顯示原因，
/// 每隔 [reconnectUpdateRecheckIntervalProvider] 重查，歸零才問。延緩期間
/// 又斷線就放棄，下次重連重新評估。查不出來（舊 Hub 逐房也失敗）時照常問，
/// 內文多一句「無法確認是否有進行中的工作」。
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
  Timer? _recheck;
  bool _deferred = false;

  void _cancelRecheck() {
    _recheck?.cancel();
    _recheck = null;
  }

  @override
  ReconnectUpdatePrompt? build() {
    ref.onDispose(_cancelRecheck);
    ref.listen(connectionStatusProvider, (previous, next) {
      final status = next.value;
      if (status is Connected) {
        // 新的一輪連線：舊的延緩作廢，重連會重新評估
        _cancelRecheck();
        final reconnect = _everConnected && _dropped;
        _everConnected = true;
        _dropped = false;
        if (reconnect) unawaited(evaluate());
      } else if (_everConnected &&
          (status is Disconnected || status is Reconnecting)) {
        _dropped = true;
        // 延緩期間又斷線：放棄，下次重連再評估
        _cancelRecheck();
      }
    });
    return null;
  }

  String _key(ReconnectUpdateKind kind, String tag) => '${kind.name}:$tag';

  /// 評估一次。公開是為了測試能直接驅動；正式路徑只由重連觸發。
  Future<void> evaluate() async {
    if (_evaluating || state != null) return;
    _evaluating = true;
    _cancelRecheck();
    _deferred = false;
    try {
      final prompt = await _decide();
      if (prompt != null && ref.mounted) state = prompt;
      if (_deferred && ref.mounted && _everConnected && !_dropped) {
        _recheck = Timer(ref.read(reconnectUpdateRecheckIntervalProvider), () {
          _recheck = null;
          if (ref.mounted && _everConnected && !_dropped) {
            unawaited(evaluate());
          }
        });
      }
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
      VersionSide.hub => _decideHub(hub, '${build?['built_at'] ?? ''}'),
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
    // 測試版（develop 建、熱修序號 0）可能比已發布的 Release 新
    final published =
        ref.read(appUpdateProvider.notifier).availableRelease?.publishedAt;
    if (!releaseNewerThanBuild(published, ref.read(appBuildProvider).builtAt)) {
      return null;
    }
    if (_handled.contains(_key(ReconnectUpdateKind.app, next.tag))) return null;
    return ReconnectUpdatePrompt(ReconnectUpdateKind.app, next.tag);
  }

  Future<ReconnectUpdatePrompt?> _decideHub(
      AppVersion hub, String hubBuiltAt) async {
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
    // 測試版 Hub 的建置時間晚於 Release 發布時間：不需更新
    if (!releaseNewerThanBuild(release.publishedAt, hubBuiltAt)) return null;
    if (_handled.contains(_key(ReconnectUpdateKind.hub, release.tag))) {
      return null;
    }

    // 進行中的 run：有就延緩（不問、不講原因），查不出來照問但內文警告
    final runs = await ref.read(kitInstallsProvider.notifier).checkHubActiveRuns();
    if (runs != null && runs.busy) {
      _deferred = true;
      return null;
    }
    _hubRelease = release;
    _hubTarget = kit.kitRoot;
    return ReconnectUpdatePrompt(ReconnectUpdateKind.hub, release.tag,
        unconfirmed: runs == null);
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
