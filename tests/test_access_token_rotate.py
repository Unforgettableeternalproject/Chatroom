"""換發 token：舊的立刻失效、新的沿用同一個身分。

要釘住的是三件事：舊憑證真的被拒（且訊息講得出原因）、身分（label／
audience／群）不變、只有 root 能換。
"""

import hashlib

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

ROOT = "root-secret"
pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


async def _issue(client, **body):
    r = await client.post("/api/tokens", json=body, headers=_auth(ROOT))
    assert r.status_code == 200, r.text
    return r.json()


async def test_old_token_rejected_new_token_works(tmp_path):
    app, client = await _make(tmp_path, "swap")
    async with app.router.lifespan_context(app), client:
        old = (await _issue(client, label="戴爾", audience="human"))["token"]
        assert (await client.get("/api/rooms", headers=_auth(old))).status_code == 200

        r = await client.post(f"/api/tokens/{old}/rotate", headers=_auth(ROOT))
        assert r.status_code == 200, r.text
        new = r.json()["token"]
        assert new != old

        r = await client.get("/api/rooms", headers=_auth(old))
        assert r.status_code == 401
        assert r.json()["detail"]["code"] == "invalid_token"
        # 被換掉的跟亂填的要講得不一樣：前者持有者該做的是找主持人
        assert "撤銷或換發" in r.json()["detail"]["message"]
        bad = await client.get("/api/rooms", headers=_auth("nope"))
        assert "撤銷或換發" not in bad.json()["detail"]["message"]

        assert (await client.get("/api/rooms", headers=_auth(new))).status_code == 200


async def test_identity_is_kept(tmp_path):
    app, client = await _make(tmp_path, "identity")
    async with app.router.lifespan_context(app), client:
        old = (await _issue(client, label="米勒", audience="human"))["token"]
        # 沒有存 party 的 token，群 id 是 hash 推出來的——換 token 不能讓它變成別人
        expected_party = "p:" + hashlib.sha256(old.encode()).hexdigest()[:16]

        r = await client.post(f"/api/tokens/{old}/rotate", headers=_auth(ROOT))
        body = r.json()
        assert body["label"] == "米勒"
        assert body["audience"] == "human"
        assert body["party"] == expected_party

        rows = (await client.get("/api/tokens", headers=_auth(ROOT))).json()["tokens"]
        assert [x["token"] for x in rows] == [body["token"]]
        assert rows[0]["label"] == "米勒" and rows[0]["audience"] == "human"
        assert rows[0]["party"] == expected_party

        # 舊列不刪（留紀錄）
        allrows = (await client.get("/api/tokens", params={"include_revoked": True},
                                    headers=_auth(ROOT))).json()["tokens"]
        gone = next(x for x in allrows if x["token"] == old)
        assert gone["revoked"] is True


async def test_agent_child_stays_in_the_same_party(tmp_path):
    app, client = await _make(tmp_path, "child")
    async with app.router.lifespan_context(app), client:
        parent = (await _issue(client, label="p", audience="human"))["token"]
        child = await _issue(client, label="p agent", audience="agent",
                             parent_token=parent)

        # 加發的 agent 憑證也能換，且不離開原本那一群
        r = await client.post(f"/api/tokens/{child['token']}/rotate",
                              headers=_auth(ROOT))
        assert r.status_code == 200, r.text
        assert r.json()["audience"] == "agent"
        assert r.json()["party"] == child["party"]

        # 換母張也不影響子張的群
        r = await client.post(f"/api/tokens/{parent}/rotate", headers=_auth(ROOT))
        assert r.json()["party"] == child["party"]


async def test_rotate_unknown_or_revoked_is_404(tmp_path):
    app, client = await _make(tmp_path, "missing")
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/tokens/nope/rotate", headers=_auth(ROOT))
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "token_not_found"

        t = (await _issue(client, label="x"))["token"]
        await client.delete(f"/api/tokens/{t}", headers=_auth(ROOT))
        r = await client.post(f"/api/tokens/{t}/rotate", headers=_auth(ROOT))
        assert r.status_code == 404


async def test_non_root_cannot_rotate(tmp_path):
    app, client = await _make(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        guest = (await _issue(client, label="g"))["token"]
        victim = (await _issue(client, label="v"))["token"]

        # 連自己的也不行：被撤掉的人能自己換一張新的，撤銷就形同虛設
        for target in (victim, guest):
            r = await client.post(f"/api/tokens/{target}/rotate",
                                  headers=_auth(guest))
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "root_token_required"

        # 沒被換掉
        assert (await client.get("/api/rooms", headers=_auth(victim))).status_code == 200
        assert (await client.get("/api/rooms", headers=_auth(guest))).status_code == 200


async def test_joined_member_kept_and_kick_revokes_new_token(tmp_path):
    app, client = await _make(tmp_path, "kick")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", headers=_auth(ROOT),
            json={"name": "房", "session_key": "admin-key"})).json()["id"]
        admin = (await client.post(
            f"/api/rooms/{room_id}/join", headers=_auth(ROOT),
            json={"kind": "human", "session_key": "admin-key",
                  "preferred_name": "Xavier", "role": "human"})).json()
        old = (await _issue(client, label="訪客", audience="human"))["token"]
        guest = (await client.post(
            f"/api/rooms/{room_id}/join", headers=_auth(old),
            json={"kind": "human", "session_key": "human-aaa",
                  "preferred_name": "Guest", "role": "human"})).json()

        new = (await client.post(f"/api/tokens/{old}/rotate",
                                 headers=_auth(ROOT))).json()["token"]

        # 成員紀錄還在，換上新憑證後仍是同一個人
        members = (await client.get(f"/api/rooms/{room_id}",
                                    headers={**_auth(new), "X-Participant-Id": guest["participant_id"]})).json()
        assert "participants" in members, members
        listed = members["participants"]
        assert any(m["id"] == guest["participant_id"] for m in listed)

        # 踢出要撤到新的那張，不是已經作廢的舊張
        r = await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers={**_auth(ROOT), "X-Participant-Id": admin["participant_id"]})
        assert r.status_code == 200, r.text
        assert r.json()["access_still_open"] is False
        assert (await client.get("/api/rooms", headers=_auth(new))).status_code == 401
