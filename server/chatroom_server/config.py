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
    # long-poll 最長掛起秒數上限
    max_poll_timeout: float = 55.0
