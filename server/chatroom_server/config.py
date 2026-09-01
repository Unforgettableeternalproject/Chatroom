"""伺服器設定——全部可由環境變數覆寫，避免硬編碼。"""

import os
from dataclasses import dataclass, field


@dataclass
class Config:
    db_path: str = field(default_factory=lambda: os.environ.get("CHATROOM_DB", "chatroom.db"))
    host: str = field(default_factory=lambda: os.environ.get("CHATROOM_HOST", "127.0.0.1"))
    port: int = field(default_factory=lambda: int(os.environ.get("CHATROOM_PORT", "8787")))
    # 共享 API token；空字串代表不驗證（僅限本機開發）
    api_token: str = field(default_factory=lambda: os.environ.get("CHATROOM_TOKEN", ""))
    # agent 閒置多久後被自動移出房間（秒）
    idle_timeout: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_IDLE_TIMEOUT", "600"))
    )
    # subagent（ephemeral 成員）閒置多久後被回收（秒）。
    # 刻意與 idle_timeout 分開：subagent 是背景工作的臨時分身，工作結束就該
    # 消失。它正常退場靠自己 end_subagent，這條時限處理的是「被中斷／crash／
    # 忘了收」——那種殘骸掛在成員列上會誤導所有人。
    #
    # 原本是 120 秒，2026-09-01 改為 900。120 秒是照「crash 殘骸該多快消失」
    # 訂的，卻沒有照「一次真正的工作有多安靜」驗證過：規劃／審查型的子代理
    # 從登記到第一次發言中間隔十分鐘是常態（當天實測 632 秒），身分早就被
    # 回收，要交報告時才發現自己沒有身分——而登記與發言之間**本來就不會有
    # 任何呼叫**，續命的機會並不存在。
    # 拉長不會讓殘骸失控：父層離場會級聯帶走旗下所有 subagent，殘骸的最長
    # 存活本來就受父層限制，這條時限只決定「父層還在、子代理已死」那段窗口。
    subagent_timeout: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_SUBAGENT_TIMEOUT", "900"))
    )
    # presence sweeper 掃描間隔（秒）
    sweep_interval: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_SWEEP_INTERVAL", "30"))
    )
    # pending 指派多久後過期（秒），預設 24 小時
    assignment_ttl: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_ASSIGNMENT_TTL", "86400"))
    )
    # 自動封存前的倒數緩衝（秒）：條件成立後先倒數，期間條件解除即取消
    archive_grace: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_ARCHIVE_GRACE", "60"))
    )
    # 封存房間保留幾天後**永久刪除**；0 = 關閉自動清理。
    # 預設啟用（艾斯維爾 2026-08-30 裁決）——所以 Hub 啟動時會把這件事印出來，
    # 拉了新版起來的人不該在房間開始消失之後才知道有這個設定
    purge_archived_days: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_PURGE_ARCHIVED_DAYS", "3"))
    )
    # Hub 啟動後多久才做第一次自動清理（秒），預設 5 分鐘。
    # 這是**反悔窗口**：啟動時會把「這一輪會刪掉哪些房間」印出來，而 30 秒
    # 根本來不及讀完再 Ctrl-C。只有第一輪需要——那是唯一一次「剛換版、人在
    # 旁邊看著、而且可能不知道自己載入了什麼」的時刻
    purge_first_delay: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_PURGE_FIRST_DELAY", "300"))
    )
    # 孤兒附件實體的寬限（秒）。附件是內容定址的，刪房只能刪 DB row，實體要
    # 等「沒有任何 row 引用這個雜湊」才能刪；而剛寫入檔案、row 還沒落庫的那
    # 一瞬間看起來也像孤兒，所以要給一段寬限，預設 1 小時
    orphan_blob_grace: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_ORPHAN_BLOB_GRACE", "3600"))
    )
    # session 名錄：last_seen 在此窗內視為 active（秒）。watcher 的指派輪詢
    # 週期約 15~65 秒，窗口取其兩倍餘裕
    session_active_window: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_SESSION_ACTIVE_WINDOW", "180"))
    )
    # session 名錄：超過此時間未見的 session 不再列出（秒），預設 24 小時
    session_ttl: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_SESSION_TTL", "86400"))
    )
    # updates long-poll / WS 單批推送的訊息數上限
    updates_batch_limit: int = field(
        default_factory=lambda: int(os.environ.get("CHATROOM_UPDATES_LIMIT", "200"))
    )
    # 附件儲存目錄；空字串＝放在資料庫檔旁邊的 attachments/
    attachment_dir: str = field(
        default_factory=lambda: os.environ.get("CHATROOM_ATTACHMENT_DIR", "")
    )
    # 單一附件大小上限（位元組），預設 25 MB
    max_attachment_bytes: int = field(
        default_factory=lambda: int(
            os.environ.get("CHATROOM_MAX_ATTACHMENT_BYTES", str(25 * 1024 * 1024))
        )
    )
    # 日誌等級（chatroom logger）
    log_level: str = field(
        default_factory=lambda: os.environ.get("CHATROOM_LOG_LEVEL", "INFO")
    )
    # 結構化日誌的落檔目錄；空字串＝放在資料庫檔旁邊的 logs/
    log_dir: str = field(
        default_factory=lambda: os.environ.get("CHATROOM_LOG_DIR", "")
    )
    # 單一日誌檔上限（位元組）與保留份數。預設 10 MB × 5＝最多佔 50 MB：
    # 長跑的 Hub 不該把磁碟寫滿，但也要留得住足夠回溯一次事故的量
    log_max_bytes: int = field(
        default_factory=lambda: int(
            os.environ.get("CHATROOM_LOG_MAX_BYTES", str(10 * 1024 * 1024))
        )
    )
    log_backup_count: int = field(
        default_factory=lambda: int(os.environ.get("CHATROOM_LOG_BACKUPS", "5"))
    )
    # 向人類提問的有效時限（秒）。預設 3 分鐘——發問的 agent 是卡在那裡等的，
    # 不是留言給人類；時限拉長不是「比較寬容」，是讓一條工作流癱瘓那麼久。
    # 逾時只標記狀態不刪紀錄，人類仍看得到問過什麼
    question_ttl: float = field(
        default_factory=lambda: float(os.environ.get("CHATROOM_QUESTION_TTL", "180"))
    )
    # long-poll 最長掛起秒數上限
    max_poll_timeout: float = 55.0
