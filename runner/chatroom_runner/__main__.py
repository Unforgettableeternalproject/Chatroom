"""執行器的進入點：``python -m chatroom_runner``。

退出碼是與排程工作的契約：

- ``0``：正常收工（drain 完成、被叫停）
- ``1``：啟動自檢沒過 —— 排程工作照原節奏再拉一次，人類會在房裡看到原因
- ``75``：請立刻重新拉起（維護窗、restart 命令）
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from logging.handlers import RotatingFileHandler

from .config import ConfigError, load_config
from .hub import RunnerHub, load_identity, save_identity
from .loop import EXIT_SELFCHECK_FAILED, RunnerLoop
from .usage import UsageStore


def _setup_logging(log_dir) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(log_dir / "runner.log", maxBytes=5_000_000,
                                  backupCount=5, encoding="utf-8")
    handler.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(handler)
    # pythonw.exe 底下沒有 console，``sys.stderr`` 是 None：掛上去的
    # StreamHandler 會在第一筆 log 就 AttributeError，而那時檔案 handler
    # 還沒寫到任何東西，看起來就是「執行器一起來就死」
    if sys.stderr is not None:
        root.addHandler(logging.StreamHandler(sys.stderr))


async def _main(args) -> int:
    cfg = load_config(args.config)
    _setup_logging(cfg.log_dir)
    log = logging.getLogger("chatroom_runner")
    identity = load_identity(cfg.state_file)
    usage = UsageStore(cfg.usage_db)
    usage.prune()
    async with RunnerHub(cfg.hub_url, cfg.agent_token,
                         identity=identity) as hub:
        loop = RunnerLoop(cfg, hub, usage_store=usage)
        if args.selfcheck_only:
            problems = await loop.selfcheck()
            for p in problems:
                log.error("自檢：%s", p)
            return EXIT_SELFCHECK_FAILED if problems else 0
        try:
            code = await loop.run_forever(max_ticks=args.max_ticks)
        finally:
            # token 可能在 register 時才拿到，離開前一定要落地
            save_identity(cfg.state_file, hub.identity)
            await loop.shutdown()
            usage.close()
        log.info("執行器結束，退出碼 %s（%s）", code,
                 loop.state.restart_reason or "無")
        return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="chatroom_runner", description="Chatroom 遠端派工執行器")
    parser.add_argument("--config", default=None, help="設定檔路徑")
    parser.add_argument("--selfcheck-only", action="store_true",
                        help="只跑啟動自檢然後結束（安裝後先跑這個）")
    parser.add_argument("--max-ticks", type=int, default=None,
                        help="跑幾輪就結束（除錯用）")
    args = parser.parse_args(argv)
    try:
        return asyncio.run(_main(args))
    except ConfigError as exc:
        if sys.stderr is not None:  # pythonw 底下沒有 stderr 可寫
            print(f"設定有問題：{exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:  # pragma: no cover
        return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
