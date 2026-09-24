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
import '../../widgets/uep_button.dart';

/// 任務板設定頁：名稱、描述，以及這塊板的貢獻紀錄。
///
/// 從任務板頁首最右側的設定鈕進來。權限比照房間設定：**只有板 owner 改得
/// 動名稱與描述**，其他成員唯讀；封存的板整頁唯讀（Hub 對封存板的修改回
/// 409 `board_archived`）。改名與描述是板本身的事，不受週期凍結影響。
///
/// 貢獻紀錄是 Hub 從稽核串整理好的（見 [BoardContributions]），這裡只負責
/// 畫：上面每人統計，下面時間序列表。
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

  BoardContributions? _data;
  Object? _error;
  bool _dirty = false;
  bool _saving = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
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
        // 打到一半的字不能被重新整理蓋掉
        if (!_dirty) {
          _name.text = data.name;
          _description.text = data.description;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadMore() async {
    final data = _data;
    if (data == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await ref.read(boardsApiProvider).contributions(
          _boardId,
          sessionKey: _sessionKey,
          limit: _pageSize,
          offset: data.entries.length);
      if (mounted) setState(() => _data = data.appendPage(next));
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
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
    final l10n = AppLocalizations.of(context);
    final editable = data.isOwner && !data.isArchived && !_saving;
    final note = data.isArchived
        ? l10n.roomSettingsArchivedReadOnly
        : data.isOwner
            ? null
            : l10n.boardSettingsOwnerOnly;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            if (note != null) ...[
              MonoLabel(note, size: 9, letterSpacing: 1.2),
              const SizedBox(height: 14),
            ],
            _Label(l10n.roomsFieldName),
            _Field(
              controller: _name,
              enabled: editable,
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: 18),
            _Label(l10n.boardSettingsDescription),
            _Field(
              controller: _description,
              enabled: editable,
              maxLines: 3,
              hint: l10n.boardSettingsDescriptionHint,
              onChanged: (_) => _markDirty(),
            ),
            if (data.ownerName.isNotEmpty) ...[
              const SizedBox(height: 12),
              MonoLabel(l10n.boardSettingsOwner(data.ownerName),
                  size: 9, letterSpacing: 1.2),
            ],
            if (data.isOwner && !data.isArchived) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: UepButton(
                  label: l10n.commonSave,
                  small: true,
                  onPressed: editable && _dirty ? () => _save(data) : null,
                ),
              ),
            ],
            const SizedBox(height: 26),
            _Label(l10n.boardContribTitle),
            if (data.total == 0)
              EmptyState(title: l10n.boardContribEmpty)
            else ...[
              MonoLabel(l10n.boardContribStats, size: 8.5, letterSpacing: 1.2),
              const SizedBox(height: 8),
              for (final st in data.stats) _StatRow(stat: st),
              const SizedBox(height: 18),
              MonoLabel(l10n.boardContribLog, size: 8.5, letterSpacing: 1.2),
              const SizedBox(height: 8),
              for (final e in data.entries) _EntryRow(entry: e),
              if (data.hasMore) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: UepButton(
                    label: l10n.boardContribMore,
                    variant: UepButtonVariant.outline,
                    small: true,
                    onPressed: _loadingMore ? null : _loadMore,
                  ),
                ),
              ],
            ],
          ],
        ),
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

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stat});

  final ContributorStat stat;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final parts = [
      for (final e in stat.counts.entries)
        '${contributionActionLabel(l10n, e.key)} ${e.value}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Row(children: [
              Flexible(
                child: Text(
                  stat.actorName.isEmpty ? l10n.commonUnnamed : stat.actorName,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.serif(size: 13.5, color: s.ink),
                ),
              ),
              if (stat.actorKind.isNotEmpty) ...[
                const SizedBox(width: 6),
                KindBadge(kind: stat.actorKind, compact: true),
              ],
            ]),
          ),
          SizedBox(
            width: 56,
            child: Text(l10n.boardContribCount(stat.total),
                style: UepText.mono(size: 11, color: s.inkSoft)),
          ),
          Expanded(
            child: Text(parts.join(' · '),
                style: UepText.serif(size: 12.5, color: s.inkMute)),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final ContributionEntry entry;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(relativeTime(entry.at),
                style: UepText.mono(size: 10, color: s.inkMute)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: entry.actorName.isEmpty
                      ? l10n.commonUnnamed
                      : entry.actorName,
                  style: UepText.serif(size: 13, color: s.ink),
                ),
                TextSpan(
                  text: '  ${contributionActionLabel(l10n, entry.action)}',
                  style: UepText.serif(size: 13, color: s.inkSoft),
                ),
                if (entry.title.isNotEmpty)
                  TextSpan(
                    text: '  ${entry.title}',
                    style: UepText.serif(size: 13, color: s.inkMute),
                  ),
                if (entry.derived)
                  TextSpan(
                    text: '  *',
                    style: UepText.mono(size: 11, color: s.inkMute),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
    return entry.derived
        ? Tooltip(message: l10n.boardContribDerived, child: row)
        : row;
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: MonoLabel(text, size: 9.5, letterSpacing: 1.6),
      );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    this.maxLines = 1,
    this.hint,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final int maxLines;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.lineStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: controller,
        enabled: enabled,
        maxLines: maxLines,
        minLines: 1,
        onChanged: onChanged,
        style: UepText.serif(size: 14, color: s.ink, height: 1.6),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: UepText.serif(size: 13.5, color: s.inkMute),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}
