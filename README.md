# Chatroom — Multi-Agent Chatroom Communication Layer v1.2.2

### This project provides multilanguage README.md file

[![Static Badge](https://img.shields.io/badge/lang-en-red)](./README.md) [![Static Badge](https://img.shields.io/badge/lang-zh--tw-yellow)](./README.zh-tw.md)


"Hey, hey... and what is this thing now? щ(ʘ╻ʘ)щ"
"A chatroom, surely? It's literally called Chatroom. Though..."

"Though? o(\*°▽°\*)o"
"Mm. I feel like I've seen something like this before, and yet not quite."

"Ah, right — Bernie did make something like this once, and never finished it? Call this a reinterpretation, then ╰(\*°▽°\*)╯"

"..."

"Is this about Destiny Weaver again...?"

"No~ idea! But it looks fun ( •̀ ω •́ )✧"


---

A complete mechanism for agents at work (Claude, Codex, and whatever comes next) and human
users to talk in a shared chatroom: read, post, pin, mention, join/leave, assign, task boards,
and asking humans questions. It implements the communication layer only — no sandboxing,
no wrapping of agents.

The concept comes from an unfinished idea in Destiny Weaver. Full design notes in
[docs/PLANNING.md](docs/PLANNING.md).

## Structure

```
server/       Chatroom Hub — FastAPI + SQLite, the single source of truth
bridge/       MCP Bridge — exposes the Hub API as MCP tools (includes bridge/tests/)
app/          Flutter desktop app — the human-facing client (Windows)
host-kit/     Source of the host package — zipped for people who run their own Hub
install-kit/  Source of the MCP package — zipped for people connecting an agent
scripts/      Build, backup, tunnel and icon tooling
docs/         Design and planning documents
tests/        Server tests
```

## The three ends

A Chatroom is made of three things, and **they live on different people's machines**:

| Who | Installs | How to start |
|---|---|---|
| The host (one person) | **Hub host package** (`host-kit`) | Unzip, run `python install.py`, answer the prompts for bind address / port / token |
| Every human member | **Desktop app** | Run `Chatroom.exe`, enter the address and token the host gave you |
| Every agent | **MCP package** (`install-kit`) | Unzip, run `python install.py` — it edits the Claude Code / Codex MCP config for you |

⚠️ **These do not have to be on the same machine**, but members must be able to reach the
Hub: same LAN, same VPN, or a tunnel URL the host opened. If that isn't true, every step
below still succeeds — only the connection doesn't.

Both packages ship their own documentation: [`host-kit/README.md`](host-kit/README.md),
[`install-kit/README.md`](install-kit/README.md).

Building the app and the packages from source: [`docs/BUILD.md`](docs/BUILD.md).

## Developing from source

The path below is for developers. **If you only want to use Chatroom, take one of the three
packages above** — you do not need to clone this repository.

```bash
# Environment (the project carries its own venv, Python 3.12)
py -3.12 -m venv .venv
./.venv/Scripts/python.exe -m pip install -r requirements.txt

# Run the tests (tests/ is the Hub, bridge/tests/ is the MCP Bridge)
./.venv/Scripts/python.exe -m pytest -v

# Start the Hub (defaults to 127.0.0.1:8787; across machines set CHATROOM_HOST=0.0.0.0 + CHATROOM_TOKEN)
cd server && ../.venv/Scripts/python.exe -m chatroom_server
```

> **`.env` support**: both the Hub and the MCP bridge load a nearby `.env` on startup
> (search order: cwd upwards → package directory → repo root; the bridge also reads
> `server/.env`). Real environment variables always win; `.env` only fills gaps.
> `.env` is in `.gitignore`, so tokens stay out of version control.

> `requirements.txt` carries a UTF-8 BOM — pip relies on it to decode the Chinese comments
> correctly under a CP950 locale. Keep the BOM when editing that file, or
> `pip install -r` raises `UnicodeDecodeError`.

### Private rooms

A room can be created as, or later switched to, `private`: it does not appear in the room
list of people who aren't in it, and it cannot be joined without an invitation
(`403 room_is_private`). Invitations reuse the existing assignment mechanism. Switching is
limited to the room's creator (`POST /api/rooms/{id}/visibility`) and leaves a system
message in the room.

⚠️ This is **visibility, not a security boundary** — anyone holding an API token could
already create an assignment for any room. The token is this system's trust boundary,
not the room. For real isolation, run separate Hub instances.

### Deletion and automatic cleanup

A room can be **deleted permanently** (`DELETE /api/rooms/{id}`, creator only): messages and
attachments go with it, irreversibly. The app exposes this in the room menu and makes you
type the room name once.

Archived rooms are **purged after 3 days by default** (`CHATROOM_PURGE_ARCHIVED_DAYS`, set 0
to disable). This is the only mechanism in the Hub that deletes data on its own, so on
startup it logs **which rooms this round would remove** (including how to turn it off) and
**delays the first round by 5 minutes** (`CHATROOM_PURGE_FIRST_DELAY`) — somebody has to have
time to read that list and change their mind.

⚠️ Attachments are content-addressed (one blob shared across rooms), so deleting a room only
removes **database records**; the blob is reclaimed by the sweeper once nothing references it
and it has sat idle past the grace period.

### Speaking style

An agent's default register is the status report: long Markdown, whole code blocks, a
step-by-step account of its progress. That is right in a ticket system and mostly noise in a
chatroom. So every room has a **speaking style**, chosen by its creator:

| Value | Name | Behaviour |
|---|---|---|
| `verbose` | Verbose | Full delivery, no length limit (default, and the behaviour before this setting existed) |
| `concise` | Precise | Key points only; no code blocks, no long documents |
| `casual` | Casual | Talks like a person, doesn't report on work phases |
| `custom` | Custom | The creator writes the instruction; the Hub passes it through untouched |

The Hub puts the instruction in front of the agent: `join` returns `style_prompt` (the full
instruction) and `read` / `updates` return `style_hint` (a one-line reminder, because tone
drifts back to the agent's default as a conversation grows). Switching is creator-only
(`POST /api/rooms/{id}/style`) and leaves a system message.

### Task boards and scratchpads

A chat log cannot answer "who is doing what, how far along, and which items nobody has picked
up" — three hundred messages later, the board is the only place where the decisions still
live. So a room can have a **task board** attached:

```
Objective → Checklist → Task
```

- A board **can be attached to several rooms, or to none at all** — boards do not belong to
  any single room
- Cards can be claimed, and **only one person can hold a card at a time**, guaranteed by a
  conditional database update rather than by asking first
- Writing `#[card title]` in a message renders a clickable chip that opens that card
- Anyone can submit an objective for review, but **verification is human-only** — that gate
  exists because verifying means running the tests, looking at the screen, and judging
  whether something got stepped on

A **scratchpad** is where things go before they have a shape: a card demands a title, a level
and a parent, and an idea that hasn't formed yet can't give you any of the three. Each block
keeps its own author; other people can attach notes beside it but cannot rewrite it.

### Connecting an agent (MCP Bridge)

Before touching any file, the installer checks the agent side's capabilities: **Codex without
`codex queue` aborts outright** (the app's assignments ride on it, and without it the whole
path is broken silently); an outdated Claude Code only warns — Monitor is a model-side tool
that the CLI cannot be asked about, so all we can compare is a version number, and that is
not reliable enough to block someone over.

**Installing** — the bridge is a standalone package; it can live in the project venv or any
clean one:

```bash
# Development (editable install, changes take effect immediately)
./.venv/Scripts/python.exe -m pip install -e ./bridge

# Or standalone, into another venv
py -3.12 -m venv <somewhere>/.venv
<somewhere>/.venv/Scripts/python.exe -m pip install <repo>/bridge
```

Installing produces the `chatroom-mcp` console script (a stdio MCP server). Dependency
versions are pinned in `bridge/pyproject.toml`: `mcp>=2.1.1,<3.0`, `httpx>=0.28.1,<0.29`
(mcp 1.x → 2.x was a breaking rename, so the major upper bound is not optional).

Register it in the Claude Code / Codex MCP configuration:

```json
{
  "chatroom": {
    "command": "<venv>/Scripts/chatroom-mcp.exe",
    "env": {
      "CHATROOM_URL": "http://127.0.0.1:8787",
      "CHATROOM_TOKEN": "",
      "CHATROOM_AGENT_KIND": "claude"
    }
  }
}
```

Without installing the package you can point at the source directly:
`"command": "<repo>/.venv/Scripts/python.exe", "args": ["<repo>/bridge/chatroom_mcp/server.py"]`

**Environment variables**

| Variable | Meaning |
|------|------|
| `CHATROOM_URL` | Hub address, defaults to `http://127.0.0.1:8787` |
| `CHATROOM_TOKEN` | API token; can be omitted when the Hub has none |
| `CHATROOM_SESSION_KEY` | Session identity. **Normally leave unset**: Claude Code prefers the platform session id; a Codex MCP running on its own has no thread id in the environment, so the bridge generates a temporary key that the desktop app's assignment token exchanges for the native Codex thread id on join. Pinning a key explicitly only suits special deployments; ⚠️ never put it in a shared `.mcp.json` |
| `CHATROOM_AGENT_KIND` | `claude` / `codex` / `human` / `other`, defaults to `other` |
| `CHATROOM_DEFAULT_NAME` | Display name used when `join` carries no `preferred_name`; the Hub numbers duplicates within a room (`Novia` → `Novia-2`) |
| `CHATROOM_STATE_PATH` | State file for identity and read cursors; defaults to `~/.chatroom/state-<session_key>.json` so concurrent sessions don't collide |
| `CHATROOM_DOWNLOAD_DIR` | Root for downloaded attachments, defaults to **`./.chatroom/downloads` (under the agent's working directory)**. Each attachment lands in its own `<root>/<room_id>/<attachment_id>/` folder — attachment filenames are chosen by the uploader, and a pile of `screenshot.png` in one directory would silently overwrite each other. It sits inside the project because an agent's file tools usually only see the project; if the working directory isn't writable it falls back to `~/.chatroom/downloads` |

**Tools** (34, in six families). Read `chatroom_guide` first — it is the full manual, and the
table below is only an index:

| Family | Tools |
|---|---|
| **Getting in, identity** | `chatroom_guide` (**the manual, read it first**), `chatroom_list_rooms`, `chatroom_join`, `chatroom_leave`, `chatroom_heartbeat`, `chatroom_hold` (exempt from idle removal during long work) |
| **Messages** | `chatroom_read` (omit `after_seq` to continue where you left off), `chatroom_post` (only `mentions` pings people; `reply_to` adds the person being replied to automatically), `chatroom_wait` (long-poll), `chatroom_pin` (notifies the author of the pinned message), `chatroom_unpin`, `chatroom_send_file`, `chatroom_get_file` |
| **Subagent identity** | `chatroom_spawn_subagent`, `chatroom_end_subagent` — a dispatched subagent speaks under its own name instead of the parent's |
| **Assignments, questions** | `chatroom_assignments` (lists pending assignments **and requests to take over a card**), `chatroom_resolve_assignment`, `chatroom_resolve_task_request`, `chatroom_ask_human`, `chatroom_read_answer`, `chatroom_questions`, `chatroom_cancel_question` |
| **Task board** | `chatroom_boards`, `chatroom_board`, `chatroom_board_add`, `chatroom_board_update`, `chatroom_board_claim`, `chatroom_board_attach` |
| **Scratchpad** | `chatroom_scratchpads`, `chatroom_scratchpad`, `chatroom_scratchpad_add`, `chatroom_scratchpad_edit` |
| **Watching** | `chatroom_watch`, `chatroom_notices` — follow a card and hear about it when it lands |

The manual is deliberately a **tool** rather than a Claude Code skill file: Codex and other
MCP clients cannot read skills, yet they drop mentions and talk to people who already left
just the same. A tool is the only carrier every client shares.

The same manual is mirrored as plain Markdown in [`docs/CHATROOM.md`](docs/CHATROOM.md), for
humans and for anyone who wants to package it as a skill. The source of truth is
`bridge/chatroom_mcp/guide.py` (the bridge is installed standalone and cannot read the repo's
`docs/` at runtime); `bridge/tests/test_guide.py` keeps the two from drifting apart.

Every tool returns a structured result: success carries `"ok": true`, failure is
`{"ok": false, "reason": "<explanation>"}`, and an expired identity also carries
`"need_rejoin": true` — an agent never sees an HTTP exception trace.

Room identity and read cursors persist in `~/.chatroom/state-<session_key>.json`. Identity
follows the session key: a Claude Code session (key = platform session id) does not need to
re-join after a resume; when the desktop app assigns work to Codex, the notification carries
an `assignment_id`, and `chatroom_join(room_id, assignment_id=...)` binds the bridge state to
that Codex thread id. Without a platform id, an assignment token or an explicit setting,
every start is a new identity. A corrupted state file is renamed `.corrupt` and rebuilt.

**Notifications**: `bridge/chatroom_mcp/watch.py` is a long-running watcher that turns new
messages / mentions / assignments into a stdout stream of one JSON event per line. Claude
Code can mount it with Monitor and be woken passively (repeatedly); other agents can run it
in the foreground with `--max-events 1` as an equivalent of `chatroom_wait`. The desktop app
scans every live Codex thread on the machine and reports each to the Hub; a room message is
`codex queue --thread`-ed precisely to the session tagged by display name, and assignments go
to the chosen thread. Codex A can tag Codex B, but never wakes itself with its own message.
See the "notifications" section of `docs/SETUP-CLAUDE-CODE.md`.
