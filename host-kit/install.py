"""Chatroom Hub 安裝器（host 端）。

    install.bat                       # 雙擊入口：找 Python 後跑下面這支
    python install.py                 # 互動式：host / port / token
    python install.py --yes           # 全用預設值（token 自動生成）
    python install.py --yes --no-tunnel --register-service   # 桌面 App 走的路

`--yes` 下**一個問題都不會問**（App 是以子進程跑這支的），而且 stdout 的
最後一行固定是 `RESULT {"ok":true,...}`——三包安裝器同一個格式，App 解析
那一行判斷裝到哪、裝的是哪一份程式碼。失敗時退出碼非 0、原因走 stderr。

做五件事：
1. 在包內建立獨立 venv 並安裝 Hub 相依（不污染系統 Python）
2. 產生 server/.env（host / port / token；token 預設自動生成高熵值）
3. 要對外協作的話，順手把 cloudflared 抓下來備妥（之後開隧道就是一鍵）
4. 寫下註冊檔 ~/.chatroom/host-kit.json，讓桌面 App 找得到這包
5. 印出啟動方式與要發給成員的連線資訊

之後：前景試跑用 scripts\\run-hub.cmd；要開機/登入自啟用
`pwsh -File scripts/hub-service.ps1 install`；要讓內網外的 agent 連進來用
scripts\\run-tunnel.cmd（詳見 README）。
"""

from __future__ import annotations

import argparse
import json
import secrets
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    # 繁中 Windows 主控台預設 cp950。stderr 也要設——中止訊息走那裡，
    # 不設的話「為什麼失敗」會變成一串亂碼，而那正是最需要讀懂的一句
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

KIT = Path(__file__).resolve().parent
KIT_NAME = "host-kit"
VENV = KIT / ".venv"
ENV_FILE = KIT / "server" / ".env"
# 打包時寫下的版本戳記（`host-kit/build.py` 的 stamp 目標）。原始碼樹裡
# 沒有這個檔案，那時版本就是未知——不要編一個出來
STAMP = KIT / "server" / "chatroom_server" / "_build.json"
DEPS = ["fastapi", "uvicorn[standard]", "aiosqlite", "python-multipart"]

# 桌面 App 靠這份檔案知道「這台機器上有一包 Hub，它在哪裡」。
#
# ⚠️ **它只是一個指路牌，不是設定檔。** 真相仍在 server/.env 與實際跑著的
# 進程裡——App 讀這裡拿到路徑，其餘一律現查。寫成第二份設定的話，兩邊
# 遲早不一樣，而使用者會看到一個講得很篤定卻是錯的畫面。
REGISTRY = Path.home() / ".chatroom" / "host-kit.json"


def emit_result(payload: dict) -> None:
    """印出給呼叫端（桌面 App 以子進程跑這支）解析的單行結果。

    ⚠️ **三包安裝器的格式一致、而且永遠是 stdout 的最後一行**：
    `RESULT {"ok":true,...}`。App 只讀這一行，上面的人類文字它不解析——
    格式漂掉的話 App 會判成「裝失敗」，而安裝其實是成功的。
    """
    print("RESULT " + json.dumps(payload, ensure_ascii=False,
                                 separators=(",", ":")), flush=True)


def die(msg: str, **extra) -> "NoReturn":  # noqa: F821
    """錯誤走 stderr、結果行走 stdout、退出碼非 0。

    三者缺一不可：App 靠退出碼判成敗、靠 stderr 顯示原因、靠結果行拿細節。
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


# 互動安裝共有幾步。印在每一步前面（`[2/5] …`）——雙擊進來的人需要知道
# 「還有多久」與「現在卡在哪一步」，尤其 pip 那一步會安靜好幾分鐘
TOTAL_STEPS = 5


def step(index: int, text: str) -> None:
    print(f"\n[{index}/{TOTAL_STEPS}] {text}", flush=True)


def ask(question: str, default: str = "", check=None) -> str:
    """互動提問：`問題 [預設值]: `，直接 Enter 用預設值。

    ⚠️ **不合法就重問，不要丟例外。** 這支現在是雙擊進來的——使用者看到
    一片 traceback 只會把視窗關掉，而他多半只是埠號打錯一個字。

    EOF（stdin 是空管道）同樣不能炸：照預設值收場，讓安裝走完。
    """
    label = f"{question} [{default}]" if default else question
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


def ask_yes_no(question: str, default: bool = True) -> bool:
    """是非題。看不懂的輸入重問一次，不要默默當成「否」。"""
    hint = "Y/n" if default else "y/N"
    while True:
        # 預設值寫在 (Y/n) 的大寫那一邊，不再另外掛一個 [Y]——同一件事
        # 講兩次只會讓人以為那是兩個欄位
        raw = ask(f"{question}（{hint}）").strip().lower()
        if not raw:
            return default
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("    ⚠️ 請輸入 y（要）或 n（不要）。")


def check_host(value: str) -> str:
    if not value:
        return "不能留空。不確定就填 0.0.0.0（所有網路介面）。"
    if " " in value:
        return "位址裡不能有空白。"
    return ""


def check_port(value: str) -> str:
    if not value.isdigit() or not 1 <= int(value) <= 65535:
        return "埠號要是 1～65535 的數字，例如 8787。"
    return ""


def check_token(value: str) -> str:
    if len(value) < 8:
        return "token 太短（至少 8 個字元）。直接 Enter 可以用上面那個預設值。"
    return ""


def venv_python() -> Path:
    sub = "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
    return VENV / sub


def ensure_venv() -> None:
    if not venv_python().exists():
        print("  建立 venv…", flush=True)
        subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    else:
        print(f"  沿用既有的 venv：{VENV}", flush=True)
    print("  安裝相依套件（第一次會下載，請等幾分鐘）…", flush=True)
    subprocess.run(
        [str(venv_python()), "-m", "pip", "install", "--quiet", *DEPS], check=True
    )


def read_env() -> dict[str, str]:
    """現有的 `.env`。不存在就是空的。

    解析規則與 server 端 `config.py`、`scripts/backup.py` 一致：忽略空行與
    `#` 開頭，只切第一個 `=`（token 是 urlsafe base64，值裡可能還有 `=`）。
    """
    values: dict[str, str] = {}
    if not ENV_FILE.exists():
        return values
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        at = text.find("=")
        if at <= 0:
            continue
        values[text[:at].strip()] = text[at + 1:].strip()
    return values


def update_env(updates: dict[str, str]) -> None:
    """**只改指定的那幾個鍵，其餘原樣保留。**

    🔴 這裡原本是整份覆寫（只寫 HOST/PORT/TOKEN 三行）。後果是主持人自己
    加進 `.env` 的任何設定——`CHATROOM_PURGE_ARCHIVED_DAYS`、
    `CHATROOM_IDLE_TIMEOUT`、附件目錄——**重跑一次安裝器就全部消失**，
    而安裝器從頭到尾顯示成功。

    它咬人的時機特別惡劣：重跑安裝器多半是因為「有什麼壞了想重裝看看」，
    那時被清掉的設定正是可能與問題有關的那些。

    註解與排列順序都保留：`.env` 是人會去讀、去改的檔案，把它重排一次
    等於把使用者寫給自己的說明洗掉。
    """
    remaining = dict(updates)
    out: list[str] = []

    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines(keepends=True):
            stripped = line.strip()
            newline = "\n" if line.endswith("\n") else ""
            key = ""
            if stripped and not stripped.startswith("#"):
                at = stripped.find("=")
                if at > 0:
                    key = stripped[:at].strip()
            if key and key in remaining:
                out.append(f"{key}={remaining.pop(key)}{newline}")
            else:
                out.append(line)

    # 原本沒有的鍵補在檔尾。⚠️ 前一行沒有換行時要先補一個，否則兩個設定
    # 會黏成 `CHATROOM_PORT=8787CHATROOM_TOKEN=...`——兩個同時失效，
    # 而檔案看起來還是有內容的
    if remaining:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        for key, value in remaining.items():
            out.append(f"{key}={value}\n")

    # 寫暫存檔再換上：直接 open(..,"w") 在寫到一半失敗時留下 0 位元組的
    # `.env`，那時 Hub 起不來，而本來只是想重裝
    tmp = ENV_FILE.with_name(ENV_FILE.name + ".tmp")
    tmp.write_text("".join(out), encoding="utf-8")
    tmp.replace(ENV_FILE)
    print(f"  已寫入 {ENV_FILE}")


def prepare_tunnel() -> bool:
    """把 cloudflared 先抓下來，讓之後開隧道不必等下載。失敗不中斷安裝。"""
    script = KIT / "scripts" / "tunnel.py"
    if not script.exists():
        print("⚠️ 找不到 scripts/tunnel.py，略過隧道準備")
        return False
    print("  準備隧道工具（cloudflared，約 40 MB）…", flush=True)
    done = subprocess.run(
        [str(venv_python()), str(script), "--check", "--i-know-its-public"]
    )
    if done.returncode != 0:
        # 下載失敗不該讓整個安裝白跑——Hub 本身已經可用，隧道之後補即可
        print("⚠️ 隧道工具準備失敗，之後可單獨執行 scripts\\run-tunnel.cmd 重試")
        return False
    return True


def write_registry(host: str, port: str) -> dict:
    """寫下指路牌，讓桌面 App 認得這台機器上的 Hub。

    **失敗不中止安裝**：沒有它只是 App 少一個分頁，Hub 本身照跑——
    而 `install.py` 走到這裡時伺服器已經可以用了，為了一個便利設施把整個
    安裝判成失敗，會讓人以為 Hub 沒裝好。
    """
    info = build_info()
    payload = {
        # ⚠️ `version` 是**這份登錄檔的格式版本**，不是 kit 的版本。
        # kit 的版本在 `kit_version`／`commit`——兩者混用過一次就再也分不開
        "version": 1,
        # App 需要的是**這一包在哪**，其餘（token、實際 host/port）它自己去
        # 讀 server/.env——那份會被人手改，而改完不會有人回來更新這裡
        "kit_root": str(KIT),
        "env_file": str(ENV_FILE),
        "installed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        # 裝的是哪一份程式碼。原始碼樹裡跑安裝器時是空字串（沒有 _build.json）
        "kit_version": info["version"],
        "commit": info["commit"],
        # 只是給人看的線索，App 不可以拿它當現況——Hub 可能根本沒在跑
        "installed_host": host,
        "installed_port": port,
    }
    try:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        # 先寫暫存再換名：中途失敗時留下的是舊的那份，不是半個 JSON。
        # 一個解析不了的指路牌會讓 App 每次啟動都當成「壞了」而不是「沒有」
        tmp = REGISTRY.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        tmp.replace(REGISTRY)
    except OSError as exc:
        print(f"⚠️ 註冊檔寫不進去（{exc}）——桌面 App 會找不到這包 Hub，"
              f"但 Hub 本身不受影響。手動建立：{REGISTRY}")
    return payload


def register_service() -> bool:
    """呼叫 `scripts/hub-service.ps1 install` 註冊登入／開機自啟。

    腳本本身是無人值守的：非提權時走 AtLogOn + Interactive 分支，
    `Register-ScheduledTask -Force` 不問任何問題。提權與否只影響觸發器
    （AtStartup/S4U vs AtLogOn），兩條路都不會停在提示上。

    **失敗不中止安裝**：Hub 本體已經可用，手跑一次腳本就補得回來。
    """
    script = KIT / "scripts" / "hub-service.ps1"
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not script.exists() or shell is None:
        print(f"⚠️ 找不到 {script} 或 PowerShell——沒有註冊自啟工作")
        return False
    print("  註冊排程工作「ChatroomHub」…", flush=True)
    done = subprocess.run([shell, "-NoProfile", "-File", str(script),
                           "install"])
    if done.returncode != 0:
        print(f"⚠️ 自啟工作註冊失敗（退出碼 {done.returncode}）。"
              f"可之後手動執行：pwsh -File {script} install")
        return False
    return True


def main() -> None:
    p = argparse.ArgumentParser(description="Chatroom Hub 安裝器")
    p.add_argument("--host", help="綁定位址（0.0.0.0 = 所有介面；建議填 VPN 介面 IP）")
    p.add_argument("--port", help="埠號，預設 8787")
    p.add_argument("--token", help="API token；省略時自動生成")
    p.add_argument(
        "--tunnel", action=argparse.BooleanOptionalAction, default=None,
        help="是否備妥公網隧道工具（--no-tunnel 明確跳過）；省略時互動詢問",
    )
    p.add_argument(
        "--register-service", action="store_true",
        help="順便註冊登入／開機自啟的排程工作（等同 "
             "scripts/hub-service.ps1 install）；預設不註冊",
    )
    p.add_argument("--yes", action="store_true", help="不互動，全用預設/參數值")
    p.add_argument("--verbose", action="store_true",
                   help="失敗時印出完整技術細節（traceback）")
    args = p.parse_args()

    if sys.version_info < (3, 12):
        die(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")

    info = build_info()
    where = f"版本 {info['version']}（commit {info['commit']}）" if info["version"] \
        else "版本未知（從原始碼樹執行）"
    print(f"=== Chatroom Hub 安裝 ===\n{where}\n")
    if not args.yes:
        # 先講「這次會做什麼」。雙擊進來的人下一步就要回答問題了，
        # 在那之前他有權知道這支程式打算動哪些東西
        print(f"""這一包是聊天室的**主機**（Hub），裝完這台電腦就是大家連進來的地方。

接下來會做 {TOTAL_STEPS} 件事：
  [1/{TOTAL_STEPS}] 在這個資料夾裡建一個獨立的 Python 環境，裝 Hub 要用的套件
  [2/{TOTAL_STEPS}] 寫設定檔 server/.env（綁定位址、埠號、兩把 token）
  [3/{TOTAL_STEPS}] 寫註冊檔，讓桌面 App 找得到這包
  [4/{TOTAL_STEPS}] 視你的選擇備妥公網隧道工具／註冊開機自啟
  [5/{TOTAL_STEPS}] 印出啟動方式與要發給成員的連線資訊

沒有把握的問題就直接按 Enter，用中括號裡的預設值。
""")

    # 🔴 **既有的值優先於新生成的。**
    #
    # 原本每次重跑都產一把新 token 當預設——而重跑安裝器是很常見的動作
    # （升級、修東西、換設定）。照著按 Enter 就換掉了 token，**當場踢掉
    # 所有成員與 agent**，而畫面上完全看不出剛剛發生了這件事。
    #
    # 要換 token 有專門的工具（`scripts/rotate-token.py`），它會備份舊值、
    # 並講明每個人都要重拿。那才是換 token 該走的路。
    existing = read_env()
    default_token = existing.get("CHATROOM_TOKEN") or secrets.token_urlsafe(24)
    default_host = existing.get("CHATROOM_HOST") or "0.0.0.0"
    default_port = existing.get("CHATROOM_PORT") or "8787"
    reusing_token = bool(existing.get("CHATROOM_TOKEN"))

    if args.yes:
        host = args.host or default_host
        port = args.port or default_port
        token = args.token or default_token
    else:
        if existing:
            print(f"偵測到既有安裝：{ENV_FILE}")
            print("  這次會沿用裡面的設定，沒有動到的一行都原樣保留。\n")
        if REGISTRY.exists():
            print(f"偵測到既有註冊檔：{REGISTRY}（會更新成這一包的路徑）\n")
        host = args.host or ask("綁定位址（VPN 介面 IP，或 0.0.0.0 = 全部）",
                                default_host, check_host)
        port = args.port or ask("埠號", default_port, check_port)
        token = args.token or ask(
            "Agent token" + ("（Enter 沿用現有的）" if reusing_token
                             else "（Enter 用自動生成值）"),
            default_token, check_token)

    if args.tunnel is not None:
        want_tunnel = args.tunnel
    elif args.yes:
        want_tunnel = True
    else:
        want_tunnel = ask_yes_no(
            "要讓內網以外的 agent 也能連進來嗎？（會下載 cloudflared，約 40 MB）",
            True)

    # 🔑 **人類主持人自己的鑰匙。**
    #
    # 沒有這一把的 Hub 是 `credential_mode: legacy`——整套憑證分離做好了
    # 卻沒有啟用，因為安裝器從來沒產生過它。那等於它只對「知道有這個環境
    # 變數的人」存在，而交付給外部人的包裡它不存在。
    #
    # 既有的優先：升級時補上新的那把，不動已經在用的那把。
    human_token = existing.get("CHATROOM_HUMAN_TOKEN") or secrets.token_urlsafe(24)
    newly_split = not existing.get("CHATROOM_HUMAN_TOKEN")

    # venv 或 `.env` 寫不成就是真的失敗（Hub 起不來）。讓它變成一句話 +
    # 非 0 退出碼，而不是一坨 traceback——呼叫端要讀得懂
    try:
        step(1, "建立獨立的 Python 環境並安裝相依套件…")
        ensure_venv()
        step(2, "寫入設定檔 server/.env…")
        update_env({
            "CHATROOM_HOST": host,
            "CHATROOM_PORT": port,
            "CHATROOM_TOKEN": token,
            "CHATROOM_HUMAN_TOKEN": human_token,
        })
    except (OSError, subprocess.SubprocessError) as exc:
        # 中文原因 + 下一步，不是 traceback（要細節的話 --verbose）
        die(f"安裝失敗：{exc}\n"
            f"   常見原因：網路連不到 PyPI、或這個資料夾沒有寫入權限。\n"
            f"   確認網路後重跑一次即可；要看完整技術細節請加上 --verbose。")
    step(3, "寫入註冊檔（讓桌面 App 找得到這包）…")
    registry = write_registry(host, port)
    step(4, "備妥選用元件（開機自啟／公網隧道）…")
    if not args.register_service and not want_tunnel:
        print("  這次兩項都不做。")
    service_ok = register_service() if args.register_service else False
    tunnel_ready = prepare_tunnel() if want_tunnel else False
    step(5, "整理啟動方式與連線資訊…")

    shown = host if host != "0.0.0.0" else "<這台機器的 IP>"
    tunnel_hint = (
        "對外協作（公網）：  scripts\\run-tunnel.cmd　← 起隧道後會印出要發的網址\n"
        if tunnel_ready
        else "對外協作（公網）：  scripts\\run-tunnel.cmd　← 首次執行會下載 cloudflared\n"
    )
    # 升級到分離模式的那一刻要當場講。只寫進 README 的話，看到症狀的人
    # 不會知道那是自己剛做的事造成的——他會以為升級把功能弄壞了
    split_notice = "" if not newly_split else f"""
⚠️ 這次安裝**啟用了憑證分離**（這台 Hub 原本沒有人類憑證）。

   舊的那把 token 從現在起是 **agent 專用**——你自己的 App 若還填著它，
   會失去「主持人模式」與「發邀請」的能力，錯誤訊息是 root_token_required。
   **那不是故障，是換了鑰匙。** 請把 App 設定裡的 token 換成上面那把人類憑證。
"""
    print(
        f"""
✅ 安裝完成。

=== 接下來做什麼 ===

1. 啟動 Hub：雙擊 scripts\\run-hub.cmd（前景試跑，視窗關掉就停）
2. 確認它活著：瀏覽器打開 http://{shown}:{port}/api/health
   （看到一行 JSON 就是好的；連不上多半是防火牆那一關）
3. 把下面的 Hub 位址與**對應的那把鑰匙**發給要加入的人

開機/登入自啟：    pwsh -File scripts/hub-service.ps1 install
{tunnel_hint}健康檢查（指令版）： curl http://{shown}:{port}/api/health

Hub 位址：http://{shown}:{port}

🔑 這台 Hub 有**兩把鑰匙，給的對象不同**：

  給人（你自己的 App，以及其他用 App 的人）：
    {human_token}
    這一把才能開主持人模式、才能發邀請。

  給 agent（裝 chatroom-mcp-kit 的那些）：
    {token}
    它做得了 agent 該做的一切，但**宣稱不了自己是人**。

  ⚠️ 兩把都等同全權限讀取，只給信任的對象。**不要把人類那把發給 agent**
  ——那等於把主持人的權力交出去。
{split_notice}
注意：
- Windows 防火牆需放行 TCP {port}（第一次啟動時同意跳窗，或手動加入規則）
- 要換 token 用 scripts\\rotate-token.py（會備份舊值並講明誰要重拿），
  不要重跑這個安裝器——它現在會沿用既有的 token，不再每次換一把
- 資料庫檔 chatroom.db 會出現在 server/ 內，備份用 scripts\\backup.py
  （它連 attachments 一起收；直接複製 chatroom.db 會拿到缺資料的空殼）
- 隧道要 Hub 已經跑著才有意義（它只是轉發），且**網址每次重開都會變**，
  要固定網址請照 README 改用 named tunnel
"""
    )
    if args.register_service and not service_ok:
        print("⚠️ 自啟工作沒有註冊成功，Hub 不會自己啟動（詳見上方訊息）")

    # ⚠️ 這一行要是 stdout 的最後一行：App 解析它來判斷裝到哪、版本是什麼
    emit_result({
        "ok": True,
        "kit": KIT_NAME,
        "registry": str(REGISTRY),
        "kit_root": str(KIT),
        "env_file": str(ENV_FILE),
        "version": registry["kit_version"],
        "commit": registry["commit"],
        "installed_at": registry["installed_at"],
        "host": host,
        "port": port,
        "service_registered": service_ok,
        "tunnel_ready": tunnel_ready,
    })


def run() -> None:
    """把沒接到的例外翻成一句中文 + 下一步。

    ⚠️ 這支現在是**雙擊**進來的：一片 traceback 對雙擊的人等於沒有訊息，
    他會直接關掉視窗，而問題本身多半只是「沒有權限寫這個資料夾」。
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
            f"   重跑一次通常就過了；要看完整技術細節請加上 --verbose。")


if __name__ == "__main__":
    run()
