"""附件下載落點：每個附件一個資料夾，不互相覆蓋。

附件的檔名是上傳者取的，而 `screenshot.png` 這種名字每個人都在用。全部堆進
同一個目錄時，後下載的會**無聲蓋掉**先下載的——agent 拿著一條正確的路徑，
讀到的卻是別人的圖，而且沒有任何地方會報錯。
"""

from pathlib import Path

import httpx
import pytest

from chatroom_mcp import server as srv


def _serve(fake_hub, attachment_id, filename, content, room_id="room-a"):
    fake_hub.json(
        "GET",
        f"/api/attachments/{attachment_id}/meta",
        {"attachment": {"id": attachment_id, "filename": filename,
                        "mime": "image/png", "is_image": True}},
    )
    fake_hub.on(
        "GET",
        f"/api/attachments/{attachment_id}",
        httpx.Response(200, content=content),
    )
    fake_hub.json(
        "POST", f"/api/rooms/{room_id}/join",
        {"participant_id": "pid-a", "display_name": "Aster", "rejoined": False},
    )
    srv.chatroom_join(room_id)


@pytest.fixture
def downloads(tmp_path, monkeypatch):
    monkeypatch.setenv("CHATROOM_DOWNLOAD_DIR", str(tmp_path / "dl"))
    return tmp_path / "dl"


def test_same_filename_from_two_attachments_does_not_clobber(fake_hub, downloads):
    _serve(fake_hub, "att1", "screenshot.png", b"first")
    _serve(fake_hub, "att2", "screenshot.png", b"second")

    a = srv.chatroom_get_file("att1", room_id="room-a")
    b = srv.chatroom_get_file("att2", room_id="room-a")

    assert a["ok"] is True and b["ok"] is True
    assert a["path"] != b["path"]
    with open(a["path"], "rb") as fh:
        assert fh.read() == b"first"
    with open(b["path"], "rb") as fh:
        assert fh.read() == b"second"


def test_default_path_is_scoped_by_room_and_attachment(fake_hub, downloads):
    _serve(fake_hub, "att1", "report.txt", b"x")
    result = srv.chatroom_get_file("att1", room_id="room-a")
    relative = str(downloads / "room-a" / "att1" / "report.txt")
    assert result["path"] == relative
    assert result["dir"] == str(downloads / "room-a" / "att1")


def test_explicit_save_dir_is_respected_but_never_overwrites(
    fake_hub, downloads, tmp_path
):
    _serve(fake_hub, "att1", "a.png", b"one")
    _serve(fake_hub, "att2", "a.png", b"two")
    target = tmp_path / "mine"

    first = srv.chatroom_get_file("att1", room_id="room-a", save_dir=str(target))
    second = srv.chatroom_get_file("att2", room_id="room-a", save_dir=str(target))

    assert first["path"] == str(target / "a.png")
    assert second["path"] == str(target / "a (2).png")
    with open(first["path"], "rb") as fh:
        assert fh.read() == b"one"


def test_hostile_filename_cannot_escape_the_download_folder(fake_hub, downloads):
    """檔名是別的 agent 給的字串，不能拿去組路徑。"""
    _serve(fake_hub, "att1", "../../evil.sh", b"payload")
    result = srv.chatroom_get_file("att1", room_id="room-a")
    assert result["path"] == str(downloads / "room-a" / "att1" / "evil.sh")
    assert not (downloads.parent / "evil.sh").exists()


def test_empty_filename_falls_back_to_the_attachment_id(fake_hub, downloads):
    _serve(fake_hub, "att1", "", b"x")
    result = srv.chatroom_get_file("att1", room_id="room-a")
    assert result["path"].endswith("att1")


def test_dot_dot_only_filename_falls_back(fake_hub, downloads):
    """`Path("..").name` 是 `".."`——它會通過 basename，但不是合法檔名。"""
    _serve(fake_hub, "att1", "..", b"x")
    result = srv.chatroom_get_file("att1", room_id="room-a")
    assert result["path"] == str(downloads / "room-a" / "att1" / "att1")


def test_default_root_is_under_the_working_directory(fake_hub, tmp_path,
                                                     monkeypatch):
    """沒有覆寫時落在**專案裡**，不是家目錄。

    agent 是在自己的專案裡工作的，檔案讀取工具的範圍也是那個專案。存到家
    目錄等於把檔案放在它多半讀不到的地方——路徑給了、打不開，而錯誤看起來
    像檔案根本不存在。
    """
    monkeypatch.delenv("CHATROOM_DOWNLOAD_DIR", raising=False)
    project = tmp_path / "some-project"
    project.mkdir()
    monkeypatch.chdir(project)

    _serve(fake_hub, "att1", "note.txt", b"x")
    result = srv.chatroom_get_file("att1", room_id="room-a")

    assert result["path"] == str(
        project / ".chatroom" / "downloads" / "room-a" / "att1" / "note.txt"
    )


def test_unwritable_working_directory_falls_back_to_home(
    fake_hub, tmp_path, monkeypatch
):
    """工作目錄不可寫時仍然要拿得到檔案。

    agent 要的是檔案，不是一堂關於它被啟動在哪個目錄的課。
    """
    monkeypatch.delenv("CHATROOM_DOWNLOAD_DIR", raising=False)
    # 用「父層是一個檔案」來製造不可寫的落點：在檔案底下 mkdir 在各平台
    # 都會拋 OSError。原本寫死 /proc/... 只在 POSIX 成立——Windows 上那是
    # 一條合法的相對根路徑，測試會真的把目錄建到 C:\proc 底下並通過 mkdir
    blocked = tmp_path / "blocked"
    blocked.write_bytes(b"")
    monkeypatch.setattr(
        srv, "_download_root", lambda: blocked / "downloads"
    )
    home = tmp_path / "home-downloads"
    monkeypatch.setattr(srv, "_fallback_download_root", lambda: home)

    _serve(fake_hub, "att1", "note.txt", b"x")
    result = srv.chatroom_get_file("att1", room_id="room-a")

    assert result["path"] == str(home / "room-a" / "att1" / "note.txt")
