"""結構化日誌落檔。

存在的理由：測試人員回報「被踢的人還能繼續對話」時，**沒有任何紀錄能回答
當時到底發生了什麼**——是誰、拿哪張 token、從哪個位址、做了什麼。最後只能
靠重跑測試去推斷，而重跑測試證明的是「現在的程式碼」，不是「當時那台 Hub」。

一行一個 JSON 物件（JSON Lines）：grep 得動，也解析得動。人看的 message
與機器看的欄位並存，不必為了好讀而犧牲可查詢。

🚨 **絕不寫入 token 明碼。** 日誌檔會被複製、貼進聊天室、附在 issue 上，
每一次都是一份新的外洩機會。要辨識是哪一張，用 `token_hint`（前 8 碼）——
足以對照 `/api/tokens` 的列表，不足以拿來登入。
"""

from __future__ import annotations

import json
import logging
import logging.handlers
from datetime import datetime, timezone
from pathlib import Path

# LogRecord 內建欄位，序列化時要跳過（其餘的都是呼叫端用 extra= 帶進來的）
_BUILTIN = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename",
    "funcName", "levelname", "levelno", "lineno", "module", "msecs",
    "message", "msg", "name", "pathname", "process", "processName",
    "relativeCreated", "stack_info", "thread", "threadName", "taskName",
}


class JsonLinesFormatter(logging.Formatter):
    """一行一個 JSON 物件。"""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(
                record.created, tz=timezone.utc
            ).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key in _BUILTIN or key.startswith("_"):
                continue
            payload[key] = _safe(value)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # ensure_ascii=False：中文訊息要能直接讀，escape 過的日誌等於沒寫
        return json.dumps(payload, ensure_ascii=False, default=str)


def _safe(value):
    """能進 JSON 的原樣放，其餘轉字串。日誌不該因為某個欄位序列化失敗就整行消失。"""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def token_hint(token: str | None) -> str:
    """token 的可辨識片段。**永遠不要記錄完整 token。**

    8 碼足以對照 `/api/tokens` 的列表認出是哪一張，不足以拿來登入。
    """
    if not token:
        return ""
    return token[:8]


def setup_file_logging(
    logger: logging.Logger,
    log_dir: str | Path,
    *,
    max_bytes: int,
    backup_count: int,
) -> Path | None:
    """把 logger 接上輪替檔案 handler，回傳實際的日誌檔路徑。

    失敗一律回 None 並在既有 handler 上留一則警告——**日誌寫不出來不該讓
    Hub 起不來**。沒有日誌是可以忍受的降級，服務起不來不是。

    可重入：同一個 logger 重複呼叫只會有一個檔案 handler（測試會反覆
    `create_app`，不擋的話 handler 會一路疊上去，每則訊息寫 N 次）。
    """
    path = Path(log_dir) / "hub.jsonl"
    for existing in list(logger.handlers):
        if getattr(existing, "_chatroom_file_handler", False):
            if Path(getattr(existing, "baseFilename", "")) == path.resolve():
                return path
            logger.removeHandler(existing)
            existing.close()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=max_bytes, backupCount=backup_count, encoding="utf-8"
        )
    except OSError as exc:
        logger.warning("日誌落檔停用：%s 無法寫入（%s）", path, exc)
        return None
    handler.setFormatter(JsonLinesFormatter())
    handler._chatroom_file_handler = True  # type: ignore[attr-defined]
    logger.addHandler(handler)
    return path
