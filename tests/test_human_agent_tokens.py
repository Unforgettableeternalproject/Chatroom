"""人類／agent 分離憑證的**遷移段**（09/07 卡 d1141898，決策裁 #16-2）。

要害只有一個：**擴權不能掛在一把所有 agent 都拿得到的鑰匙上。**

`X-Host-View` 與 `role=human` 是 Hub 裡兩個「我是人」的宣稱，而 bridge 用的
就是 `.env` 那把主 token——只看 token 的話，每一個 agent 都宣稱得了。09/07 的
主持人擴權卡（a03fa6e8）會讓這件事更貴，所以先把憑證分開。

**遷移期的形狀**：`CHATROOM_HUMAN_TOKEN` 沒設＝還沒進入分離期，一切照舊
（舊單一 token 視同 agent，但仍當得了主持人）。設了才開始嚴格。理由是舊 kit
還在外面跑，而一個「升級 Hub 就讓所有人被擋在門外」的改動沒有人會預期。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


async def _client(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def _host_view_flag(client, token: str = ROOT):
    """list_rooms 的 `host_view`——「此刻是不是用主持人視角在看」。"""
    return await client.get("/api/rooms",
                            headers={**_auth(token), "X-Host-View": "1"})


# ---------- 遷移期：沒設 human token 就一切照舊 ----------

async def test_without_a_human_token_the_old_single_token_still_hosts(tmp_path):
    """升級 Hub 不該把主持人自己關在門外。"""
    app, client = await _client(tmp_path, "compat-host")
    async with app.router.lifespan_context(app), client:
        r = await _host_view_flag(client)
        assert r.status_code == 200, r.text
        assert r.json()["host_view"] is True


async def test_without_a_human_token_role_human_still_joins(tmp_path):
    """App 目前就是拿主 token 以 role=human 進房的。"""
    app, client = await _client(tmp_path, "compat-role")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={"name": "房", "session_key": "human-1"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "Bernie"})
        assert r.status_code == 200, r.text


# ---------- 分離期：設了 human token 之後 ----------

async def test_an_agent_token_cannot_switch_to_host_view(tmp_path):
    """主 token 是 bridge 手上那把。它宣稱得了「我是主持人」的話，
    分離憑證就沒有意義了。"""
    app, client = await _client(tmp_path, "split-host", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        r = await _host_view_flag(client)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_token_required"


async def test_the_human_token_can_switch_to_host_view(tmp_path):
    app, client = await _client(tmp_path, "split-host-ok", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        r = await _host_view_flag(client, HUMAN)
        assert r.status_code == 200, r.text
        assert r.json()["host_view"] is True


async def test_an_agent_token_cannot_claim_to_be_human(tmp_path):
    """`role=human` 決定的不只是圖示：人類在板上、在封存規則裡、在完成
    別人的卡時都有額外的份量。"""
    app, client = await _client(tmp_path, "split-role", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={"name": "房", "session_key": "human-1"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "Bernie"})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_token_required"


async def test_the_human_token_joins_as_human(tmp_path):
    app, client = await _client(tmp_path, "split-role-ok", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={"name": "房", "session_key": "human-1"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join",
                              headers=_auth(HUMAN), json={
                                  "kind": "human", "role": "human",
                                  "session_key": "human-1",
                                  "preferred_name": "Bernie"})
        assert r.status_code == 200, r.text


async def test_an_agent_token_still_joins_as_an_agent(tmp_path):
    """分離憑證擋的是**冒充**，不是進門。"""
    app, client = await _client(tmp_path, "split-agent", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={"name": "房", "session_key": "human-1"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "claude-1",
            "preferred_name": "Novia"})
        assert r.status_code == 200, r.text


# ---------- 發出去的 token 也要分 ----------

async def test_an_invite_can_be_issued_for_a_human(tmp_path):
    """邀請別人的人類進來時，發的那張要是人類憑證——否則對方一樣冒充不了
    自己。"""
    app, client = await _client(tmp_path, "invite-human", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        issued = await client.post("/api/tokens", headers=_auth(HUMAN),
                                   json={"label": "艾斯維爾的手機",
                                         "audience": "human"})
        assert issued.status_code == 200, issued.text
        token = issued.json()["token"]
        assert issued.json()["audience"] == "human"
        r = await _host_view_flag(client, token)
        assert r.status_code == 200, r.text
        assert r.json()["host_view"] is True


async def test_invites_default_to_agent(tmp_path):
    """沒講的話一律是 agent。**舊 kit 發過的那些沒有這一欄**，而把它們
    當成人類等於把整個機制的預設方向弄反。"""
    app, client = await _client(tmp_path, "invite-default", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        issued = await client.post("/api/tokens", headers=_auth(HUMAN),
                                   json={"label": "某個 agent"})
        assert issued.json()["audience"] == "agent"
        r = await _host_view_flag(client, issued.json()["token"])
        assert r.status_code == 403, r.text


async def test_only_a_human_token_may_issue_invites(tmp_path):
    """發 token 是主持人的權力。分離之後那也是人類那一側的事。"""
    app, client = await _client(tmp_path, "invite-perm", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/tokens", json={"label": "自己發給自己"})
        assert r.status_code == 403, r.text


# ---------- 開放模式（本機開發）不受影響 ----------

async def test_an_open_hub_is_still_open(tmp_path):
    """沒設任何 token＝本機開發，這時人人都是主持人（既有語意）。"""
    cfg = Config(db_path=str(tmp_path / "open.db"), api_token="")
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/rooms", headers={"X-Host-View": "1"})
        assert r.status_code == 200, r.text
        assert r.json()["host_view"] is True


# ---------- 從外部看得出自己在哪個模式 ----------

async def test_health_says_which_credential_mode_it_is_in(tmp_path):
    """漏設 human token 的失敗模式是「所有防護都不生效、而且不報錯」。

    測試Novia 09/07 提：相容期本身就是靜默失效的形狀，所以模式必須從外部
    查得到——否則沒有人知道正式站到底進沒進分離期，只能靠翻 `.env`。
    """
    app, client = await _client(tmp_path, "mode-legacy")
    async with app.router.lifespan_context(app), client:
        assert (await client.get("/api/health")).json()["credential_mode"] \
            == "legacy"

    app, client = await _client(tmp_path, "mode-split", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        assert (await client.get("/api/health")).json()["credential_mode"] \
            == "split"


async def test_health_does_not_leak_the_token_itself(tmp_path):
    """`/api/health` 不需要 token 就打得到——它只能說模式，不能說鑰匙。"""
    app, client = await _client(tmp_path, "mode-no-leak", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        body = (await client.get("/api/health")).text
        assert HUMAN not in body and ROOT not in body


# ---------- you_are_host：開關要畫給真正按得動的人 ----------

async def _you_are_host(client, token: str):
    r = await client.get("/api/rooms", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()["you_are_host"]


async def test_the_host_switch_is_shown_to_whoever_can_actually_use_it(tmp_path):
    """`you_are_host` 決定 App 畫不畫主持人開關，`host_view` 決定按下去有沒有
    用——**兩者必須對同一件事說話**。

    分離憑證之後它們一度相反：主 token 拿到開關卻按不動（403），人類憑證按得動
    卻沒有開關。畫一個永遠按不動的開關比不畫更難懂，而「該有的人看不到」根本
    無從發現。
    """
    app, client = await _client(tmp_path, "switch-split", human_api_token=HUMAN)
    async with app.router.lifespan_context(app), client:
        assert await _you_are_host(client, HUMAN) is True
        assert await _you_are_host(client, ROOT) is False
        invite = (await client.post("/api/tokens", headers=_auth(HUMAN),
                                    json={"label": "App",
                                          "audience": "human"})).json()["token"]
        assert await _you_are_host(client, invite) is True


async def test_before_the_split_the_main_token_still_owns_the_switch(tmp_path):
    """相容期照舊：那時能開主持人模式的就是主 token。"""
    app, client = await _client(tmp_path, "switch-legacy")
    async with app.router.lifespan_context(app), client:
        assert await _you_are_host(client, ROOT) is True


async def test_a_human_invite_works_before_the_split_too(tmp_path):
    """**同一張 `audience=human` 的邀請在兩種模式下都要能用。**

    這是換版時唯一沒有斷線視窗的路（@開發Novia (除錯) 09/07）：先發這張、
    App 換上，之後 Hub 何時進入分離期都不影響。legacy 下 `audience` 根本
    沒被讀到——但「沒被讀到所以不影響」是推理，這條把它變成事實。
    """
    app, client = await _client(tmp_path, "invite-legacy")
    async with app.router.lifespan_context(app), client:
        invite = (await client.post("/api/tokens",
                                    json={"label": "Bernie 的 App",
                                          "audience": "human"})).json()["token"]
        rid = (await client.post("/api/rooms", headers=_auth(invite),
                                 json={"name": "房",
                                       "session_key": "human-1"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join", headers=_auth(invite),
                              json={"kind": "human", "role": "human",
                                    "session_key": "human-1",
                                    "preferred_name": "Bernie"})
        assert r.status_code == 200, r.text
