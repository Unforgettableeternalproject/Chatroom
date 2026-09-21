/// 本機執行器的起停——**與 `scripts/hub-service.ps1` 對 Hub 做的是同一件事**。
///
/// 控制的對象是 Windows 排程工作（`runner/install-task.ps1` 建的那個），
/// 不是某個進程：執行器設了失敗自動重啟（`RestartCount 999`、每分鐘重試）
/// 加上每 5 分鐘一次的存活觸發，所以**只殺進程等於沒停**——一分鐘之內
/// 排程就把它拉回來，而畫面已經說「已停止」了。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'kit_installer.dart';
import 'runner_kit_providers.dart';

/// 排程工作的預設名。安裝器的 `--task-name` 改得掉，所以要先問註冊檔。
const String kRunnerTaskName = 'ChatroomRunner';

/// 執行器進程的認法：命令列裡有 `-m chatroom_runner`。
///
/// 不看執行檔名：排程工作起的是 `pythonw.exe`，手跑的是 `python.exe`，
/// 而兩者都是「執行器在跑」。
const String kRunnerCommandLineMark = '-m chatroom_runner';

enum RunnerServiceState {
  /// 排程工作在跑，或找得到執行器的進程。
  running,

  /// 工作在（Ready），但沒有在執行。
  stopped,

  /// 觸發器被停用了——這是 `stop` 留下的狀態，**不按啟動就不會自己回來**。
  disabled,

  /// 問不到（不是 Windows、沒有那個工作、PowerShell 出錯）。
  unknown,
}

@immutable
class RunnerServiceStatus {
  const RunnerServiceStatus(this.state,
      {this.taskName = kRunnerTaskName, this.detail = ''});

  final RunnerServiceState state;
  final String taskName;

  /// 問不到時的那一句（stderr 的第一行）。畫面上照原文轉述。
  final String detail;
}

/// 這台機器上的排程工作叫什麼。
///
/// 安裝器可以用 `--task-name` 改名，改過的話註冊檔裡會有 `task_name`；
/// 沒有就是預設的 [kRunnerTaskName]——**不猜別的名字**。
final runnerTaskNameProvider = FutureProvider<String>((ref) async {
  final file = runnerKitRegistryFile();
  if (file == null) return kRunnerTaskName;
  try {
    if (!await file.exists()) return kRunnerTaskName;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return kRunnerTaskName;
    final name = json['task_name'];
    if (name is String && name.trim().isNotEmpty) return name.trim();
  } on Object {
    return kRunnerTaskName;
  }
  return kRunnerTaskName;
});

/// 執行器現在手上有幾筆 run。
///
/// 讀的是執行器自己落地的 `state.json`（同 `runnerBusyProvider`）。
/// 讀不到回 0：這個數字只用來把停止的後果講得更清楚，**沒有它照樣要問**，
/// 而把「不知道」說成「有 N 筆」會讓人以為畫面知道一件它不知道的事。
final runnerActiveRunCountProvider = FutureProvider<int>((ref) async {
  final cfg = await ref.watch(runnerConfigProvider.future);
  if (cfg == null) return 0;
  final file = runnerStateFileFor(cfg);
  if (file == null) return 0;
  try {
    if (!await file.exists()) return 0;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return 0;
    final ids = json['active_run_ids'];
    return ids is List ? ids.length : 0;
  } on Object {
    return 0;
  }
});

/// PowerShell 的單引號字串：裡面的單引號要成雙。
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// 起停執行器。子進程走 [KitProcessRunner]，測試換成 fake。
class RunnerServiceController {
  const RunnerServiceController(
      {required this.processRunner, required this.taskName});

  final KitProcessRunner processRunner;
  final String taskName;

  String get _task => _psQuote(taskName);

  /// 停止。**順序不能換**：
  ///
  /// 1. `Disable-ScheduledTask`——先拿掉觸發器。只 `Stop` 的話，失敗重啟
  ///    與每 5 分鐘的存活觸發會在一分鐘內把執行器拉回來。
  /// 2. `Stop-ScheduledTask`——停掉現在這一次。
  /// 3. 殺掉命令列帶 `-m chatroom_runner` 的進程——排程停止收不掉手跑的
  ///    那一份，而「停止」的定義是這台機器上沒有執行器在動。
  Future<String?> stop() => _runAll([
        'Disable-ScheduledTask -TaskName $_task '
            '-ErrorAction SilentlyContinue | Out-Null',
        'Stop-ScheduledTask -TaskName $_task '
            '-ErrorAction SilentlyContinue | Out-Null',
        'Get-CimInstance Win32_Process '
            "| Where-Object { \$_.CommandLine -like '*$kRunnerCommandLineMark*' } "
            '| ForEach-Object { Stop-Process -Id \$_.ProcessId -Force '
            '-ErrorAction SilentlyContinue }',
      ]);

  /// 啟動。`Enable` 一定要在前面：停過一次之後觸發器是停用的，
  /// 不先啟用的話這一次起得來，下次開機不會。
  Future<String?> start() => _runAll([
        'Enable-ScheduledTask -TaskName $_task '
            '-ErrorAction SilentlyContinue | Out-Null',
        'Start-ScheduledTask -TaskName $_task',
      ]);

  /// 一步一步跑；哪一步失敗就停在那裡，把 stderr 的第一行帶回去。
  /// 回 `null` 代表整串都過了。
  Future<String?> _runAll(List<String> scripts) async {
    for (final script in scripts) {
      try {
        final r = await processRunner
            .run('powershell', ['-NoProfile', '-Command', script]);
        if (r.exitCode != 0) return _firstLine('${r.stderr}${r.stdout}');
      } on Object catch (e) {
        return _firstLine('$e');
      }
    }
    return null;
  }
}

String _firstLine(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.split('\n').first.trim();
}

final runnerServiceControllerProvider =
    FutureProvider<RunnerServiceController>((ref) async {
  return RunnerServiceController(
    processRunner: ref.watch(kitProcessRunnerProvider),
    taskName: await ref.watch(runnerTaskNameProvider.future),
  );
});

/// 執行器現在的狀態。
///
/// 判準兩項合起來看：
///
/// * 排程工作的 `State`——`Disabled` 直接就是「已停用」，那是停止留下的
///   狀態，光看有沒有進程看不出來（沒進程也可能只是還沒到觸發時間）。
/// * 有沒有命令列帶 `-m chatroom_runner` 的進程——手跑的那一份排程不知道，
///   但它確實在接派工。
///
/// **出錯回 [RunnerServiceState.unknown]，不丟例外**：這一格是一顆按鈕的
/// 旁白，讓 provider 進入 error 狀態的話畫面會卡在讀取中並反覆重試。
final runnerServiceStatusProvider =
    FutureProvider<RunnerServiceStatus>((ref) async {
  final taskName = await ref.watch(runnerTaskNameProvider.future);
  // 排程工作是 Windows 才有的東西；其他平台問不到，也不該畫一顆按不動的按鈕
  if (!ref.watch(kitInstallSupportedProvider)) {
    return RunnerServiceStatus(RunnerServiceState.unknown, taskName: taskName);
  }
  final script = '\$ErrorActionPreference = \'SilentlyContinue\'; '
      '\$t = Get-ScheduledTask -TaskName ${_psQuote(taskName)}; '
      'if (\$t) { Write-Output "TASK=\$(\$t.State)" } '
      'else { Write-Output \'TASK=missing\' }; '
      '\$p = @(Get-CimInstance Win32_Process '
      "| Where-Object { \$_.CommandLine -like '*$kRunnerCommandLineMark*' }); "
      'Write-Output "PROC=\$(\$p.Count)"';
  try {
    final r = await ref
        .watch(kitProcessRunnerProvider)
        .run('powershell', ['-NoProfile', '-Command', script]);
    if (r.exitCode != 0) {
      return RunnerServiceStatus(RunnerServiceState.unknown,
          taskName: taskName, detail: _firstLine('${r.stderr}${r.stdout}'));
    }
    return RunnerServiceStatus(parseRunnerServiceState('${r.stdout}'),
        taskName: taskName);
  } on Object catch (e) {
    return RunnerServiceStatus(RunnerServiceState.unknown,
        taskName: taskName, detail: _firstLine('$e'));
  }
});

/// 解析上面那段腳本印回來的兩行。
///
/// 進程優先於 `Ready`：工作可以是 Ready 而人在前景手跑一份執行器，那時
/// 說「已停止」是假的。但 `Disabled` 優先於進程——那台機器下次開機不會再
/// 起來，這件事比現在有沒有人在跑更需要被看見。
@visibleForTesting
RunnerServiceState parseRunnerServiceState(String stdout) {
  var task = '';
  var procs = 0;
  for (final line in stdout.split('\n')) {
    final text = line.trim();
    if (text.startsWith('TASK=')) task = text.substring(5).trim();
    if (text.startsWith('PROC=')) {
      procs = int.tryParse(text.substring(5).trim()) ?? 0;
    }
  }
  final state = task.toLowerCase();
  if (state == 'disabled') return RunnerServiceState.disabled;
  if (state == 'running' || procs > 0) return RunnerServiceState.running;
  if (state == 'ready') return RunnerServiceState.stopped;
  // 連工作都沒有、又沒有進程：這台機器上沒有東西可停，也沒有東西可報
  return RunnerServiceState.unknown;
}
