"""指派的界線：一個人只指派得動自己的 agent（艾斯維爾裁 2026-09-12）。

一「群」＝**一個人連同他的 agent**。判準是接入用的憑證，不是自報的主機名
（`session.host` 的註解自己就寫著那是辨識用、不是授權依據），也不是前端
過濾——前端只擋得住誤點，繞過 App 直接打 REST 的那條路才是要關的。

兩條必須同時成立的規則，它們是同一件事的兩面：

- 別人指派不動我的 agent
- **我也指派不動別人的，即使我是主持人**（開了前者就等於開了後者）

而 `.env` 的兩把（`CHATROOM_TOKEN` / `CHATROOM_HUMAN_TOKEN`）必須同群：
分離憑證之後一台機器上的人與他的 bridge 本來就用不同 token，分開算的話
主持人會指派不了自己機器上的 agent——規則反過來咬自己。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


async def _hub(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 human_api_token=HUMAN)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {HUMAN}"})


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def _invite(host, label, audience="human", parent=""):
    body = {"label": label, "audience": audience}
    if parent:
        body["parent_token"] = parent
    r = await host.post("/api/tokens", json=body)
    assert r.status_code == 200, r.text
    return r.json()["token"]


async def _heartbeat(client, token, session_key, kind="claude"):
    """agent 進名錄的實際路徑：watcher 輪詢 GET /api/assignments。"""
    r = await client.get("/api/assignments", headers={
        **_auth(token), "X-Session-Key": session_key},
        params={"kind": kind, "label": session_key})
    assert r.status_code == 200, r.text


async def _keys(client, token):
    r = await client.get("/api/sessions", headers=_auth(token))
    assert r.status_code == 200, r.text
    return {s["session_key"] for s in r.json()["sessions"]}


async def _room(host):
    return (await host.post("/api/rooms", json={
        "name": "房", "session_key": "human-host"})).json()["id"]


# ---------- 名錄只列同群 ----------

async def test_you_only_see_your_own_agents(tmp_path):
    app, host = await _hub(tmp_path, "party-list")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        await _heartbeat(host, a, "claude-a1")
        await _heartbeat(host, b, "claude-b1")

        assert await _keys(host, a) == {"claude-a1"}
        assert await _keys(host, b) == {"claude-b1"}


async def test_the_env_pair_is_one_party(tmp_path):
    """主持人的 App 用 human token、他的 bridge 用 agent token。

    分開算的話他會指派不了自己機器上的 agent——這條規則會反過來咬自己。
    """
    app, host = await _hub(tmp_path, "party-env")
    async with app.router.lifespan_context(app), host:
        await _heartbeat(host, ROOT, "claude-mine")
        assert "claude-mine" in await _keys(host, HUMAN)


async def test_the_same_invite_on_a_second_device_is_the_same_person(tmp_path):
    """同一張碼貼在第二台裝置上——本來就是同一個人，不必另外做事。"""
    app, host = await _hub(tmp_path, "party-device")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        await _heartbeat(host, a, "claude-laptop")
        await _heartbeat(host, a, "claude-desktop")
        assert await _keys(host, a) == {"claude-laptop", "claude-desktop"}


async def test_a_session_that_has_not_reported_yet_is_still_listed(tmp_path):
    """`party=''` 是「還沒心跳過」，不是「別人的」。

    當成別群排掉的話，升級的那一瞬間每個人的指派清單都會變空——而那看
    起來像所有 agent 一起死了。
    """
    app, host = await _hub(tmp_path, "party-unknown")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        db = app.state.db
        await db.execute(
            "INSERT INTO session (session_key, kind, label, first_seen_at,"
            " last_seen_at, party) VALUES (?,?,?,?,?,?)",
            ("claude-old", "claude", "舊的", "2099-01-01T00:00:00+00:00",
             "2099-01-01T00:00:00+00:00", ""))
        await db.commit()

        listed = await _keys(host, a)
        assert "claude-old" in listed


# ---------- 指派 ----------

async def test_you_cannot_assign_someone_elses_agent(tmp_path):
    app, host = await _hub(tmp_path, "party-assign")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        await _heartbeat(host, b, "claude-b1")
        rid = await _room(host)

        r = await host.post(f"/api/rooms/{rid}/assignments",
                            headers=_auth(a),
                            json={"target_session_key": "claude-b1"})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_your_agent"


async def test_not_even_the_host(tmp_path):
    """主持人**沒有穿透口**（艾斯維爾明確裁定）。

    「我能指派所有人的 agent」與「別人能指派我的 agent」是同一條規則的
    兩面，開了前者就等於開了後者。
    """
    app, host = await _hub(tmp_path, "party-host-assign")
    async with app.router.lifespan_context(app), host:
        b = await _invite(host, "B")
        await _heartbeat(host, b, "claude-b1")
        rid = await _room(host)

        r = await host.post(f"/api/rooms/{rid}/assignments",
                            json={"target_session_key": "claude-b1"})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_your_agent"


async def test_you_can_assign_your_own(tmp_path):
    app, host = await _hub(tmp_path, "party-assign-ok")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        await _heartbeat(host, a, "claude-a1")
        rid = await _room(host)

        r = await host.post(f"/api/rooms/{rid}/assignments",
                            headers=_auth(a),
                            json={"target_session_key": "claude-a1"})
        assert r.status_code == 200, r.text


async def test_the_boundary_also_holds_at_redemption(tmp_path):
    """目標還沒上線時建立當下判不了群，界線移到兌換那一刻。

    否則「先指派一個還沒出現的 key、對方稍後用別群的憑證上線」就是一條
    完整的繞道。
    """
    app, host = await _hub(tmp_path, "party-redeem")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        rid = await _room(host)
        # 目標從未出現過 ⇒ 建立成立
        aid = (await host.post(f"/api/rooms/{rid}/assignments",
                               headers=_auth(a),
                               json={"target_session_key": "claude-later"}
                               )).json()["id"]

        # 那個 key 用**別群**的憑證上線來兌換
        r = await host.post(f"/api/rooms/{rid}/join", headers=_auth(b),
                            json={"kind": "claude", "role": "agent",
                                  "session_key": "claude-later",
                                  "assignment_id": aid})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_your_agent"

        # 同群的話正常兌換
        ok = await host.post(f"/api/rooms/{rid}/join", headers=_auth(a),
                             json={"kind": "claude", "role": "agent",
                                   "session_key": "claude-later",
                                   "assignment_id": aid})
        assert ok.status_code == 200, ok.text


# ---------- 加發（方案 B） ----------

async def test_an_agent_token_issued_under_an_invite_joins_that_party(tmp_path):
    """主持人先發人的那張，對方的 agent 要接入時再從它底下加發一張。

    這是「一張邀請 = 一個人」在 UI 上有實體的走法：對方一次只拿一串，
    而「誰的 agent」在畫面上看得見。
    """
    app, host = await _hub(tmp_path, "party-child")
    async with app.router.lifespan_context(app), host:
        human_code = await _invite(host, "給艾斯維爾")
        agent_code = await _invite(host, "他的 Claude", audience="agent",
                                   parent=human_code)
        await _heartbeat(host, agent_code, "claude-his")
        rid = await _room(host)

        # 他用 App（人的那張）指派自己的 agent
        r = await host.post(f"/api/rooms/{rid}/assignments",
                            headers=_auth(human_code),
                            json={"target_session_key": "claude-his"})
        assert r.status_code == 200, r.text
        # 而別人（這裡是主持人）仍然指派不動它
        deny = await host.post(f"/api/rooms/{rid}/assignments",
                               json={"target_session_key": "claude-his"})
        assert deny.status_code == 403, deny.text


async def test_adding_under_a_token_that_does_not_exist_is_an_error(tmp_path):
    """靜靜發一張自成一群的比報錯更糟：那張碼長得跟成功的一模一樣，
    直到對方的 agent 被指派時才發現它不屬於任何人。"""
    app, host = await _hub(tmp_path, "party-child-404")
    async with app.router.lifespan_context(app), host:
        r = await host.post("/api/tokens", json={
            "label": "孤兒", "audience": "agent",
            "parent_token": "沒有這張"})
        assert r.status_code == 404, r.text
        assert r.json()["detail"]["code"] == "parent_token_not_found"


# ---------- 人類不受這條界線 ----------
#
# party 是 **agent 的界線**。人與人本來就分屬不同群（各拿一張邀請碼），而
# 「邀請成員加入」要找的正是別群的那個人——把 party 套到人類身上的話，兩個
# 人連同一個 Hub（一個走 LAN、一個走 tunnel）會在對話框裡互相看不見，於是
# 誰也邀不了誰（艾斯維爾 2026-09-22 實測）。


async def _human_seen(client, token, key):
    """人進名錄的實際路徑：App 開著就會列房間。"""
    r = await client.get("/api/rooms", headers={
        **_auth(token), "X-Session-Key": key}, params={"kind": "human"})
    assert r.status_code == 200, r.text


async def _keys_with_humans(client, token):
    r = await client.get("/api/sessions", headers=_auth(token),
                         params={"include_human": "true"})
    assert r.status_code == 200, r.text
    return {s["session_key"] for s in r.json()["sessions"]}


async def test_you_see_other_humans_but_not_their_agents(tmp_path):
    app, host = await _hub(tmp_path, "party-human-list")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        await _human_seen(host, a, "human-a")
        await _human_seen(host, b, "human-b")
        await _heartbeat(host, b, "claude-b1")

        listed = await _keys_with_humans(host, a)
        assert "human-b" in listed
        # 對照組：別人的 agent 仍然看不到
        assert "claude-b1" not in listed


async def test_you_can_invite_another_human(tmp_path):
    app, host = await _hub(tmp_path, "party-human-assign")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        await _human_seen(host, a, "human-a")
        await _human_seen(host, b, "human-b")
        await _heartbeat(host, b, "claude-b1")
        rid = await _room(host)

        ok = await host.post(f"/api/rooms/{rid}/assignments", headers=_auth(a),
                             json={"target_session_key": "human-b"})
        assert ok.status_code == 200, ok.text
        # 對照組：他的 agent 仍然指派不動
        deny = await host.post(f"/api/rooms/{rid}/assignments",
                               headers=_auth(a),
                               json={"target_session_key": "claude-b1"})
        assert deny.status_code == 403, deny.text
        assert deny.json()["detail"]["code"] == "not_your_agent"


async def test_the_invited_human_redeems_it_into_a_private_room(tmp_path):
    """邀請要真的走得完：建立 → 對方用自己的憑證兌換 → 進得了私人房。

    只驗到建立 200 的話，兌換那一關的群比對仍然會把人擋在門外。
    """
    app, host = await _hub(tmp_path, "party-human-redeem")
    async with app.router.lifespan_context(app), host:
        a = await _invite(host, "A")
        b = await _invite(host, "B")
        b_agent = await _invite(host, "B 的 Claude", audience="agent",
                                parent=b)
        await _human_seen(host, a, "human-a")
        await _human_seen(host, b, "human-b")

        rid = (await host.post("/api/rooms", headers={
            **_auth(a), "X-Session-Key": "human-a"},
            json={"name": "私人", "visibility": "private",
                  "session_key": "human-a"})).json()["id"]
        aid = (await host.post(f"/api/rooms/{rid}/assignments",
                               headers=_auth(a),
                               json={"target_session_key": "human-b"}
                               )).json()["id"]

        # 對照組：拿 agent 憑證兌換「發給人的」邀請不成立
        bad = await host.post(f"/api/rooms/{rid}/join", headers=_auth(b_agent),
                              json={"kind": "claude", "role": "agent",
                                    "session_key": "human-b",
                                    "assignment_id": aid})
        assert bad.status_code == 403, bad.text
        assert bad.json()["detail"]["code"] == "human_token_required"

        ok = await host.post(f"/api/rooms/{rid}/join", headers={
            **_auth(b), "X-Session-Key": "human-b"},
            json={"kind": "human", "role": "human",
                  "session_key": "human-b", "assignment_id": aid})
        assert ok.status_code == 200, ok.text
