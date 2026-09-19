"""Chatroom 執行器安裝器（runner 端）。

    python install.py                  # 互動式：Hub 位址 / token / 標籤
    python install.py --yes            # 不互動，全用預設／參數值
    python install.py --uninstall      # 移除排程工作與註冊檔（設定與資料留著）

`--yes` 下**一個問題都不會問**（App 是以子進程跑這支的），而且 stdout 的
最後一行固定是 `RESULT {"ok":true,...}`——三包安裝器同一個格式。失敗時
退出碼非 0、原因走 stderr。

做五件事：
1. 把這一包搬到安裝目錄（預設 %LOCALAPPDATA%\\UEP\\Chatroom\\runner-kit）
2. 在包內建立獨立 venv 並安裝執行器與 bridge 的相依（不污染系統 Python）
3. 產生設定檔（預設 %LOCALAPPDATA%\\UEP\\Chatroom\\runner\\config.json）；
   **已經存在就原樣不動**——那份是使用者自己調過的，重跑安裝器不該吃掉它
4. 呼叫既有的 runner/install-task.ps1 註冊 Windows 排程工作（只建工作、
   不啟動執行器）
5. 寫下註冊檔 ~/.chatroom/runner-kit.json，讓桌面 App 知道這台機器是執行器

⚠️ 裝完還**不能**直接開跑，還有兩件只有人做得到的事（README 有步驟）：
獨立 CLAUDE_CONFIG_DIR 要先 `claude /login`，以及設定檔裡要加專案。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

KIT = Path(__file__).resolve().parent
KIT_NAME = "runner-kit"

# 桌面 App 靠這份檔案知道「這台機器上有一台執行器，它在哪」。
#
# ⚠️ **它只是一個指路牌，不是設定檔。** 真相在 config.json 與實際跑著的
# 排程工作裡——App 讀這裡拿路徑，其餘一律現查。寫成第二份設定的話，兩邊
# 遲早不一樣，而使用者會看到一個講得很篤定卻是錯的畫面。
REGISTRY = Path.home() / ".chatroom" / "runner-kit.json"

DEFAULT_TASK_NAME = "ChatroomRunner"

# 執行器本身只用到 httpx（其餘是標準庫）；bridge 另外要 mcp。
# 版本界線沿用 bridge/pyproject.toml——**兩邊一定要一致**，不然這包裡的
# bridge 與 install-kit 發出去的那包會是不同的東西。
DEPS = ["httpx>=0.28.1,<0.29", "mcp>=2.1.1,<3.0"]


def emit_result(payload: dict) -> None:
    """印出給呼叫端（桌面 App 以子進程跑這支）解析的單行結果。

    ⚠️ **三包安裝器的格式一致、而且永遠是 stdout 的最後一行**：
    `RESULT {"ok":true,...}`。App 只讀這一行，上面的人類文字它不解析——
    格式漂掉的話 App 會判成「裝失敗」，而安裝其實是成功的。
    """
    print("RESULT " + json.dumps(payload, ensure_ascii=False,
                                 separators=(",", ":")), flush=True)


def die(msg: str, **extra) -> "NoReturn":  # noqa: F821
    """錯誤走 stderr、結果行走 stdout、退出碼非 0。"""
    print(f"❌ {msg}", file=sys.stderr, flush=True)
    emit_result({"ok": False, "kit": KIT_NAME, "error": msg, **extra})
    raise SystemExit(1)


def build_info(root: Path) -> dict[str, str]:
    """這一包的版本與 commit（打包時寫下的 `_build.json`）。

    讀不到就是空字串——原始碼樹裡跑安裝器時本來就沒有這個檔案，
    「不知道」要看得出來，不要編一個版本出來。
    """
    try:
        data = json.loads(
            (root / "runner" / "chatroom_runner" / "_build.json")
            .read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"version": "", "commit": ""}
    if not isinstance(data, dict):
        return {"version": "", "commit": ""}
    return {"version": str(data.get("version") or ""),
            "commit": str(data.get("commit") or "")}


def local_app_data() -> Path:
    """Windows 的 `%LOCALAPPDATA%`；非 Windows 退回同構的路徑。"""
    env = os.environ.get("LOCALAPPDATA")
    if env:
        return Path(env)
    return Path.home() / "AppData" / "Local"


def default_install_dir() -> Path:
    return local_app_data() / "UEP" / "Chatroom" / "runner-kit"


def default_config_path() -> Path:
    """與 `chatroom_runner.config.default_state_dir()` 同一個位置。

    不是隨便挑的：執行器沒有 `--config` 時自己就去那裡找，排程工作也是用
    這個路徑當參數。改這裡等於改三個地方的預設值。
    """
    return local_app_data() / "UEP" / "Chatroom" / "runner" / "config.json"


def ask(prompt: str, default: str = "") -> str:
    tip = f"（預設 {default}）" if default else ""
    return input(f"{prompt}{tip}: ").strip() or default


def venv_python(target: Path) -> Path:
    sub = "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
    return target / ".venv" / sub


def stage_kit(target: Path) -> None:
    """把包內容搬到安裝目錄。已經在那裡跑就什麼都不做。

    `.venv` 不複製：裡面是絕對路徑，搬過去的那份直譯器指向舊位置。
    """
    target.mkdir(parents=True, exist_ok=True)
    if KIT == target:
        return
    for name in ("install.py", "README.md"):
        src = KIT / name
        if src.exists():
            shutil.copy2(src, target / name)
    for name in ("runner", "bridge"):
        src = KIT / name
        if not src.exists():
            # 走 die()：錯誤要進 stderr，而且結果行仍然要印，否則以子進程
            # 呼叫的 App 只看得到一個沒有理由的非 0 退出碼
            die(f"這一包裡沒有 {name}/——交付包不完整，"
                "請重新解壓 chatroom-runner-kit.zip")
        shutil.copytree(src, target / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    print(f"已安裝到 {target}")


def ensure_venv(target: Path) -> Path:
    python = venv_python(target)
    if not python.exists():
        print("建立 venv…")
        subprocess.run([sys.executable, "-m", "venv", str(target / ".venv")],
                       check=True)
    print("安裝相依套件…")
    subprocess.run([str(python), "-m", "pip", "install", "--quiet", *DEPS],
                   check=True)
    return python


def write_pth(python: Path, target: Path) -> bool:
    """讓這個 venv import 得到 `chatroom_runner`。

    與 `install-task.ps1` 寫的是**同一行 .pth**（同名、同內容，重複寫是冪等
    的）。這裡也寫一份，是因為那支腳本只在註冊排程工作時才跑：`--no-task`
    裝出來的 venv 否則連 `-m chatroom_runner --selfcheck-only` 都跑不起來，
    而安裝器最後印的正是那一行指令。

    問不到 site-packages 就放棄並說出來——不要假裝寫過了。
    """
    try:
        out = subprocess.run(
            [str(python), "-c",
             "import sysconfig;print(sysconfig.get_paths()['purelib'])"],
            capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"⚠️ 取不到 site-packages 路徑（{exc}）")
        return False
    purelib = Path(out.stdout.strip()) if out.returncode == 0 else None
    if not purelib or not purelib.is_dir():
        print(f"⚠️ 取不到 site-packages 路徑（{python}）")
        return False
    (purelib / "chatroom_runner.pth").write_text(
        str(target / "runner") + "\n", encoding="ascii")
    return True


def build_config(example: dict, *, hub_url: str, agent_token: str,
                 host: str, label: str, kit_dir: Path,
                 state_dir: Path) -> dict:
    """依樣板產生這台機器的設定內容。

    以樣板為底、只覆蓋安裝器問得到的那幾個欄位：其餘（退避階梯、允許的
    網域、軟上限…）是樣板作者調過的預設值，安裝器沒有理由自己重寫一份。

    `workspaces` 一律留空：安裝器不問專案路徑——那是「加工作區」的事，
    而它需要的資訊（哪些分支可動、skill 目錄在哪）不是安裝當下答得出來的。
    """
    cfg = dict(example)
    for key in list(cfg):
        if key.startswith("_"):
            cfg.pop(key)
    cfg.update({
        "hub_url": hub_url,
        "agent_token": agent_token,
        # 樣板指到 repo 的 server/.env——kit 形態下沒有那個檔案，留著只會
        # 讓 token 解析多繞一圈然後失敗
        "token_env_file": "",
        "host": host,
        "label": label,
        "state_dir": str(state_dir),
        "claude_config_dir": str(state_dir / "claude-config"),
        # 執行器起 run 時掛給 claude 的 MCP 伺服器就在這一包裡
        "bridge_path": str(kit_dir / "bridge"),
        # 工作區（舊鍵 `projects`）留空；樣板若是舊格式，舊鍵也要一起清掉
        "workspaces": {},
    })
    cfg.pop("projects", None)
    return cfg


def write_config(config_path: Path, payload: dict) -> bool:
    """寫設定檔。**已存在就不覆寫**，回傳有沒有真的寫。

    🔴 重跑安裝器多半是因為「有什麼壞了想重裝看看」，而那時設定檔裡是
    使用者加好的每一個專案、repo 路徑與允許分支。覆寫掉的話執行器會照常
    起來、照常註冊，只是**一筆單都領不到**——而畫面從頭到尾顯示成功。
    """
    if config_path.exists():
        print(f"設定檔已存在，原樣保留：{config_path}")
        return False
    config_path.parent.mkdir(parents=True, exist_ok=True)
    # 先寫暫存再換名：寫到一半失敗時留下的是「沒有設定檔」，不是半個 JSON
    # ——後者會讓執行器每次啟動都以解析錯誤退出，而症狀看起來像程式壞了
    tmp = config_path.with_name(config_path.name + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    tmp.replace(config_path)
    print(f"已寫入 {config_path}")
    return True


def powershell() -> str | None:
    return shutil.which("pwsh") or shutil.which("powershell")


def register_task(target: Path, python: Path, config_path: Path,
                  task_name: str) -> bool:
    """呼叫既有的 `runner/install-task.ps1` 建排程工作。

    ⚠️ `-Python` 一定要顯式給：腳本的預設值是 `$RepoRoot\\.venv\\...`，
    在 kit 形態下那個路徑不存在（venv 在包的根目錄，而 `-RepoRoot` 也是
    包的根目錄——這兩個剛好一致，但依賴巧合的話搬過位置就壞）。

    失敗不中止安裝：執行器本體已經可用，手跑一次腳本就補得回來。
    """
    script = target / "runner" / "install-task.ps1"
    shell = powershell()
    if not script.exists() or shell is None:
        print(f"⚠️ 找不到 {script} 或 PowerShell——排程工作沒建，"
              "執行器不會自己啟動")
        return False
    print(f"註冊排程工作「{task_name}」…")
    done = subprocess.run([
        shell, "-NoProfile", "-File", str(script),
        "-TaskName", task_name,
        "-RepoRoot", str(target),
        "-Python", str(python),
        "-ConfigPath", str(config_path),
        "-Force",
    ])
    if done.returncode != 0:
        print(f"⚠️ 排程工作註冊失敗（退出碼 {done.returncode}）。"
              f"可之後手動執行：{script}")
        return False
    return True


def write_registry(kit_dir: Path, python: Path, config_path: Path) -> dict:
    """寫下指路牌，讓桌面 App 認得這台機器上的執行器。

    **欄位名是與 App 約好的契約**（`kit_dir`／`python`／`config`／
    `installed_at`），改名等於讓 App 當成「沒裝」。

    **失敗不中止安裝**：沒有它只是 App 少一個分頁，執行器本身照跑。
    """
    info = build_info(kit_dir)
    payload = {
        # ⚠️ `version` 是**這份登錄檔的格式版本**，kit 的版本在
        # `kit_version`／`commit`。兩者混用過一次就再也分不開
        "version": 1,
        "kit_dir": str(kit_dir),
        # `kit_root` 與 `kit_dir` 同值：前者是三包共用的欄位名（host-kit 與
        # mcp-kit 都叫這個），後者是 App 現在讀的那個。**兩個都要寫**——
        # 只留新的會讓現有的 App 當成「沒裝」
        "kit_root": str(kit_dir),
        "python": str(python),
        "config": str(config_path),
        "installed_at": datetime.now(timezone.utc).isoformat(
            timespec="seconds"),
        "kit_version": info["version"],
        "commit": info["commit"],
    }
    try:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        # 先寫暫存再換名：中途失敗時留下的是舊的那份，不是半個 JSON。
        # 一個解析不了的指路牌會讓 App 每次啟動都當成「壞了」而不是「沒有」
        tmp = REGISTRY.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")
        tmp.replace(REGISTRY)
        print(f"已寫入 {REGISTRY}")
    except OSError as exc:
        print(f"⚠️ 註冊檔寫不進去（{exc}）——桌面 App 會以為這台沒有執行器，"
              f"但執行器本身不受影響。手動建立：{REGISTRY}")
    return payload


def uninstall(task_name: str) -> None:
    """移除排程工作與註冊檔。

    **不刪設定檔、不刪 state／log**：那些是使用者的資料，而「移除」最常見的
    下一步是重裝——把設定一起刪掉會讓重裝的人以為自己從來沒設定過。
    """
    shell = powershell()
    if shell is None:
        print("⚠️ 找不到 PowerShell，排程工作請手動移除")
    else:
        # 先問在不在，再決定要不要移除：直接 Unregister 一個不存在的工作，
        # pwsh 會以退出碼 1 結束（即使 -ErrorAction SilentlyContinue）。
        # 那時印「移除失敗」是**錯的**——人會以為工作還在，跑去找一個不存在
        # 的東西。「本來就沒有」與「移不掉」要分開講。
        done = subprocess.run([
            shell, "-NoProfile", "-Command",
            f"$t = Get-ScheduledTask -TaskName '{task_name}' "
            "-ErrorAction SilentlyContinue; "
            f"if ($t) {{ Unregister-ScheduledTask -TaskName '{task_name}' "
            "-Confirm:$false; 'removed' } else { 'absent' }",
        ], capture_output=True, text=True)
        out = (done.stdout or "").strip()
        if done.returncode == 0 and "removed" in out:
            print(f"已移除排程工作「{task_name}」")
        elif done.returncode == 0:
            print(f"沒有排程工作「{task_name}」可移除")
        else:
            print(f"⚠️ 移除排程工作失敗（退出碼 {done.returncode}）"
                  f"{(': ' + done.stderr.strip()) if done.stderr else ''}")
    try:
        if REGISTRY.exists():
            REGISTRY.unlink()
            print(f"已移除 {REGISTRY}")
        else:
            print(f"沒有註冊檔可移除（{REGISTRY}）")
    except OSError as exc:
        print(f"⚠️ 註冊檔刪不掉（{exc}）：{REGISTRY}")
    print("\n設定檔與 state／log 留著沒動——要整包清掉請自行刪除安裝目錄與 "
          f"{default_config_path().parent}")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description="Chatroom 執行器安裝器")
    # ⚠️ help 字串會被 argparse 拿去做 `%` 展開，所以 `%LOCALAPPDATA%` 必須
    # 寫成 `%%LOCALAPPDATA%%`。不跳脫的話 `--help` 直接拋 ValueError——
    # 而那是使用者（與 App 的作者）查得到參數清單的唯一入口
    p.add_argument("--dir", help="安裝目錄，預設 "
                                 "%%LOCALAPPDATA%%\\UEP\\Chatroom\\runner-kit")
    p.add_argument("--hub-url", help="Hub 位址，例如 http://192.0.2.10:8787")
    p.add_argument("--token", help="Agent token（Hub 的 CHATROOM_TOKEN）")
    p.add_argument("--host", help="註冊用的機器名，預設本機名稱")
    p.add_argument("--label", help="註冊用的標籤（同 host+label 在 Hub 是同一台）")
    p.add_argument("--config", help="設定檔路徑，預設 "
                                    "%%LOCALAPPDATA%%\\UEP\\Chatroom\\runner\\config.json")
    p.add_argument("--task-name", default=DEFAULT_TASK_NAME,
                   help=f"排程工作名稱，預設 {DEFAULT_TASK_NAME}")
    p.add_argument("--no-task", action="store_true",
                   help="不註冊排程工作（之後可手動跑 runner/install-task.ps1）")
    p.add_argument("--yes", action="store_true", help="不互動，全用預設／參數值")
    p.add_argument("--uninstall", action="store_true",
                   help="移除排程工作與註冊檔；設定與資料留著")
    args = p.parse_args(argv)

    if args.uninstall:
        uninstall(args.task_name)
        emit_result({"ok": True, "kit": KIT_NAME, "action": "uninstall",
                     "registry": str(REGISTRY)})
        return

    if sys.version_info < (3, 12):
        die(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")

    print("=== Chatroom 執行器安裝 ===\n")

    target = Path(args.dir).expanduser().resolve() if args.dir \
        else default_install_dir()
    config_path = Path(args.config).expanduser().resolve() if args.config \
        else default_config_path()

    default_host = os.environ.get("COMPUTERNAME") or ""
    if not default_host and hasattr(os, "uname"):
        default_host = os.uname().nodename
    default_host = default_host or "runner"

    if args.yes:
        hub_url = args.hub_url or "http://127.0.0.1:8787"
        token = args.token or ""
        host = args.host or default_host
        label = args.label or "runner"
    else:
        hub_url = args.hub_url or ask("Hub 位址", "http://127.0.0.1:8787")
        token = args.token or ask("Agent token（可留空，之後填進設定檔）")
        host = args.host or ask("機器名", default_host)
        label = args.label or ask("標籤", "runner")

    # 這三步任何一步失敗都是真的裝不起來。讓它變成一句話 + 非 0 退出碼，
    # 而不是一坨 traceback——呼叫端（App）要讀得懂
    try:
        stage_kit(target)
        python = ensure_venv(target)
        write_pth(python, target)

        example = json.loads(
            (target / "runner" / "config.example.json")
            .read_text(encoding="utf-8"))
        wrote = write_config(config_path, build_config(
            example, hub_url=hub_url, agent_token=token, host=host,
            label=label, kit_dir=target, state_dir=config_path.parent))
    except SystemExit:
        raise
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        die(f"安裝失敗：{exc}")

    task_ok = False if args.no_task else register_task(
        target, python, config_path, args.task_name)
    registry = write_registry(target, python, config_path)

    config_note = "" if wrote else (
        "\n   （設定檔原本就在，這次沒有動它——上面問的 Hub 位址與 token "
        "**沒有**寫進去）")
    task_note = ("排程工作「%s」已建立，但**還沒啟動**。" % args.task_name
                 if task_ok else
                 "排程工作沒建（--no-task 或註冊失敗），執行器不會自己啟動。")
    print(f"""
✅ 安裝完成。

   安裝目錄：{target}
   直譯器　：{python}
   設定檔　：{config_path}{config_note}

還要做兩件只有人做得到的事：

1. 加工作區——設定檔的 `workspaces` 現在是空的，執行器會註冊上線但領不到
   任何單。用 App 的執行器分頁加，或直接編輯 {config_path}。
   ⚠️ kit 不含要被派工的 repo：那些工作樹仍然要存在於這台機器上，路徑填進
   `workspaces.<key>.projects.<name>.path`。

2. 登入獨立的 CLAUDE_CONFIG_DIR（只要做一次）：

   $env:CLAUDE_CONFIG_DIR = "{config_path.parent}\\claude-config"
   claude /login

接著自檢（不領單、不起 agent）：

   "{python}" -m chatroom_runner --config "{config_path}" --selfcheck-only

{task_note}
自檢過了再 Start-ScheduledTask -TaskName {args.task_name}。
""")

    # ⚠️ 這一行要是 stdout 的最後一行：App 解析它來判斷裝到哪、版本是什麼
    emit_result({
        "ok": True,
        "kit": KIT_NAME,
        "registry": str(REGISTRY),
        "kit_root": str(target),
        "python": str(python),
        "config": str(config_path),
        "version": registry["kit_version"],
        "commit": registry["commit"],
        "installed_at": registry["installed_at"],
        # 設定檔本來就在的話，這次問到的 hub_url／token **沒有**寫進去。
        # App 要顯示得出這個差別，不然使用者會以為自己剛剛換好了位址
        "config_written": wrote,
        "task_registered": task_ok,
    })


if __name__ == "__main__":
    main()
