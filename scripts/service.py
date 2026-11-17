"""非 Windows 的 Hub／執行器服務管理（Linux systemd user、macOS LaunchAgent）。

    <python> scripts/service.py {hub|runner} {install|uninstall|start|stop|status} [--json]

對應 Windows 的 `scripts/hub-service.ps1` 與 `runner/install-task.ps1`，語意一致：

- install   註冊登入自啟，**不啟動**（重跑就是覆寫）
- start     啟用並啟動（對稱於 stop 的停用）
- stop      **停用並停止**：服務設了失敗自動重啟，只停進程的話一分鐘內會被拉回來
- uninstall 停止並移除註冊
- status    查狀態；`--json` 的欄位是與桌面 App 約好的契約，不可改名：
            {"manager": "systemd|launchd|none", "installed": bool,
             "enabled": bool, "running": bool, "detail": str}

Windows 不走這支（manager 回 "none"）：那條路由 PowerShell 腳本負責，行為不動。

⚠️ 單一來源：host-kit 與 runner-kit 的 build.py 各自把這個檔案複製進 zip 的
`scripts/service.py`，不要在別處另存一份。只用標準庫，kit 的 venv 與系統 Python
都跑得起來。
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

KITS = ("hub", "runner")
ACTIONS = ("install", "uninstall", "start", "stop", "status")

# 失敗後等多久再拉起。Windows 兩邊都是 RestartInterval 1 分鐘
RESTART_SECONDS = 60
# 停止 Hub 後等埠釋放、以及 SIGTERM 之後等進程退場的上限（秒）
PORT_WAIT_SECONDS = 5.0
DEFAULT_HUB_PORT = "8787"


class ServiceError(Exception):
    """可預期的失敗：訊息是給人看的一句話。"""


# ---------------------------------------------------------------------------
# 路徑
# ---------------------------------------------------------------------------

def install_root() -> Path:
    """安裝根目錄。

    與 `chatroom_runner.config.default_state_dir()` 的父目錄、`runner-kit/install.py`
    的 `install_root()` 是同一個答案（有測試守著三處一致）：
    Windows `%LOCALAPPDATA%\\UEP\\Chatroom`；macOS
    `~/Library/Application Support/UEP/Chatroom`；Linux
    `${XDG_DATA_HOME:-~/.local/share}/uep/chatroom`。
    """
    if sys.platform == "win32":
        env = os.environ.get("LOCALAPPDATA")
        base = Path(env) if env else Path.home() / "AppData" / "Local"
        return base / "UEP" / "Chatroom"
    if sys.platform == "darwin":
        return (Path.home() / "Library" / "Application Support"
                / "UEP" / "Chatroom")
    xdg = os.environ.get("XDG_DATA_HOME", "")
    # XDG 規範：相對路徑視為無效，退回預設
    base = Path(xdg) if xdg and os.path.isabs(xdg) \
        else Path.home() / ".local" / "share"
    return base / "uep" / "chatroom"


def kit_root() -> Path:
    """這支腳本所在的 kit（或 repo）根目錄：`<root>/scripts/service.py`。"""
    return Path(__file__).resolve().parents[1]


def venv_python(kit: Path) -> Path:
    sub = "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
    return kit / ".venv" / sub


# ---------------------------------------------------------------------------
# 服務描述
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Spec:
    kind: str          # hub | runner
    unit: str          # systemd unit 名稱
    label: str         # launchd label
    description: str
    workdir: Path
    argv: tuple[str, ...]
    log_file: Path
    # Hub 才有：停止後要確認空掉的埠。None＝不做埠檢查
    port: str | None = None


def read_env_value(env_file: Path, key: str) -> str:
    """`.env` 取一個值；解析規則同 server／tunnel：忽略空行與 `#`，只切第一個 `=`。"""
    try:
        text = env_file.read_text(encoding="utf-8-sig")
    except OSError:
        return ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            return v.strip().strip('"').strip("'")
    return ""


def make_spec(kind: str, kit: Path, python: Path | None = None,
              config: Path | None = None, *, check: bool = True) -> Spec:
    """組出服務描述。``check`` 為 False 時不驗檔案在不在：status／stop／
    uninstall 在 kit 已被刪掉的情況下仍然要能用（那正是最需要它們的時候）。"""
    if kind not in KITS:
        raise ServiceError(f"不認得的服務：{kind}（只有 {'、'.join(KITS)}）")
    py = python or venv_python(kit)
    if check and not py.exists():
        # 不拿一個不存在的直譯器去註冊——服務會每分鐘重試一次然後永遠失敗
        raise ServiceError(f"找不到 Python：{py}。請先跑安裝器建好 .venv。")
    log_dir = install_root() / kind / "logs"
    if kind == "hub":
        server = kit / "server"
        if check and not (server / "chatroom_server").is_dir():
            raise ServiceError(f"找不到 Hub 程式：{server / 'chatroom_server'}")
        port = (os.environ.get("CHATROOM_PORT")
                or read_env_value(server / ".env", "CHATROOM_PORT")
                or DEFAULT_HUB_PORT)
        return Spec(
            kind="hub", unit="uep-chatroom-hub.service",
            label="com.uep.chatroom.hub",
            description="Chatroom Hub", workdir=server,
            argv=(str(py), "-m", "chatroom_server"),
            log_file=log_dir / "service.log", port=port)
    cfg = config or (install_root() / "runner" / "config.json")
    if check and not (kit / "runner" / "chatroom_runner").is_dir():
        raise ServiceError(
            f"找不到執行器程式：{kit / 'runner' / 'chatroom_runner'}")
    return Spec(
        kind="runner", unit="uep-chatroom-runner.service",
        label="com.uep.chatroom.runner",
        description="Chatroom runner", workdir=kit,
        argv=(str(py), "-m", "chatroom_runner", "--config", str(cfg)),
        log_file=log_dir / "service.log")


# ---------------------------------------------------------------------------
# 外部指令（測試時整個換掉）
# ---------------------------------------------------------------------------

def run_cmd(argv: list[str], timeout: float = 30.0
            ) -> subprocess.CompletedProcess:
    """跑一條指令並收輸出。起不來／逾時以 returncode 127／124 表示，不丟例外。"""
    try:
        return subprocess.run(argv, capture_output=True, text=True,
                              encoding="utf-8", errors="replace",
                              timeout=timeout, check=False)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc))
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, 124, "", "逾時")
    except OSError as exc:
        return subprocess.CompletedProcess(argv, 126, "", str(exc))


def _msg(done: subprocess.CompletedProcess) -> str:
    return ((done.stderr or "").strip() or (done.stdout or "").strip()
            or f"退出碼 {done.returncode}")


def detect_manager() -> str:
    """這台機器能用哪個服務管理員。能不能用要實際問，不能只看有沒有指令。"""
    if sys.platform == "darwin":
        return "launchd" if shutil.which("launchctl") else "none"
    if sys.platform.startswith("linux"):
        # 沒有 systemd 當 init（容器、沒開 systemd 的 WSL）或沒有使用者 bus 時，
        # `systemctl --user` 會直接連不上：那種環境註冊了也不會有人拉起它
        if shutil.which("systemctl") and \
                run_cmd(["systemctl", "--user", "show-environment"]
                        ).returncode == 0:
            return "systemd"
    return "none"


def service_env_path() -> str:
    """安裝當下的 PATH。

    服務管理員拉起的進程拿不到登入 shell 的 PATH（`claude`、`git`、`gpg` 常常
    在 ~/.local/bin 或 Homebrew 底下），不帶的話 Hub 起得來、執行器卻會因為
    找不到 claude 而在每次派工時失敗。
    """
    return os.environ.get("PATH", "")


# ---------------------------------------------------------------------------
# systemd（Linux）
# ---------------------------------------------------------------------------

def systemd_unit_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME", "")
    base = Path(xdg) if xdg and os.path.isabs(xdg) \
        else Path.home() / ".config"
    return base / "systemd" / "user"


def _sd_word(value: str) -> str:
    """ExecStart 的一個詞：要轉義 `% $ \\ "`，有空白就加引號。"""
    esc = (value.replace("\\", "\\\\").replace('"', '\\"')
           .replace("%", "%%").replace("$", "$$"))
    if esc == "" or re.search(r"[\s'\";]", esc):
        return f'"{esc}"'
    return esc


def build_systemd_unit(spec: Spec, path_env: str) -> str:
    exec_start = " ".join(_sd_word(a) for a in spec.argv)
    env_path = path_env.replace("\\", "\\\\").replace('"', '\\"') \
        .replace("%", "%%")
    log = str(spec.log_file).replace("%", "%%")
    lines = [
        "[Unit]",
        f"Description={spec.description}",
        "After=network-online.target",
        "Wants=network-online.target",
        "",
        "[Service]",
        "Type=simple",
        f"WorkingDirectory={str(spec.workdir).replace('%', '%%')}",
        f"ExecStart={exec_start}",
        "Restart=always",
        f"RestartSec={RESTART_SECONDS}",
    ]
    if path_env:
        lines.append(f'Environment="PATH={env_path}"')
    lines += [
        f"StandardOutput=append:{log}",
        f"StandardError=append:{log}",
        "",
        "[Install]",
        "WantedBy=default.target",
        "",
    ]
    return "\n".join(lines)


def _sctl(*args: str) -> subprocess.CompletedProcess:
    return run_cmd(["systemctl", "--user", *args])


def linger_hint() -> str:
    """登出後服務還在不在，取決於 linger。**只提示、不代做**（需要權限）。"""
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    if not user or not shutil.which("loginctl"):
        return ""
    done = run_cmd(["loginctl", "show-user", user, "--property=Linger"])
    if done.returncode == 0 and "Linger=yes" in (done.stdout or ""):
        return ""
    return (f"目前登出後服務會跟著停。要登出後仍持續執行，請另外執行"
            f"（需要權限）：sudo loginctl enable-linger {user}")


def systemd_install(spec: Spec) -> str:
    unit_path = systemd_unit_dir() / spec.unit
    unit_path.parent.mkdir(parents=True, exist_ok=True)
    spec.log_file.parent.mkdir(parents=True, exist_ok=True)
    unit_path.write_text(build_systemd_unit(spec, service_env_path()),
                         encoding="utf-8")
    for args in (("daemon-reload",), ("enable", spec.unit)):
        done = _sctl(*args)
        if done.returncode != 0:
            raise ServiceError(f"systemctl --user {' '.join(args)} 失敗："
                               f"{_msg(done)}")
    detail = (f"已註冊 {spec.unit}（{unit_path}），登入自啟，**還沒啟動**。"
              f"log：{spec.log_file}")
    hint = linger_hint()
    return f"{detail}\n{hint}" if hint else detail


def systemd_uninstall(spec: Spec) -> str:
    unit_path = systemd_unit_dir() / spec.unit
    _sctl("disable", "--now", spec.unit)  # 沒註冊過也會失敗，不影響後面
    existed = unit_path.exists()
    unit_path.unlink(missing_ok=True)
    _sctl("daemon-reload")
    _sctl("reset-failed", spec.unit)
    free_port(spec)
    return f"已移除 {spec.unit}" if existed else f"沒有 {spec.unit} 可移除"


def systemd_start(spec: Spec) -> str:
    if not (systemd_unit_dir() / spec.unit).exists():
        raise ServiceError(f"尚未註冊 {spec.unit}，請先 install")
    done = _sctl("enable", "--now", spec.unit)
    if done.returncode != 0:
        raise ServiceError(f"啟動失敗：{_msg(done)}")
    return f"已啟動 {spec.unit}"


def systemd_stop(spec: Spec) -> str:
    # 停用 + 停止：只 stop 的話下次登入又會起來，與 Windows「stop 會停用觸發器」不同
    done = _sctl("disable", "--now", spec.unit)
    if done.returncode != 0:
        raise ServiceError(f"停止失敗：{_msg(done)}")
    note = free_port(spec)
    return (f"已停止 {spec.unit}（已停用自啟；start 會重新啟用）"
            + (f"\n{note}" if note else ""))


def systemd_status(spec: Spec) -> dict:
    unit_path = systemd_unit_dir() / spec.unit
    installed = unit_path.exists()
    enabled_out = (_sctl("is-enabled", spec.unit).stdout or "").strip()
    active_out = (_sctl("is-active", spec.unit).stdout or "").strip()
    enabled = enabled_out == "enabled"
    running = active_out == "active"
    if not installed:
        detail = f"未註冊（{unit_path} 不存在）"
    else:
        detail = (f"{spec.unit}：{active_out or 'unknown'}，"
                  f"自啟 {enabled_out or 'unknown'}；log：{spec.log_file}")
    return {"manager": "systemd", "installed": installed,
            "enabled": enabled, "running": running, "detail": detail}


# ---------------------------------------------------------------------------
# launchd（macOS）
# ---------------------------------------------------------------------------

def launch_agents_dir() -> Path:
    return Path.home() / "Library" / "LaunchAgents"


def launchd_domain() -> str:
    return f"gui/{os.getuid()}"


def build_launchd_plist(spec: Spec, path_env: str) -> bytes:
    payload: dict = {
        "Label": spec.label,
        "ProgramArguments": list(spec.argv),
        "WorkingDirectory": str(spec.workdir),
        "RunAtLoad": True,
        "KeepAlive": True,
        # 對應 Windows 的 RestartInterval 1 分鐘：launchd 至少隔這麼久才再拉起
        "ThrottleInterval": RESTART_SECONDS,
        "StandardOutPath": str(spec.log_file),
        "StandardErrorPath": str(spec.log_file),
    }
    if path_env:
        payload["EnvironmentVariables"] = {"PATH": path_env}
    return plistlib.dumps(payload)


def _lctl(*args: str) -> subprocess.CompletedProcess:
    return run_cmd(["launchctl", *args])


def launchd_loaded(spec: Spec) -> subprocess.CompletedProcess:
    return _lctl("print", f"{launchd_domain()}/{spec.label}")


def launchd_disabled(spec: Spec) -> bool:
    done = _lctl("print-disabled", launchd_domain())
    if done.returncode != 0:
        return False
    return bool(re.search(rf'"{re.escape(spec.label)}"\s*=>\s*(?:true|disabled)',
                          done.stdout or ""))


def launchd_install(spec: Spec) -> str:
    plist = launch_agents_dir() / f"{spec.label}.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    spec.log_file.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(build_launchd_plist(spec, service_env_path()))
    # 先前 stop 過會留下「停用」標記；重新註冊就是要它回到可用
    _lctl("enable", f"{launchd_domain()}/{spec.label}")
    return (f"已註冊 {spec.label}（{plist}），登入自啟，**還沒啟動**。"
            f"log：{spec.log_file}")


def launchd_start(spec: Spec) -> str:
    plist = launch_agents_dir() / f"{spec.label}.plist"
    if not plist.exists():
        raise ServiceError(f"尚未註冊 {spec.label}，請先 install")
    target = f"{launchd_domain()}/{spec.label}"
    _lctl("enable", target)
    if launchd_loaded(spec).returncode != 0:
        done = _lctl("bootstrap", launchd_domain(), str(plist))
        if done.returncode != 0:
            raise ServiceError(f"launchctl bootstrap 失敗：{_msg(done)}")
    # 已載入但沒在跑（例如被停過）時 kickstart 才會真的啟動；在跑就不動它
    done = _lctl("kickstart", target)
    if done.returncode != 0:
        raise ServiceError(f"launchctl kickstart 失敗：{_msg(done)}")
    return f"已啟動 {spec.label}"


def launchd_stop(spec: Spec) -> str:
    target = f"{launchd_domain()}/{spec.label}"
    # 沒載入時 bootout 會報錯，那是「本來就停著」，不是失敗
    if launchd_loaded(spec).returncode == 0:
        done = _lctl("bootout", target)
        if done.returncode != 0:
            raise ServiceError(f"launchctl bootout 失敗：{_msg(done)}")
    _lctl("disable", target)
    note = free_port(spec)
    return (f"已停止 {spec.label}（已停用自啟；start 會重新啟用）"
            + (f"\n{note}" if note else ""))


def launchd_uninstall(spec: Spec) -> str:
    plist = launch_agents_dir() / f"{spec.label}.plist"
    target = f"{launchd_domain()}/{spec.label}"
    if launchd_loaded(spec).returncode == 0:
        _lctl("bootout", target)
    _lctl("enable", target)  # 清掉停用標記，不留在 launchd 的資料庫裡
    existed = plist.exists()
    plist.unlink(missing_ok=True)
    free_port(spec)
    return f"已移除 {spec.label}" if existed else f"沒有 {spec.label} 可移除"


def launchd_status(spec: Spec) -> dict:
    plist = launch_agents_dir() / f"{spec.label}.plist"
    installed = plist.exists()
    loaded = launchd_loaded(spec)
    out = loaded.stdout or ""
    running = loaded.returncode == 0 and bool(
        re.search(r"\bstate = running\b", out) or re.search(r"\bpid = \d+", out))
    enabled = installed and not launchd_disabled(spec)
    if not installed:
        detail = f"未註冊（{plist} 不存在）"
    else:
        state = "執行中" if running else ("已載入、未執行" if
                                       loaded.returncode == 0 else "未載入")
        detail = (f"{spec.label}：{state}，"
                  f"自啟{'啟用' if enabled else '停用'}；log：{spec.log_file}")
    return {"manager": "launchd", "installed": installed,
            "enabled": enabled, "running": running, "detail": detail}


# ---------------------------------------------------------------------------
# 埠擁有者（Hub 停止後的收尾，對應 hub-service.ps1 的「以埠為準」）
# ---------------------------------------------------------------------------

def port_owners(port: str) -> list[int]:
    """誰在聽這個埠。依序試 lsof、ss、/proc；都問不出來回空清單。"""
    if shutil.which("lsof"):
        done = run_cmd(["lsof", "-nP", "-t", f"-iTCP:{port}",
                        "-sTCP:LISTEN"])
        if done.returncode in (0, 1):  # lsof 沒找到時回 1
            return sorted({int(x) for x in (done.stdout or "").split()
                           if x.isdigit()})
    if shutil.which("ss"):
        done = run_cmd(["ss", "-H", "-ltnp", f"sport = :{port}"])
        if done.returncode == 0:
            return sorted({int(x) for x in
                           re.findall(r"pid=(\d+)", done.stdout or "")})
    return _proc_port_owners(port)


def _proc_port_owners(port: str) -> list[int]:
    """純 Python：讀 /proc/net/tcp{,6} 找 LISTEN 的 inode，再回頭掃 /proc/*/fd。"""
    proc = Path("/proc")
    if not (proc / "net" / "tcp").exists():
        return []
    want = f"{int(port):04X}"
    inodes: set[str] = set()
    for name in ("tcp", "tcp6"):
        try:
            rows = (proc / "net" / name).read_text().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            cols = row.split()
            if len(cols) > 9 and cols[3] == "0A" \
                    and cols[1].rsplit(":", 1)[-1] == want:
                inodes.add(cols[9])
    if not inodes:
        return []
    pids: set[int] = set()
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            for fd in (entry / "fd").iterdir():
                try:
                    link = os.readlink(fd)
                except OSError:
                    continue
                if link.startswith("socket:[") and link[8:-1] in inodes:
                    pids.add(int(entry.name))
        except OSError:
            continue  # 別人的進程讀不到，略過
    return sorted(pids)


def _proc_name(pid: int) -> str:
    done = run_cmd(["ps", "-o", "comm=", "-p", str(pid)])
    return (done.stdout or "").strip()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def free_port(spec: Spec) -> str:
    """停 Hub 之後確認埠真的空了；只收 python 進程，其餘讓人看見而不是順手殺。

    與 hub-service.ps1 同一個理由：Hub 是 uvicorn，真正在聽的可能是
    multiprocessing spawn 出來的那一層，服務管理員停的只是上一層。
    不是 Hub（沒有 port）時什麼都不做。
    """
    if not spec.port:
        return ""
    owners = port_owners(spec.port)
    notes: list[str] = []
    for pid in owners:
        name = _proc_name(pid)
        if "python" not in name.lower():
            notes.append(f"⚠️ 埠 {spec.port} 被 PID {pid}（{name or '未知'}）占著，"
                         "不是 python，不動它——請自行確認那是什麼")
            continue
        notes.append(f"埠 {spec.port} 仍被 python PID {pid} 佔著，一併收掉")
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            continue
        deadline = time.monotonic() + PORT_WAIT_SECONDS
        while time.monotonic() < deadline and _alive(pid):
            time.sleep(0.1)
        if _alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    if owners:
        left = port_owners(spec.port)
        if left:
            notes.append(f"⚠️ 埠 {spec.port} 仍有監聽（PID "
                         f"{'、'.join(map(str, left))}）")
    return "\n".join(notes)


# ---------------------------------------------------------------------------
# 分派
# ---------------------------------------------------------------------------

_BACKENDS = {
    "systemd": {"install": systemd_install, "uninstall": systemd_uninstall,
                "start": systemd_start, "stop": systemd_stop,
                "status": systemd_status},
    "launchd": {"install": launchd_install, "uninstall": launchd_uninstall,
                "start": launchd_start, "stop": launchd_stop,
                "status": launchd_status},
}


def none_status(detail: str) -> dict:
    return {"manager": "none", "installed": False, "enabled": False,
            "running": False, "detail": detail}


def no_manager_detail() -> str:
    if sys.platform == "win32":
        return ("Windows 不走這支：請用 scripts/hub-service.ps1 或 "
                "runner/install-task.ps1")
    if sys.platform.startswith("linux"):
        return ("這台機器沒有可用的 systemd 使用者服務"
                "（`systemctl --user` 連不上）。容器或沒開 systemd 的 WSL 屬於這種；"
                "請改用 run-hub.sh／前景手動啟動。")
    return "這個平台沒有支援的服務管理員"


def perform(kind: str, action: str, *, kit: Path | None = None,
            python: Path | None = None, config: Path | None = None) -> dict:
    """執行一個動作，回傳要輸出的 dict。失敗丟 ServiceError。"""
    manager = detect_manager()
    if action == "status" and manager == "none":
        return none_status(no_manager_detail())
    if manager == "none":
        raise ServiceError(no_manager_detail())
    spec = make_spec(kind, kit or kit_root(), python, config,
                     check=action in ("install", "start"))
    result = _BACKENDS[manager][action](spec)
    if action == "status":
        return result
    return {"ok": True, "manager": manager, "detail": result}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Hub／執行器的服務管理（systemd user／launchd）")
    p.add_argument("kind", choices=KITS)
    p.add_argument("action", choices=ACTIONS)
    p.add_argument("--json", action="store_true", help="輸出 JSON（給 App 解析）")
    p.add_argument("--kit", type=Path, help="kit 根目錄；預設是這支腳本的上一層")
    p.add_argument("--python", type=Path,
                   help="服務用的直譯器；預設 <kit>/.venv 裡那支")
    p.add_argument("--config", type=Path,
                   help="（runner）設定檔路徑；預設在安裝根目錄的 runner/ 下")
    args = p.parse_args(argv)

    try:
        result = perform(args.kind, args.action, kit=args.kit,
                         python=args.python, config=args.config)
        code = 0
    except ServiceError as exc:
        if args.action == "status":
            result, code = none_status(str(exc)), 1
        else:
            result, code = {"ok": False, "manager": detect_manager(),
                            "detail": str(exc)}, 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False), flush=True)
    else:
        print(result["detail"], flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
