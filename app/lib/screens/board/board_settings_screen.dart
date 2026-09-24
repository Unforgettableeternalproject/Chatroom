import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/relative_time.dart';
import '../../l10n/l10n.dart';
import '../../models/board_contributions.dart';
import '../../state/app_providers.dart';
import '../../state/board_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/settings_form.dart';
import '../../widgets/uep_button.dart';

/// 紀錄區塊的固定高度。紀錄會一直長，不能拿它撐高整頁——每人統計與上面
/// 的欄位要一直看得到（艾斯維爾 2026-09-24）。
const double kContributionLogHeight = 420;

/// 捲到離底部還有這麼多時就先載下一頁，捲到底時資料已經在路上。
const double _loadMoreThreshold = 120;

/// 任務板設定頁：名稱、描述，以及這塊板的貢獻紀錄。
///
/// 從任務板頁首最右側的設定鈕進來。權限比照房間設定：**只有板 owner 改得
/// 動名稱與描述**，其他成員唯讀；封存的板整頁唯讀（Hub 對封存板的修改回
/// 409 `board_archived`）。改名與描述是板本身的事，不受週期凍結影響。
///
/// 版面、字級與區段標題沿用設定頁（`settings_screen.dart`）：頁寬
/// [kPageMaxWidth]、區段標題 [UepText.itemTitle]、欄位用
/// [SettingsFieldLabel]／[SettingsInputBox]。字級一律跟著 App 的字級設定
/// （MediaQuery 的 textScaler），這裡不寫死任何徽章級的小字。
///
/// 貢獻紀錄是 Hub 從稽核串整理好的（見 [BoardContributions]），這裡只負責
/// 畫：上面每人統計，下面固定高度的紀錄區塊，捲到底才載下一頁。
class BoardSettingsScreen extends ConsumerStatefulWidget {
  const BoardSettingsScreen({super.key, required this.boardId, this.roomId});

  final String boardId;

  /// 從聊天室的板進來時是那間房——返回鍵要回到房軸那塊板，不是 BOARDS 分頁。
  final String? roomId;

  @override
  ConsumerState<BoardSettingsScreen> createState() =>
      _BoardSettingsScreenState();
}

class _BoardSettingsScreenState extends ConsumerState<BoardSettingsScreen> {
  static const _pageSize = 50;

  final _name = TextEditingController();
  final _description = TextEditingController();
  final _logScroll = ScrollController();

  BoardContributions? _data;
  Object? _error;
  bool _dirty = false;
  bool _saving = false;
  bool _loadingMore = false;

  /// Hub 說還有、卻回了空的一頁：不再要。不設這道閘的話，捲動監聽與
  /// 「區塊沒填滿就補載」會對著同一個 offset 一直打。
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    _logScroll.addListener(_onLogScroll);
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  String get _sessionKey => ref.read(appConfigProvider).deviceKey;

  /// 房軸網址帶著 `?board=`；少了它就從這間房掛的板取。
  String _boardId = '';

  Future<String> _resolveBoardId() async {
    if (_boardId.isNotEmpty) return _boardId;
    var id = widget.boardId;
    if (id.isEmpty && widget.roomId != null) {
      id = (await ref.read(boardProvider(widget.roomId!).future)).boardId;
    }
    return _boardId = id;
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final data = await ref
          .read(boardsApiProvider)
          .contributions(await _resolveBoardId(),
              sessionKey: _sessionKey, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _exhausted = false;
        // 打到一半的字不能被重新整理蓋掉
        if (!_dirty) {
          _name.text = data.name;
          _description.text = data.description;
        }
      });
      _fillLogIfShort();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool get _canLoadMore =>
      (_data?.hasMore ?? false) && !_loadingMore && !_exhausted;

  void _onLogScroll() {
    if (!_logScroll.hasClients || !_canLoadMore) return;
    final pos = _logScroll.position;
    if (pos.pixels >= pos.maxScrollExtent - _loadMoreThreshold) {
      _loadMore();
    }
  }

  /// 一頁不夠填滿區塊時沒有東西可捲，捲動監聽永遠不會觸發——補載到填滿
  /// 或沒有下一頁為止。
  void _fillLogIfShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logScroll.hasClients || !_canLoadMore) return;
      if (_logScroll.position.maxScrollExtent <= 0) _loadMore();
    });
  }

  Future<void> _loadMore() async {
    final data = _data;
    if (data == null || !_canLoadMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await ref.read(boardsApiProvider).contributions(
          _boardId,
          sessionKey: _sessionKey,
          limit: _pageSize,
          offset: data.entries.length);
      if (mounted) {
        setState(() {
          _data = data.appendPage(next);
          if (next.entries.isEmpty) _exhausted = true;
        });
      }
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
    _fillLogIfShort();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save(BoardContributions data) async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack(l10n.commonNameRequired);
      return;
    }
    final topic = _description.text.trim();
    setState(() => _saving = true);
    try {
      // 只送改過的：改名會在每間掛接房留一則系統訊息，沒變的也送就是噪音
      await ref.read(boardsApiProvider).updateSettings(
            _boardId,
            sessionKey: _sessionKey,
            name: name != data.name ? name : null,
            description: topic != data.description ? topic : null,
          );
      _dirty = false;
      _snack(l10n.roomSettingsSaved);
    } on ApiException catch (e) {
      _snack(e.message);
    }
    // 離開頁面之後 ref 不能再用，重讀的事交給下次進來
    if (!mounted) return;
    ref.invalidate(boardByIdProvider(_boardId));
    if (widget.roomId != null) {
      ref.invalidate(boardProvider(widget.roomId!));
    }
    ref.invalidate(boardLibraryProvider);
    setState(() => _saving = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final data = _data;

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
          onPressed: () => context.go(widget.roomId != null
              ? '/rooms/${widget.roomId}/board'
              : '/boards/$_boardId'),
        ),
        title: Text(
          l10n.boardSettingsTitle,
          style: UepText.pageTitle(color: s.inkTitle),
        ),
      ),
      body: data == null
          ? (_error != null
              ? ErrorState(
                  error: _error!,
                  onRetry: () {
                    setState(() => _error = null);
                    _load();
                  },
                )
              : const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: UepColors.gold,
                    ),
                  ),
                ))
          : _body(context, data),
    );
  }

  Widget _body(BuildContext context, BoardContributions data) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final editable = data.isOwner && !data.isArchived && !_saving;
    final note = data.isArchived
        ? l10n.roomSettingsArchivedReadOnly
        : data.isOwner
            ? null
            : l10n.boardSettingsOwnerOnly;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPageMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(32),
          children: [
            if (note != null) ...[
              Text(note,
                  style: UepText.serif(
                      size: 12.5, color: UepColors.gold, height: 1.4)),
              const SizedBox(height: 18),
            ],
            Text(l10n.settingsSectionBasics,
                style: UepText.itemTitle(color: s.inkTitle)),
            const SizedBox(height: 16),
            SettingsFieldLabel(l10n.roomsFieldName),
            SettingsInputBox(
              child: TextField(
                controller: _name,
                enabled: editable,
                style: UepText.sans(size: 13, color: s.ink),
                decoration: settingsInputDecoration(null, s),
                onChanged: (_) => _markDirty(),
              ),
            ),
            const SizedBox(height: 18),
            SettingsFieldLabel(l10n.boardSettingsDescription),
            SettingsInputBox(
              child: TextField(
                controller: _description,
                enabled: editable,
                maxLines: 3,
                minLines: 1,
                style: UepText.sans(size: 13, color: s.ink),
                decoration: settingsInputDecoration(
                    l10n.boardSettingsDescriptionHint, s),
                onChanged: (_) => _markDirty(),
              ),
            ),
            if (data.ownerName.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(l10n.boardSettingsOwner(data.ownerName),
                  style: UepText.sans(size: 13.5, color: s.inkSoft)),
            ],
            if (data.isOwner && !data.isArchived) ...[
              const SizedBox(height: 20),
              _saveRow(data),
            ],
            const SizedBox(height: 26),
            Divider(color: s.line, height: 1),
            const SizedBox(height: 22),
            Text(l10n.boardContribTitle,
                style: UepText.itemTitle(color: s.inkTitle)),
            const SizedBox(height: 16),
            if (data.total == 0)
              Text(l10n.boardContribEmpty,
                  style: UepText.serif(size: 13.5, color: s.inkMute))
            else ...[
              Text(l10n.boardContribStats,
                  style: UepText.sans(size: 13.5, color: s.inkTitle)),
              const SizedBox(height: 10),
              ContributorStatsTable(stats: data.stats),
              const SizedBox(height: 26),
              Text(l10n.boardContribLog,
                  style: UepText.sans(size: 13.5, color: s.inkTitle)),
              const SizedBox(height: 10),
              _logBox(context, data),
            ],
          ],
        ),
      ),
    );
  }

  /// 儲存：設定頁的主要按鈕（非 small），旁邊是「未儲存」提示。
  Widget _saveRow(BoardContributions data) {
    final l10n = AppLocalizations.of(context);
    final editable = data.isOwner && !data.isArchived && !_saving;
    return Row(children: [
      UepButton(
        label: l10n.commonSave,
        onPressed: editable && _dirty ? () => _save(data) : null,
      ),
      const SizedBox(width: 14),
      if (_dirty)
        Flexible(
          child: Text(l10n.settingsUnsavedChanges,
              style: UepText.serif(
                  size: 12.5, color: UepColors.gold, height: 1.4)),
        ),
    ]);
  }

  Widget _logBox(BuildContext context, BoardContributions data) {
    final s = context.uep;
    final entries = data.entries;
    final footer = _loadingMore ? 1 : 0;
    return Container(
      key: const ValueKey('board-contrib-log'),
      height: kContributionLogHeight,
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        controller: _logScroll,
        itemCount: entries.length + footer,
        separatorBuilder: (_, _) => Divider(height: 1, color: s.line),
        itemBuilder: (context, i) {
          if (i >= entries.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: UepColors.gold),
                ),
              ),
            );
          }
          return ContributionEntryRow(entry: entries[i]);
        },
      ),
    );
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }
}

/// 動作代碼 → 顯示文字。Hub 新增了這裡不認得的動作時照原字顯示，
/// 不吞掉那一筆。
String contributionActionLabel(AppLocalizations l10n, String action) =>
    switch (action) {
      'objective_created' => l10n.boardContribObjectiveCreated,
      'checklist_created' => l10n.boardContribChecklistCreated,
      'task_created' => l10n.boardContribTaskCreated,
      'task_done' => l10n.boardContribTaskDone,
      'checklist_done' => l10n.boardContribChecklistDone,
      'objective_review' => l10n.boardContribObjectiveReview,
      'objective_verified' => l10n.boardContribObjectiveVerified,
      'objective_done' => l10n.boardContribObjectiveDone,
      'objective_reopened' => l10n.boardContribObjectiveReopened,
      'released' => l10n.boardContribReleased,
      _ => action,
    };

/// 每人統計：名字＋種類｜件數（靠右）｜明細（可換行）三欄對齊。
///
/// 用 [Table]：件數欄取所有列裡最寬的那個（[IntrinsicColumnWidth]），
/// 名字欄與明細欄分剩下的寬度。寫死欄寬的話，字級一放大件數就會被擠到
/// 名字上（「去澳洲留學… CLAUDE2 件」那張截圖）。
class ContributorStatsTable extends StatelessWidget {
  const ContributorStatsTable({super.key, required this.stats});

  final List<ContributorStat> stats;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    const cell = EdgeInsets.symmetric(vertical: 10);
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: IntrinsicColumnWidth(),
        2: FlexColumnWidth(3),
      },
      border: TableBorder(horizontalInside: BorderSide(color: s.line)),
      children: [
        for (final st in stats)
          TableRow(
            children: [
              Padding(
                padding: cell.copyWith(right: 12),
                child: Row(children: [
                  Flexible(
                    child: Text(
                      st.actorName.isEmpty ? l10n.commonUnnamed : st.actorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.sans(size: 13.5, color: s.ink),
                    ),
                  ),
                  if (st.actorKind.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        st.actorKind.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.fieldLabel(
                            color: kindColor(st.actorKind, context: context)),
                      ),
                    ),
                  ],
                ]),
              ),
              Padding(
                padding: cell.copyWith(left: 4, right: 20),
                child: Text(l10n.boardContribCount(st.total),
                    textAlign: TextAlign.right,
                    style: UepText.sans(size: 13, color: s.inkSoft)),
              ),
              Padding(
                padding: cell,
                child: Text(
                  [
                    for (final e in st.counts.entries)
                      '${contributionActionLabel(l10n, e.key)} ${e.value}',
                  ].join(' · '),
                  style: UepText.sans(size: 13, color: s.inkMute),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// 紀錄的一列：誰／做了什麼／哪一項，時間靠右。
class ContributionEntryRow extends StatelessWidget {
  const ContributionEntryRow({super.key, required this.entry});

  final ContributionEntry entry;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: entry.actorName.isEmpty
                      ? l10n.commonUnnamed
                      : entry.actorName,
                  style: UepText.sans(size: 13.5, color: s.ink),
                ),
                TextSpan(
                  text: '  ${contributionActionLabel(l10n, entry.action)}',
                  style: UepText.sans(size: 13, color: s.inkSoft),
                ),
                if (entry.title.isNotEmpty)
                  TextSpan(
                    text: '  ${entry.title}',
                    style: UepText.sans(size: 13, color: s.inkMute),
                  ),
                if (entry.derived)
                  TextSpan(
                    text: '  *',
                    style: UepText.fieldLabel(color: s.inkMute),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Text(relativeTime(entry.at),
              style: UepText.fieldLabel(color: s.inkMute)),
        ],
      ),
    );
    return entry.derived
        ? Tooltip(message: l10n.boardContribDerived, child: row)
        : row;
  }
}
