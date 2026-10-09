"""讓 `tapsay --toggle` 通知已經在執行的 TapSay（Unix domain socket，僅 macOS / Linux）。

用途：
- Wayland 收不到全域按鍵，改由桌面環境的快捷鍵執行 `tapsay --toggle`
- 順便防止重複啟動（開機自動啟動 + 手動再開一次）
"""

from __future__ import annotations

import os
import socket
import tempfile
import threading
from pathlib import Path

SUPPORTED = os.name == "posix" and hasattr(socket, "AF_UNIX")
TIMEOUT = 2.0


class AlreadyRunning(RuntimeError):
    pass


def socket_path() -> Path:
    override = os.environ.get("TAPSAY_SOCKET")
    if override:
        return Path(override)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime and os.path.isdir(runtime):
        return Path(runtime) / "tapsay.sock"
    # macOS 與沒有 XDG_RUNTIME_DIR 的環境：放在只有自己能讀的暫存資料夾
    return Path(tempfile.gettempdir()) / f"tapsay-{os.getuid()}" / "tapsay.sock"


def send(command: str) -> str:
    """送指令給執行中的 TapSay，回傳回應。沒有在執行時丟 ConnectionError。"""
    if not SUPPORTED:
        raise ConnectionError("這個平台不支援 --toggle")
    path = socket_path()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(TIMEOUT)
            sock.connect(str(path))
            sock.sendall(command.encode("utf-8") + b"\n")
            sock.shutdown(socket.SHUT_WR)
            return _read_all(sock).decode("utf-8", "replace").strip()
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        raise ConnectionError("TapSay 沒有在執行") from exc
    except OSError as exc:
        raise ConnectionError(f"無法連線到 TapSay：{exc}") from exc


def _read_all(sock: socket.socket) -> bytes:
    chunks = []
    while True:
        data = sock.recv(4096)
        if not data:
            return b"".join(chunks)
        chunks.append(data)


class Server:
    """在背景執行緒接受指令。handlers: {"toggle": callable}，回傳值（字串）會送回去。"""

    def __init__(self, handlers: dict) -> None:
        self.handlers = {"ping": lambda: "pong", **handlers}
        self.path: Path | None = None  # Windows 沒有 os.getuid()，所以到 start() 才決定
        self._sock: socket.socket | None = None

    def start(self) -> None:
        if not SUPPORTED:
            return
        self.path = socket_path()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.path.exists():
            try:
                send("ping")
            except ConnectionError:
                self.path.unlink(missing_ok=True)  # 上次沒正常結束留下的
            else:
                raise AlreadyRunning("TapSay 已經在執行")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old_umask = os.umask(0o177)  # socket 只有自己能連
        try:
            sock.bind(str(self.path))
        finally:
            os.umask(old_umask)
        sock.listen(4)
        self._sock = sock
        threading.Thread(target=self._serve, daemon=True).start()

    def stop(self) -> None:
        sock, self._sock = self._sock, None
        if sock is None:
            return
        try:
            sock.close()
        finally:
            if self.path is not None:
                self.path.unlink(missing_ok=True)

    def _serve(self) -> None:
        while self._sock is not None:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return  # stop() 關掉了
            with conn:
                try:
                    conn.settimeout(TIMEOUT)
                    command = _read_all(conn).decode("utf-8", "replace").strip()
                    handler = self.handlers.get(command)
                    reply = "unknown command" if handler is None else (handler() or "ok")
                    conn.sendall(str(reply).encode("utf-8") + b"\n")
                except Exception as exc:  # 單一連線出錯不能讓伺服器停掉
                    try:
                        conn.sendall(f"error: {exc}\n".encode("utf-8"))
                    except OSError:
                        pass
