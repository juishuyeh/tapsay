import os
import stat
import subprocess
import sys

import pytest

from tapsay import ipc, linux


@pytest.mark.parametrize(
    ("combo", "expected"),
    [
        ("<ctrl>+<alt>+<space>", "<Control><Alt>space"),
        ("<cmd>+<shift>+h", "<Super><Shift>h"),
        ("<ctrl_l>+<f9>", "<Control>F9"),
        ("<f12>", "F12"),
        ("<alt>+<enter>", "<Alt>Return"),
    ],
)
def test_to_gnome_binding(combo, expected):
    assert linux.to_gnome_binding(combo) == expected


@pytest.mark.parametrize("combo", ["double:<ctrl>", "", "<ctrl>+<alt>", "<ctrl>+a+b", "<ctrl>+<nope>"])
def test_to_gnome_binding_rejects(combo):
    with pytest.raises(ValueError):
        linux.to_gnome_binding(combo)


def test_parse_gvariant_strings():
    assert linux._parse_gvariant_strings("@as []") == []
    assert linux._parse_gvariant_strings("['/a/', '/b/']") == ["/a/", "/b/"]
    assert linux._parse_gvariant_strings(linux._gvariant_strings(["/x'y/"])) == ["/x'y/"]


def test_is_wayland(monkeypatch):
    monkeypatch.setattr(linux, "IS_LINUX", True)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.setenv("XDG_SESSION_TYPE", "x11")
    assert not linux.is_wayland()
    monkeypatch.setenv("XDG_SESSION_TYPE", "wayland")
    assert linux.is_wayland()


@pytest.fixture
def fake_gsettings(tmp_path, monkeypatch):
    """假的 gsettings：把設定存在一個檔案裡，記錄每次呼叫。"""
    store = tmp_path / "store"
    log = tmp_path / "log"
    script = tmp_path / "gsettings"
    script.write_text(
        f"""#!{sys.executable}
import json, sys
store, log = {str(store)!r}, {str(log)!r}
try:
    data = json.load(open(store))
except FileNotFoundError:
    data = {{}}
op, schema, key, *rest = sys.argv[1:]
open(log, "a").write(" ".join(sys.argv[1:]) + "\\n")
if op == "get":
    print(data.get(schema + "/" + key, "@as []"))
else:
    data[schema + "/" + key] = rest[0]
    json.dump(data, open(store, "w"))
"""
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")
    return log


def test_install_gnome_shortcut(fake_gsettings):
    assert not linux.gnome_shortcut_installed()
    assert linux.install_gnome_shortcut("<ctrl>+<alt>+<space>") == "<Control><Alt>space"
    assert linux.gnome_shortcut_installed()
    log = fake_gsettings.read_text()
    assert "binding <Control><Alt>space" in log
    assert "--toggle" in log
    # 再裝一次只更新，不會重複加入清單
    linux.install_gnome_shortcut("<ctrl>+<f9>")
    lists = [l for l in fake_gsettings.read_text().splitlines() if l.startswith("set") and "custom-keybindings [" in l]
    assert len(lists) == 1


@pytest.fixture
def sock(tmp_path, monkeypatch):
    path = tmp_path / "t.sock"
    monkeypatch.setenv("TAPSAY_SOCKET", str(path))
    return path


def test_ipc_roundtrip(sock):
    calls = []
    server = ipc.Server({"toggle": lambda: calls.append(1)})
    server.start()
    try:
        assert ipc.send("ping") == "pong"
        assert ipc.send("toggle") == "ok"
        assert ipc.send("nope") == "unknown command"
        assert calls == [1]
        assert stat.S_IMODE(os.stat(sock).st_mode) & 0o077 == 0  # 只有自己能連
        with pytest.raises(ipc.AlreadyRunning):
            ipc.Server({}).start()
    finally:
        server.stop()
    assert not sock.exists()
    with pytest.raises(ConnectionError):
        ipc.send("ping")


def test_ipc_replaces_stale_socket(sock):
    import socket

    stale = socket.socket(socket.AF_UNIX)
    stale.bind(str(sock))
    stale.close()  # 檔案還在，但沒人在聽
    server = ipc.Server({})
    server.start()
    try:
        assert ipc.send("ping") == "pong"
    finally:
        server.stop()


def test_toggle_cli_without_instance(sock):
    env = {**os.environ, "TAPSAY_SOCKET": str(sock), "PATH": "/usr/bin:/bin"}
    proc = subprocess.run([sys.executable, "-m", "tapsay", "--toggle"], env=env, capture_output=True, text=True)
    assert proc.returncode == 1
    assert "沒有在執行" in proc.stderr
