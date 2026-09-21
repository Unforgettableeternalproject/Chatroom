"""Chatroom MCP Bridge 安裝器。

給測試者的一鍵安裝：建立獨立 venv、安裝 bridge、寫入 Claude Code 與
Codex CLI 的 MCP 設定。只用 Python 標準庫，Python 3.12+。

用法（互動）：
    install.bat          # 雙擊入口：找 Python 後跑下面這支
    python install.py

用法（非互動，全部參數給定）：
    python install.py --yes --url http://192.0.2.10:8787 --token <TOKEN> \
        --name 小明 --targets claude,codex

`--yes` 下**一個問題都不會問**（App 是以子進程跑這支的），而且 stdout 的
最後一行固定是 `RESULT {"ok":true,...}`——三包安裝器同一個格式。失敗時
退出碼非 0、原因走 stderr。

設計原則：
- **絕不寫入 CHATROOM_SESSION_KEY**——身分由各 agent 平台的 session 決定
  （Claude Code 用 CLAUDE_CODE_SESSION_ID；Codex 每 session 自動生成）。
  固定 key 會讓多個 session／多台機器合併成同一個聊天室身分。
- 冪等：重跑只更新，不重複追加；Codex 設定寫入前先備份，既有 chatroom 區塊
  移除後重寫（換機重裝時舊機器的路徑不能留著，見 setup_codex）。
- 除了 MCP 設定，另外寫一份 kit 根目錄 `.env` 給 watcher——它是獨立進程，
  讀不到 MCP client 傳給 bridge 的 env（見 write_env_file）。
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# 繁中 Windows 主控台預設 cp950，emoji/特殊字元會直接 UnicodeEncodeError
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

KIT_DIR = Path(__file__).resolve().parent

# 桌面 App 靠這份檔案知道「這台機器上接了 chatroom，接在哪、什麼時候接的」。
#
# ⚠️ **它是指路牌，不是設定。** URL 與 token 的真相在 kit 根目錄的 `.env`，
# bridge 版本的真相在 `_build.json`——那兩份都會被改，而改完不會有人回來
# 更新這裡。App 讀這份拿路徑與安裝時間，其餘一律現查。
REGISTRY = Path.home() / ".chatroom" / "mcp-kit.json"
VENV_DIR = KIT_DIR / "venv"
KIT_NAME = "mcp-kit"
# 打包時寫下的版本戳記（`install-kit/build.py` 的 stamp 目標）。原始碼樹裡
# 沒有這個檔案，那時版本就是未知——不要編一個出來
STAMP = KIT_DIR / "bridge" / "chatroom_mcp" / "_build.json"


def emit_result(payload: dict) -> None:
    """印出給呼叫端（桌面 App 以子進程跑這支）解析的單行結果。

    ⚠️ **三包安裝器的格式一致、而且永遠是 stdout 的最後一行**：
    `RESULT {"ok":true,...}`。App 只讀這一行，上面的人類文字它不解析——
    格式漂掉的話 App 會判成「裝失敗」，而安裝其實是成功的。
    """
    print("RESULT " + json.dumps(payload, ensure_ascii=False,
                                 separators=(",", ":")), flush=True)


def die(msg: str, **extra) -> "NoReturn":  # noqa: F821
    """錯誤走 **stderr**、結果行走 stdout、退出碼非 0。

    ⚠️ 走 stderr 是給以子進程呼叫的 App 用的：它拿 stdout 去解析 RESULT，
    失敗原因混在同一條流裡的話，人看得到、程式分不出來。
    """
    print(f"❌ {msg}", file=sys.stderr, flush=True)
    emit_result({"ok": False, "kit": KIT_NAME, "error": msg, **extra})
    raise SystemExit(1)


def build_info() -> dict[str, str]:
    """這一包的版本與 commit。讀不到就是空字串——「不知道」要看得出來。"""
    try:
        data = json.loads(STAMP.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"version": "", "commit": ""}
    if not isinstance(data, dict):
        return {"version": "", "commit": ""}
    return {"version": str(data.get("version") or ""),
            "commit": str(data.get("commit") or "")}


# 互動安裝共有幾步。印在每一步前面（`[2/4] …`）——雙擊進來的人需要知道
# 「還有多久」與「現在卡在哪一步」，尤其 pip 那一步會安靜好幾分鐘
TOTAL_STEPS = 4


def step(index: int, text: str) -> None:
    print(f"\n[{index}/{TOTAL_STEPS}] {text}", flush=True)


def ask(prompt: str, default: str = "", check=None) -> str:
    """互動提問：`問題 [預設值]: `，直接 Enter 用預設值。

    ⚠️ **不合法就重問，不要丟例外。** 這支現在是雙擊進來的——使用者看到
    一片 traceback 只會把視窗關掉，而他多半只是位址少打了 `http://`。

    EOF（stdin 是空管道）同樣不能炸：照預設值收場，讓安裝走完。
    """
    label = f"{prompt} [{default}]" if default else prompt
    while True:
        try:
            value = input(f"{label}: ").strip() or default
        except EOFError:
            print()
            return default
        problem = check(value) if check else ""
        if not problem:
            return value
        print(f"    ⚠️ {problem}")


def ask_yes_no(prompt: str, default: bool = True) -> bool:
    """是非題。看不懂的輸入重問一次，不要默默當成「否」。"""
    hint = "Y/n" if default else "y/N"
    while True:
        # 預設值寫在 (Y/n) 的大寫那一邊，不再另外掛一個 [Y]——同一件事
        # 講兩次只會讓人以為那是兩個欄位
        raw = ask(f"{prompt}（{hint}）").strip().lower()
        if not raw:
            return default
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("    ⚠️ 請輸入 y（要）或 n（不要）。")


def ask_required(prompt: str) -> str:
    """沒有預設值、而且不接受空白的那種問題。

    給的是「按 Enter 就錯」的那些欄位——空字串靜靜收下的話，安裝會一路
    成功，直到 agent 連不上才發現，而那時沒有人會想到是這一步。
    """
    while True:
        try:
            value = input(f"{prompt}: ").strip()
        except EOFError:
            die(f"{prompt}：沒有輸入（stdin 是空的）。"
                "非互動請改用 --yes 並把值當參數給。")
        if value:
            return value
        print("    ⚠️ 這一項沒有預設值，必須填。")


def check_url(value: str) -> str:
    """Hub 位址。**留空是合法的**（之後再填進 .env），打錯才要擋。"""
    if not value:
        return ""
    if not value.startswith(("http://", "https://")):
        return "位址要以 http:// 或 https:// 開頭，例如 http://192.0.2.10:8787。"
    if " " in value:
        return "位址裡不能有空白，確認一下是不是貼到了多餘的字。"
    return ""


def scripts_dir() -> Path:
    return VENV_DIR / ("Scripts" if sys.platform == "win32" else "bin")


# ---------- 步驟 ----------


def check_python() -> None:
    if sys.version_info < (3, 12):
        die(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")


# bridge 需要 agent 端具備的能力。少了它們，工具裝得起來但**通知永遠不會來**
# ——而那種失效是靜默的：指派送出了、Hub 也收下了，只是沒有人被叫醒。
#
# ⚠️ 兩邊的判斷方式刻意不同：
# * Codex 的 `queue` 是一個 CLI 子命令，可以直接問它在不在——**能力偵測**，
#   不受版本號格式或發佈節奏影響
# * Claude Code 的 Monitor 是模型端的工具，CLI 問不到，只能比版本號
#
# 而版本號這條路已經被實測打臉一次：公開資料說 Monitor 從 2.1.242 起才有，
# 但 2.1.238 的機器上它運作正常（2026-08-30 實測）。所以這裡的門檻取
# **實證可用的最低版本**，而且比不過時只警告不擋——擋掉一台其實能用的機器，
# 比放行一台不能用的更糟：後者至少會在第一次指派時就看出問題。
MIN_CLAUDE_VERSION = (2, 1, 238)


def _cli_version(exe: str) -> tuple[int, ...] | None:
    """問 CLI 自己的版本，回傳數字元組。問不到就 None。

    ⚠️ ``exe`` 要傳 **shutil.which 解析出來的完整路徑**，不要傳 "claude"
    這種名稱。同一台機器上可能裝了不只一份：這台用名稱叫到的是 2.1.92，
    用 which 的完整路徑叫到的是 2.1.238（2026-08-30 實測）。檢查錯的那份
    版本，結論當然也是錯的。
    """
    try:
        out = subprocess.run([exe, "--version"], capture_output=True, text=True,
                             timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out.stdout or out.stderr or "")
    return tuple(int(x) for x in m.groups()) if m else None


def check_agent_capabilities(targets: set[str]) -> None:
    """確認要設定的 agent 真的支援 bridge 依賴的能力。

    Codex 缺 `queue` 是**硬性阻擋**：App 的指派就是靠它送進 Codex session，
    沒有它整條路是斷的，而使用者不會收到任何錯誤。
    """
    claude_exe = shutil.which("claude")
    if "claude" in targets and claude_exe:
        ver = _cli_version(claude_exe)
        if ver is None:
            print("⚠️  問不到 Claude Code 版本——無法確認它支援 Monitor"
                  "（背景 watcher 靠它推送指派通知）。")
        elif ver < MIN_CLAUDE_VERSION:
            shown = ".".join(str(x) for x in ver)
            want = ".".join(str(x) for x in MIN_CLAUDE_VERSION)
            print(f"⚠️  Claude Code {shown} 比實證可用的 {want} 舊。"
                  "若 Monitor 工具不存在，背景 watcher 掛不起來，"
                  "指派與 @mention 都不會叫醒你（而且不會報錯）。"
                  "裝完後請掛一次 watcher 確認。")
    if "codex" in targets:
        exe = shutil.which("codex")
        if not exe:
            print("⚠️  找不到 codex，略過它的能力檢查。")
            return
        try:
            probe = subprocess.run([exe, "queue", "--help"],
                                   capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as exc:
            die(f"無法執行 codex：{exc}")
        if probe.returncode != 0:
            ver = _cli_version(exe)
            shown = ".".join(str(x) for x in ver) if ver else "未知版本"
            die(
                f"這個 Codex（{shown}）沒有 `codex queue` 子命令。\n"
                "  App 的指派就是靠 queue 把訊息送進既有的 Codex session，"
                "缺了它整條路是斷的——而且不會有任何錯誤訊息，"
                "指派會像是石沉大海。\n"
                "  `codex queue` 自 0.149.0 起提供，請先升級 Codex CLI"
                "（或用 --targets claude 只裝 Claude Code）。"
            )


def check_hub(url: str, token: str) -> bool:
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/rooms",
        headers={"Authorization": f"Bearer {token}"} if token else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        print(f"⚠️ Hub 回應 {e.code}（token 可能不對）")
    except OSError as e:
        print(f"⚠️ 連不上 Hub：{e}")
        print("   Hub 不在公網上時，要先連上主持人指定的網路"
              "（同區網、VPN、或他給的隧道網址）。")
    return False


PKG_NAME = "chatroom_mcp"


def site_packages(py: Path) -> Path | None:
    done = subprocess.run(
        [str(py), "-c",
         "import sysconfig;print(sysconfig.get_paths()['purelib'])"],
        capture_output=True, text=True,
    )
    if done.returncode != 0:
        return None
    path = Path(done.stdout.strip())
    return path if path.is_dir() else None


def restore_pip_leftovers(site: Path) -> list[str]:
    """把 pip 中斷時留下的 ``~`` 備份還原回去，回傳還原的項目名。

    pip 升級時先把舊目錄的第一個字元換成 ``~`` 當備份（``chatroom_mcp`` →
    ``~hatroom_mcp``），再解壓新版。中途失敗時它**不會回滾**，於是 venv 裡
    根本不存在 ``chatroom_mcp`` 這個模組。當下毫無症狀——bridge 進程早已把
    模組載入記憶體——直到下次重啟 agent 才炸 ``ModuleNotFoundError``，而那時
    沒人會把它跟幾天前那次失敗的安裝聯想在一起（2026-08-29 實機回報）。

    安裝失敗可以接受；讓失敗後的狀態比動手前更糟不行。
    """
    restored: list[str] = []
    for leftover in site.glob(f"~{PKG_NAME[1:]}*"):
        target = site / (PKG_NAME[0] + leftover.name[1:])
        if target.exists():
            shutil.rmtree(leftover, ignore_errors=True)  # 新版已就位，殘骸是垃圾
            continue
        leftover.rename(target)
        restored.append(target.name)
    return restored


def install_bridge() -> Path:
    """建立 venv 並安裝 bridge，回傳 chatroom-mcp 執行檔路徑。"""
    bridge_src = KIT_DIR / "bridge"
    if not (bridge_src / "pyproject.toml").is_file():
        die(f"找不到 bridge 原始碼（{bridge_src}）——請整包解壓後再執行")
    if not VENV_DIR.exists():
        print("• 建立虛擬環境…")
        subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], check=True)
    py = scripts_dir() / ("python.exe" if sys.platform == "win32" else "python")
    exe = scripts_dir() / (
        "chatroom-mcp.exe" if sys.platform == "win32" else "chatroom-mcp")
    print("• 安裝 bridge（含 mcp / httpx 相依，需要網路）…")
    done = subprocess.run(
        [str(py), "-m", "pip", "install", "--disable-pip-version-check",
         "-q", "--upgrade", str(bridge_src)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if done.returncode != 0:
        _report_install_failure(done, py, exe)
    if not exe.exists():
        die(f"安裝後找不到 {exe}")
    print(f"✅ bridge 安裝完成：{exe}")
    # 新環境驗過了（exe 在），這時才輪得到清舊的
    sweep_old_venvs()
    return exe


def _dir_size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def sweep_old_venvs(keep: int = 1) -> list[str]:
    """清掉更早幾輪升級留下的 ``venv.old-*``，保留最近 ``keep`` 份。

    **印出來比清掉重要。** 這些目錄各佔 70–80 MB，而升級流程從頭到尾沒有
    任何一步提到它們存在——實機上跑了五次升級才有人發現三份躺在那裡
    （2026-08-30 回報）。跟這個 kit 一路在修的東西同一個形狀：狀態產生了，
    但沒有任何觀測面會講到它。

    保留最近一份是刻意的：新版剛裝完就把唯一的退路刪光，升級失敗時連手動
    回滾都沒得回。只在新 venv 驗證通過後才呼叫。
    """
    olds = sorted((d for d in KIT_DIR.glob("venv.old-*") if d.is_dir()),
                  key=lambda d: d.name)
    doomed = olds[:-keep] if keep else olds
    if not doomed:
        return []
    removed: list[str] = []
    freed = 0
    for d in doomed:
        size = _dir_size(d)
        shutil.rmtree(d, ignore_errors=True)
        if d.exists():  # Windows：檔案被佔用時 rmtree 會安靜地失敗
            print(f"⚠️ 舊環境 {d.name} 清不掉（可能被程式佔用），請手動刪除")
            continue
        removed.append(d.name)
        freed += size
    if removed:
        print(f"• 已清理 {len(removed)} 份舊環境（{freed / 1024 / 1024:.0f} MB）："
              f"{'、'.join(removed)}")
    if keep and olds[-keep:]:
        print(f"  保留最近一份供回滾：{olds[-1].name}")
    return removed


def _report_install_failure(
    done: subprocess.CompletedProcess[str], py: Path, exe: Path
) -> "NoReturn":  # noqa: F821
    """pip 失敗：先把 venv 修回可用狀態，再說明真正的原因。"""
    output = f"{done.stdout}\n{done.stderr}".strip()
    site = site_packages(py)
    restored = restore_pip_leftovers(site) if site else []
    print(output)
    print()
    if restored:
        print(f"• 已還原 pip 中斷留下的殘骸：{'、'.join(restored)}")
        print("  （venv 回到安裝前的可用狀態，舊版 bridge 仍能運作）")
    # Windows 不給執行中 image 的 DELETE 權限，連改名都不行——升級的人幾乎
    #一定開著 agent，而 agent 正持有這支 exe，所以這是升級路徑的預設情境
    if "WinError 32" in output or "being used by another process" in output:
        die(f"{exe.name} 正被執行中的 agent 持有，pip 無法覆寫它。\n"
            "   請**完全關閉** Claude Code / Codex（含背景 watcher）後再重跑本安裝器。")
    die("pip 安裝失敗，原因見上方輸出。")


def mcp_env(kind: str, name: str) -> dict[str, str]:
    """MCP client 設定裡要放的環境變數。

    🔑 **連線資訊（URL／token）不寫在這裡**，只放一個指向 kit `.env` 的
    路徑（2026-09-12）。理由是那份設定不是唯一的一份：watcher 是獨立進程、
    拿不到 MCP client 的 env，所以 token 本來要寫兩個地方 ⇒ 換 token 得改
    兩處，而漏改一處的症狀是「看起來換好了、實際還在用舊的」。

    這也讓**安裝與連線分開**：還沒被邀請、或自己的 Hub 還沒架起來的人可以
    先把 bridge 裝好，之後把兩行填進那個檔就能用，不必重跑安裝器。

    kind 與 name 留在這裡是刻意的：它們是 per-agent 的**身分**，寫進共用檔
    就得在 claude 與 codex 之間二選一（見 ENV_FILE_HEADER）。
    """
    return {
        "CHATROOM_ENV_FILE": str(KIT_DIR / ".env"),
        "CHATROOM_AGENT_KIND": kind,
        "CHATROOM_DEFAULT_NAME": name,
    }


ENV_FILE_HEADER = """\
# 由 install.py 產生——**watcher 專用的連線資訊**。
#
# watch.py 是 Monitor／排程拉起的獨立進程，繼承的是 agent 主進程的環境，
# 拿不到 MCP client 設定裡的 env（那份只給 bridge 進程）。缺了這些值，
# watcher 會退回預設 Hub 位址，而且**不會報錯**——只是安靜地什麼通知
# 都不發。載入器是「真實環境變數優先、只補缺不覆寫」，所以這個檔對
# 已有 env 的 bridge 進程沒有任何影響。
#
# ⚠️ 這裡只放跨 agent 共用的連線資訊。**身分相關的值不要寫進來**：
#    - CHATROOM_AGENT_KIND：一份共用檔只能填一個 kind，另一種 agent 的
#      watcher 就會頂著錯誤身分跑。填 claude 時，同機的 Codex 備援
#      watcher（--codex-thread）會沿用 CLAUDE_CODE_SESSION_ID，直接與
#      母 Claude session 撞成同一個 participant。改用 watch.py --kind。
#    - CHATROOM_DEFAULT_NAME：同理，用 watch.py --label。
#    - CHATROOM_SESSION_KEY：身分由 session 決定，寫死會讓多個 session
#      合併成同一個聊天室身分。
#
# ⚠️ 內含 token，請勿提交版控或轉傳。
"""


def write_env_file(url: str, token: str) -> Path:
    """在 kit 根目錄寫一份 .env——**連線資訊的唯一真相**（只放 URL/TOKEN）。

    bridge 進程靠 MCP 設定裡的 `CHATROOM_ENV_FILE` 找到它，watcher 靠
    `watcher_command` 產的 `--env-file` 找到它。在這之前 token 得同時寫進
    MCP 設定與這個檔，換一次要改兩處，而漏改一處的症狀是「看起來換好了、
    實際還在用舊的」。

    ⚠️ 兩邊都是**顯式指定**，不要靠搜尋。這裡原本寫著「watcher 靠 cwd 找到
    它」——那句話只在 watcher 取 kit 的 `bridge/` 原始碼時成立，而
    `watcher_command` 刻意不走那條（見它的 docstring）。兩個設計決定互相
    抵銷，而失敗是靜默的。

    位置放在 kit 根目錄（bridge/ 的上一層）——那也是 envfile 候選清單裡
    「bridge 套件的 repo 根」的位置，走 fallback 路徑時剛好也搆得到。

    kind 與 name 刻意不寫：它們是 per-agent 的身分資訊，塞進共用檔就得在
    claude 與 codex 之間二選一，選哪個都會讓另一種 watcher 頂著錯誤身分跑
    （詳見 ENV_FILE_HEADER）。那兩個值由 watch.py 的 --kind / --label 給。
    """
    path = KIT_DIR / ".env"
    # 留空時仍然把兩行寫出來（空值）。**沒有那兩行的話，「之後自己填」是
    # 一句沒有著落的指示**——使用者得先猜到鍵叫什麼、該放哪個檔。
    # 空的鍵值對本身就是說明書。
    values = {"CHATROOM_URL": url, "CHATROOM_TOKEN": token}
    body = "".join(f"{k}={v}\n" for k, v in values.items())
    content = ENV_FILE_HEADER + body
    old = path.read_text(encoding="utf-8-sig") if path.is_file() else ""
    if old == content:
        print(f"• watcher 用 .env 已是最新：{path}")
        return path
    # 舊版把 kind 寫在這裡，是那些使用者當下唯一的 kind 來源。這次改寫會拿掉
    # 它——若他們沒同時把 --kind 補進 Monitor 指令，watcher 會立刻退化成隨機
    # 身分。只對真正受影響的人喊，避免變成人人略過的例行雜訊。
    stale = [k for k in ("CHATROOM_AGENT_KIND", "CHATROOM_DEFAULT_NAME")
             if any(line.startswith(f"{k}=") for line in old.splitlines())]
    if path.is_file():
        backup = path.with_name(f".env.bak-{datetime.now():%Y%m%d%H%M%S}")
        shutil.copy2(path, backup)
        print(f"• 已備份原 .env → {backup.name}")
    path.write_text(content, encoding="utf-8")
    if sys.platform != "win32":
        path.chmod(0o600)
    print(f"✅ watcher 用 .env 已寫入：{path}")
    if stale:
        print(f"⚠️ 舊 .env 帶著 {'、'.join(stale)}，已移除（身分改由指令列給）。")
        print("   **在重掛 watcher 前，先把 --kind claude|codex 加進 Monitor**")
        print("   **指令**——否則 watcher 會退回隨機身分，指派與 @mention 都")
        print("   收不到。確認新 watcher 的 session_key 正確後再收工。")
    return path


def setup_claude(exe: Path, name: str, mode: str) -> None:
    config = {"command": str(exe), "args": [],
              "env": mcp_env("claude", name)}
    payload = json.dumps(config, ensure_ascii=False)
    claude = shutil.which("claude")
    if mode == "auto" and claude:
        print("• 寫入 Claude Code 使用者層級 MCP 設定…")
        result = subprocess.run(
            [claude, "mcp", "remove", "chatroom", "--scope", "user"],
            capture_output=True, text=True)
        _ = result  # 不存在時 remove 會失敗，冪等重裝用，忽略
        done = subprocess.run(
            [claude, "mcp", "add-json", "chatroom", payload, "--scope", "user"],
            capture_output=True, text=True)
        if done.returncode == 0:
            print("✅ Claude Code 設定完成（所有專案可用）")
            return
        print(f"⚠️ claude mcp add-json 失敗：{done.stderr.strip()}")
    print("→ 請手動執行以下指令完成 Claude Code 設定：")
    print(f"  claude mcp add-json chatroom '{payload}' --scope user")


SKILL_TMPL = KIT_DIR / "skill" / "SKILL.md.tmpl"
SKILL_DIR = Path.home() / ".claude" / "skills" / "chatroom"


def watcher_command(py: Path, name: str) -> str:
    """產出**這台機器**掛 watcher 的實際指令。

    取 site-packages 裡那支 ``watch.py``，不是 kit 的 ``bridge/`` 原始碼：
    Windows 原地升級撞 ``WinError 32`` 之後兩份會不同版，而跑著的 bridge 是
    site-packages 那份（2026-08-29 實錄）。與 ``guide.watcher_setup()`` 推的
    是同一支，兩邊對得起來才有交叉驗證的價值。

    ``--kind`` / ``--label`` 走命令列而不是共用 ``.env``：一份 .env 只填得下
    一個 kind，另一種 agent 的 watcher 就會頂著錯身分跑（見 ENV_FILE_HEADER）。

    🚨 ``--env-file`` 也**必須**顯式給。取 site-packages 那支的代價是
    ``load_env_file`` 推出來的根變成 ``venv/Lib``——kit 根目錄不在它的候選
    清單裡，而 watcher 的 cwd 是使用者自己的專案。搜尋那條路在這個版面下
    永遠找不到，症狀是靜靜退回 ``DEFAULT_HUB_URL``（127.0.0.1:8787）：
    安裝全綠、watcher 掛得起來、指派掃描清單上就是看不到它。
    """
    site = site_packages(py)
    if site:
        script = site / "chatroom_mcp" / "watch.py"
    else:
        script = KIT_DIR / "bridge" / "chatroom_mcp" / "watch.py"
        print("⚠️ 找不到 site-packages，watcher 指令改指向 kit 的 bridge/ 原始碼"
              "（升級後這兩份可能不同版）")
    if not script.is_file():
        print(f"⚠️ watcher 腳本不在：{script}")
        print("   產出的指令會指向一個不存在的檔案——請確認 bridge 裝好了再重跑。")
    label = f' --label {name}' if name else ""
    env_file = KIT_DIR / ".env"
    return f'"{py}" "{script}" --env-file "{env_file}" --kind claude{label}'


def setup_skill(py: Path, name: str) -> None:
    """裝 Claude Code 的 chatroom skill（把掛 watcher 的路徑填成這台的）。

    為什麼 kit 要管這個：手冊（``chatroom_guide``）講的是「在房裡怎麼做事」，
    但 agent 得先**知道自己該去讀它**。skill 是 Claude Code 唯一會在對的時機
    自動載入的載體——沒有它，agent 只能從工具名稱猜，然後猜到 ``chatroom_watch``
    （那支是追蹤卡片的），而猜錯不會報錯。

    ⚠️ 樣板裡的路徑是佔位符，必須在這裡填。舊版這份 skill 是手寫的、帶著
    作者那台的開發樹路徑，複製到任何別台機器都是死的。
    """
    if not SKILL_TMPL.is_file():
        # 舊版 kit 沒有這個目錄。講出來——靜默跳過與「裝好了」長得一樣
        print(f"⚠️ 找不到 skill 樣板（{SKILL_TMPL}），略過 skill 安裝")
        print("   這包可能是舊版；agent 仍可用 chatroom_guide() 取得掛法")
        return
    content = SKILL_TMPL.read_text(encoding="utf-8").replace(
        "@@WATCHER@@", watcher_command(py, name))
    if "@@" in content:
        # assert 在 -O 下會被拿掉，而「沒填完的樣板」正是要擋的東西：
        # 寫出去的話 agent 會照著貼一個佔位符，然後得到「找不到檔案」
        die("skill 樣板有沒填掉的佔位符，中止以免寫出壞掉的 skill")
    target = SKILL_DIR / "SKILL.md"
    if target.is_file():
        if target.read_text(encoding="utf-8") == content:
            print("✅ Claude Code skill 已是最新（未變更）")
            return
        # 08/29 盲點一的教訓：遇到既有內容只警告不改、卻照樣印「完成」，
        # 結果是裝出一個壞環境而輸出看起來成功。備份後覆寫，並講出備份在哪
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        backup = target.with_name(f"SKILL.md.bak-{stamp}")
        backup.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"• 既有 skill 已備份 → {backup}")
    SKILL_DIR.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    print(f"✅ Claude Code skill 已安裝 → {target}")


CODEX_TABLE = "mcp_servers.chatroom"


def strip_codex_block(text: str) -> tuple[str, bool]:
    """移除既有的 ``[mcp_servers.chatroom]`` 及其子表，回傳 (剩餘內容, 是否移除)。

    只認裸寫的表頭（``[mcp_servers.chatroom]`` / ``[mcp_servers.chatroom.env]``）。
    引號形式（``[mcp_servers."chatroom"]``）不處理——TOML 合法但沒人手寫，
    為它引進一個 TOML parser 不划算；真遇到會在寫入後由 Codex 自己報重複表頭。
    """
    out: list[str] = []
    removed = False
    skipping = False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            table = stripped[1:-1].strip()
            if table == CODEX_TABLE or table.startswith(f"{CODEX_TABLE}."):
                skipping = True
                removed = True
                continue
            skipping = False
        if not skipping:
            out.append(line)
    return "".join(out), removed


def setup_codex(exe: Path, name: str, config_path: Path) -> None:
    block_lines = [
        "",
        f"[{CODEX_TABLE}]",
        f"command = '{exe}'",
        "args = []",
        "",
        f"[{CODEX_TABLE}.env]",
    ]
    for k, v in mcp_env("codex", name).items():
        # 🚨 TOML 的 basic string 會解跳脫序列，而現在這裡有 Windows 路徑
        # （`CHATROOM_ENV_FILE`）：`C:\Users\...` 裡的 `\U` 是合法的 Unicode
        # 跳脫開頭 ⇒ **整份 config.toml 變成無效 TOML**，Codex 連別人的 MCP
        # 設定一起讀不到。用 literal string（單引號，不解跳脫）。
        # command 那一行一直都是單引號，正是同一個理由。
        block_lines.append(f"{k} = '{v}'")
    block = "\n".join(block_lines) + "\n"

    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    # 舊行為是「偵測到既有區塊就只印警告」，但換機重裝正是本 kit 的主要情境：
    # 帳號同步過來的設定往往指向舊機器不存在的路徑，跳過就等於裝出一個壞環境，
    # 而主流程照樣印「完成」。改成比照 setup_claude 走 remove → add 的冪等路徑。
    remainder, removed = strip_codex_block(existing)
    if existing:
        backup = config_path.with_suffix(
            f".toml.bak-{datetime.now():%Y%m%d%H%M%S}")
        shutil.copy2(config_path, backup)
        print(f"• 已備份原設定 → {backup.name}")
    if removed:
        print("• 偵測到既有 chatroom 區塊（可能指向舊機器路徑）——移除後重寫")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    head = remainder.rstrip("\n")
    config_path.write_text(
        (head + "\n" if head else "") + block, encoding="utf-8")
    print(f"✅ Codex 設定完成：{config_path}")


# ---------- 主流程 ----------


def write_registry(targets: list[str]) -> dict:
    """寫下指路牌，讓桌面 App 認得這台機器上的 MCP 接入。

    **失敗不中止安裝**：沒有它只是 App 少一塊狀態顯示，agent 照樣連得上
    ——走到這裡時 MCP 設定與 .env 都已經寫好了，為了一個便利設施把整個
    安裝判成失敗，會讓人以為 bridge 沒裝好而重跑一遍。

    🔴 **`targets` 要與既有的合併，不能覆寫。**

    這台 kit 的既定流程就是**分兩次跑安裝器**——`--name` 一次只吃一個值，
    而 Claude 與 Codex 的房內代稱往往不同。覆寫的話第二次會把第一次的洗掉，
    於是 App 顯示「只裝了 codex」而實際上兩端都在
    （測試Novia 09/09 房 seq 186 實測撞到，那不是邊緣案例是既定流程）。

    使用者看到那個之後合理的反應是再跑一次安裝器，然後把另一端的代稱洗掉
    ——**一個顯示錯誤誘導出一個真實的破壞**。

    ⚠️ 合併的前提是**同一包**：`kit_root` 不同表示他把 kit 解到別的位置重裝，
    那時舊的 targets 可能指向已經不存在的設定，整份取代才對。

    每個 target 另外記自己的安裝時間——「哪一端比較舊」比「整包什麼時候裝的」
    有用得多，尤其在分兩次裝的機器上。

    ⚠️ **時間欄位是有用途的，不是裝飾。** Claude Code / Codex 若在安裝之前
    就開著，它連的是舊的 bridge 進程——設定檔更新了，跑著的那個沒有。
    那個落差安裝器看得見、使用者看不見（2026-09-09 實際踩過：舊 bridge 沒有
    `card_refs` 參數，發文被 Hub 擋下，而錯誤訊息指向他手上沒有的東西）。

    ⚠️ 但**不要拿這個時間去要求使用者比較**——他不知道自己的 agent 是什麼
    時候開的（Claude Code 與 Codex 都沒有顯示啟動時間）。它的用途是**診斷**
    （出事時看「哪一端比較舊」），不是給使用者的判準。
    """
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    merged = sorted(targets)
    per_target = {t: now for t in targets}

    old = {}
    try:
        if REGISTRY.is_file():
            loaded = json.loads(REGISTRY.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                old = loaded
    except (OSError, ValueError):
        # 讀不懂就當沒有——一份壞掉的舊檔不該擋住寫入新的
        old = {}

    if old.get("kit_root") == str(KIT_DIR):
        previous = [str(t) for t in (old.get("targets") or [])]
        merged = sorted(set(previous) | set(targets))
        stamps = old.get("target_installed_at")
        if isinstance(stamps, dict):
            # 這次沒裝的那些保留原本的時間，別假裝它們剛剛被更新過
            for key, value in stamps.items():
                per_target.setdefault(str(key), str(value))
        # ⚠️ **舊格式（沒有 target_installed_at）留下的 target 就是沒有時間，
        # 不要替它補一個。** 那筆是上一版安裝器裝的，它的時間從來沒被記過
        # ——填今天的等於宣稱它剛剛被更新，填舊的 installed_at 等於宣稱那是
        # 它的安裝時刻，兩個都是編出來的。
        #
        # 顯示「不明」是誠實的，顯示一個錯的時間會讓人拿它去判斷「哪一端
        # 比較舊」而得到相反的結論（測試Novia 09/09 房 seq 204 指出這一點
        # 時，它還只是 setdefault 的副作用；現在它是刻意的）。

    info = build_info()
    payload = {
        # ⚠️ `version` 是**這份登錄檔的格式版本**，不是 kit 的版本。
        # kit 的版本在 `kit_version`／`commit`
        "version": 1,
        "kit_root": str(KIT_DIR),
        "env_file": str(KIT_DIR / ".env"),
        "installed_at": now,
        "kit_version": info["version"],
        "commit": info["commit"],
        "targets": merged,
        "target_installed_at": per_target,
    }
    try:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        # 先寫暫存再換名：中途失敗留下的是舊的那份，不是半個 JSON。
        # 一個解析不了的指路牌會讓 App 每次都當成「壞了」而不是「沒有」
        tmp = REGISTRY.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        tmp.replace(REGISTRY)
        print(f"✅ 註冊檔已寫入：{REGISTRY}（targets: {'、'.join(merged)}）")
    except OSError as exc:
        print(f"⚠️ 註冊檔寫不進去（{exc}）——桌面 App 會看不到這包，"
              f"但 agent 的連線不受影響。")
    return payload


def main() -> None:
    p = argparse.ArgumentParser(description="Chatroom MCP Bridge 安裝器")
    p.add_argument("--url", help="Hub 位址，例 http://192.0.2.10:8787")
    p.add_argument("--token", help="API token（主持人提供）")
    p.add_argument("--name", help="你在聊天室的預設代稱")
    p.add_argument("--targets", help="要設定的 agent：claude,codex（預設兩者）")
    p.add_argument("--claude", choices=["auto", "manual"], default="auto",
                   help="auto=直接寫入設定；manual=只印出指令")
    p.add_argument("--codex-config", type=Path,
                   default=Path.home() / ".codex" / "config.toml",
                   help="Codex 設定檔位置（測試用）")
    p.add_argument(
        "--yes", action="store_true",
        help="不互動：沒給的值一律留空（之後填進 kit 的 .env），"
             "Hub 連線測試失敗也不停下來問",
    )
    p.add_argument("--verbose", action="store_true",
                   help="失敗時印出完整技術細節（traceback）")
    args = p.parse_args()

    # 🔴 **`--yes` 下這支不可以問任何問題。**
    #
    # App 是以子進程跑它的：`input()` 讀到的是一個沒有人在打字的管道，
    # 安裝會就地停住或拿到 EOF，而 App 那邊只看得到「沒有輸出、沒有結束」。
    # 所以下面每一處 `ask()` 都必須先過這個閘。
    def prompt(question: str, default: str = "", check=None) -> str:
        return default if args.yes else ask(question, default, check)

    check_python()
    info = build_info()
    where = f"版本 {info['version']}（commit {info['commit']}）" if info["version"] \
        else "版本未知（從原始碼樹執行）"
    print(f"=== Chatroom MCP Bridge 安裝 ===\n{where}\n")

    env_file = KIT_DIR / ".env"
    if not args.yes:
        # 先講「這次會做什麼」。雙擊進來的人下一步就要回答問題了，
        # 在那之前他有權知道這支程式打算動哪些東西
        print(f"""這一包讓你的 Claude Code / Codex 連得上聊天室（多出一批 chatroom_* 工具）。

接下來會做 {TOTAL_STEPS} 件事：
  [1/{TOTAL_STEPS}] 問你要連哪台 Hub、用什麼代稱（都可以留空，之後再填）
  [2/{TOTAL_STEPS}] 在這個資料夾裡建獨立 Python 環境並裝上 bridge
  [3/{TOTAL_STEPS}] 寫進 Claude Code／Codex 的 MCP 設定
  [4/{TOTAL_STEPS}] 寫下連線設定與註冊檔

沒有把握的問題就直接按 Enter。
""")
        # 既有安裝先講明白，再問——不然使用者會以為自己要從頭再來一次
        for label, path in (("連線設定", env_file), ("註冊檔", REGISTRY),
                            ("Codex 設定", args.codex_config)):
            if path.exists():
                print(f"偵測到既有安裝：{path}（{label}），將沿用／就地更新")
        if env_file.exists() or REGISTRY.exists():
            print()

    step(1, "確認要連哪台 Hub…")

    # 🔴 **這裡不可以有預設值。**
    #
    # 原本填的是開發機的內網位址——交付給外部人之後，按 Enter 的人
    # 會拿到一個他連不上的位址；而**更糟的是他剛好也在那個 VPN 裡**，
    # 那時他會安安靜靜地連到別人的 Hub。
    #
    # 「按 Enter 就錯」是最容易踩的一種預設值，所以這一題強制要回答。
    # 可以留空——**安裝 bridge 與決定要連哪台 Hub 是兩件事**（艾斯維爾
    # 2026-09-12）：還沒被邀請、或自己的 Hub 還沒架起來的人，先把 bridge
    # 裝好是合理的。留空時連線資訊之後填進 kit 的 `.env` 就生效，不必重裝。
    #
    # 🔴 但**仍然沒有預設值**。原本填的是開發機的內網位址——交付出去之後，
    # 按 Enter 的人會拿到一個他連不上的位址；而更糟的是他剛好也在那個 VPN
    # 裡，那時他會安安靜靜地連到別人的 Hub。「按 Enter 就錯」與「按 Enter
    # 就先跳過」是兩回事，這裡要的是後者。
    url = (args.url or prompt(
        "Hub 位址（主持人給你的，例 http://192.0.2.10:8787；可留空，之後再填）",
        check=check_url,
    )).rstrip("/")
    # 🔑 **主持人手上有兩把，agent 要的是 agent 那把。**
    #
    # 憑證分離之後 Hub 有 CHATROOM_TOKEN（agent）與 CHATROOM_HUMAN_TOKEN（人）。
    # 這包裝的是 agent 的 bridge，拿到人類那把等於把主持人的權力交給 agent；
    # 而拿錯的症狀不是「裝不起來」，是**裝好了、權限卻不對**。
    token = args.token if args.token is not None else prompt(
        "Agent token（主持人給你的那把 agent 憑證；可留空，之後再填）")
    # 預設值刻意留空：所有按 Enter 的人都叫同一個名字的話，房內會出現
    # 一串 Tester / Tester-2 / Tester-3，而名字是用來認人的
    name = args.name or prompt("你在聊天室的代稱（可留空，由 Hub 發一個）")
    targets = {
        t.strip() for t in (args.targets or "claude,codex").split(",") if t.strip()
    }
    unknown = targets - {"claude", "codex"}
    if unknown:
        die(f"未知的 target：{', '.join(sorted(unknown))}")
    # 在動任何檔案之前檢查：裝到一半才發現環境不支援，使用者要自己收拾殘骸
    check_agent_capabilities(targets)

    print()
    if not url:
        # 沒有位址就沒有「連得上」這回事。硬測一次只會印出一個看起來像
        # 故障的失敗，而使用者什麼都還沒做錯
        print("• 尚未指定 Hub，略過連線測試")
    else:
        print("• 測試 Hub 連線…")
        if check_hub(url, token):
            print("✅ Hub 連線正常")
        elif args.yes:
            # 連不上不等於裝不起來（Hub 沒開、還沒進 VPN 都算）。非互動時
            # 照裝並把話說明白，不要停在一個沒有人回答得了的問題上
            print("⚠️ Hub 連線失敗——仍繼續安裝（--yes）。"
                  "連線資訊之後改 kit 的 .env 即可，不必重裝。")
        elif not ask_yes_no("Hub 連線失敗，仍要繼續安裝嗎？", False):
            print("❌ 已中止安裝（Hub 連線失敗）", file=sys.stderr, flush=True)
            emit_result({"ok": False, "kit": KIT_NAME,
                         "error": "Hub 連線失敗，使用者選擇中止"})
            raise SystemExit(1)

    step(2, "建立獨立的 Python 環境並安裝 bridge…")
    exe = install_bridge()
    print()
    step(3, "寫入 Claude Code／Codex 的 MCP 設定…")
    if "claude" in targets:
        setup_claude(exe, name, args.claude)
        # skill 是 Claude Code 專屬機制，Codex 讀不到——所以手冊仍然
        # 留在 chatroom_guide（見 guide.py 開頭的理由），這裡是加強不是取代
        setup_skill(scripts_dir() / ("python.exe" if sys.platform == "win32"
                                    else "python"), name)
    if "codex" in targets:
        setup_codex(exe, name, args.codex_config)

    print()
    # 連線資訊的唯一真相：bridge 靠 CHATROOM_ENV_FILE 找到它，watcher
    # （Monitor 拉起的獨立進程，拿不到 MCP 設定裡的 env）靠 cwd 找到它。
    # 兩種 target 都需要：Codex 的 --codex-thread 備援模式同樣是獨立進程。
    step(4, "寫下連線設定與註冊檔…")
    env_path = write_env_file(url, token)

    registry = write_registry(targets)

    print("\n=== 安裝完成 ===")
    if not url or not token:
        # 裝好了但還連不上，而那是**使用者自己選的**。講清楚缺什麼、填哪裡，
        # 否則他下次想用的時候只會看到 401／連不上，然後回來重裝一次
        missing = "、".join(
            n for n, v in (("Hub 位址", url), ("agent token", token)) if not v)
        print(f"⚠️ 還缺 {missing}——bridge 已經裝好，但現在還連不上任何 Hub。")
        print(f"   拿到之後把這兩行填進：{env_path}")
        print("     CHATROOM_URL=http://主持人給你的位址:8787")
        print("     CHATROOM_TOKEN=主持人給你的那把 agent 憑證")
        print("   填完讓 agent 重連（或重啟 Claude Code / Codex）即可，"
              "不必重跑這支安裝器。")
        print()
    print("接下來做什麼：")
    print("  1. **完全關掉**正在跑的 Claude Code / Codex，再重新開啟")
    print("     （MCP 設定是啟動時讀的，不重開就看不到新工具）")
    print("  2. 重開後問它「有哪些 chatroom 工具？」，看得到 chatroom_* 就成功了")
    print("  3. 第一次使用前先讓它讀 chatroom_guide，那是聊天室的操作手冊")
    print("⚠️ 請勿自行設定 CHATROOM_SESSION_KEY——身分由 session 自動決定，")
    print("   固定 key 會讓多個 session 合併成同一個聊天室身分。")
    print("通知用法見 kit 內 README。")

    # ⚠️ 這一行要是 stdout 的最後一行：App 解析它來判斷裝到哪、版本是什麼
    emit_result({
        "ok": True,
        "kit": KIT_NAME,
        "registry": str(REGISTRY),
        "kit_root": str(KIT_DIR),
        "env_file": str(env_path),
        "version": registry["kit_version"],
        "commit": registry["commit"],
        "installed_at": registry["installed_at"],
        "targets": registry["targets"],
        # 這兩個缺任何一個都是「裝好了但連不上」，App 要顯示得出來
        "url": url,
        "has_token": bool(token),
    })


def run() -> None:
    """把沒接到的例外翻成一句中文 + 下一步。

    ⚠️ 這支現在是**雙擊**進來的：一片 traceback 對雙擊的人等於沒有訊息，
    他會直接關掉視窗，而問題本身多半只是「網路連不到 PyPI」。
    要技術細節的人可以加 `--verbose`，那時原樣拋出去。
    """
    try:
        main()
    except SystemExit:
        raise
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr, flush=True)
        emit_result({"ok": False, "kit": KIT_NAME, "error": "使用者取消"})
        raise SystemExit(130)
    except Exception as exc:
        if "--verbose" in sys.argv:
            raise
        die(f"安裝中止：{type(exc).__name__}: {exc}\n"
            f"   常見原因：網路連不到 PyPI、或這個資料夾沒有寫入權限。\n"
            f"   要看完整技術細節請加上 --verbose。")


if __name__ == "__main__":
    run()
