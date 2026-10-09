"""System Tray / macOS Menu Bar 圖示，同時作為狀態指示。"""

from __future__ import annotations

import subprocess
import sys
import threading

import pystray
from PIL import Image, ImageDraw

from . import hotkey, ipc, linux, notify
from .app import ERROR, IDLE, PROCESSING, RECORDING, SUCCESS, TapSay

COLORS = {
    IDLE: (130, 130, 130),
    RECORDING: (225, 60, 60),
    PROCESSING: (235, 170, 40),
    SUCCESS: (70, 180, 90),
    ERROR: (225, 60, 60),
}
LABELS = {
    IDLE: "TapSay — 待命",
    RECORDING: "TapSay — ● 錄音中",
    PROCESSING: "TapSay — 處理中…",
    SUCCESS: "TapSay — 完成",
    ERROR: "TapSay — 錯誤",
}


def _icon_image(color: tuple[int, int, int]) -> Image.Image:
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse((10, 10, size - 10, size - 10), fill=color + (255,))
    return img


_IMAGES = {state: _icon_image(color) for state, color in COLORS.items()}


def open_settings(app: TapSay) -> None:
    """設定視窗用獨立行程開，避免 tkinter 與 menu bar 搶主執行緒。"""

    # 打包成 .app / .exe 之後 sys.executable 就是程式本身，不能用 -m
    if getattr(sys, "frozen", False):
        cmd = [sys.executable, "--settings"]
    else:
        cmd = [sys.executable, "-m", "tapsay.ui"]

    def run() -> None:
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True)
        except Exception as exc:
            notify.notify(f"無法開啟設定視窗：{exc}")
            return
        if proc.returncode != 0:
            # 打包版沒有主控台，子行程的錯誤只能靠通知講出來，否則使用者只會看到「沒反應」
            lines = (proc.stderr or "").strip().splitlines()
            reason = lines[-1][:120] if lines else f"exit {proc.returncode}"
            notify.notify(f"設定視窗開啟失敗：{reason}")
            return
        app.reload_config()

    threading.Thread(target=run, daemon=True).start()


def run() -> None:
    app = TapSay()
    try:
        app.start_ipc()
    except ipc.AlreadyRunning:
        notify.notify("TapSay 已經在執行了")
        print("[tapsay] 已經有一個 TapSay 在執行，這次不再啟動", file=sys.stderr)
        return

    menu_items = [
        pystray.MenuItem("開始 / 停止錄音", lambda: app.toggle()),
        pystray.MenuItem("設定…", lambda: open_settings(app)),
    ]
    if sys.platform == "darwin":
        menu_items.append(
            pystray.MenuItem("輔助使用權限…", lambda: hotkey.request_trust())
        )
    if linux.is_wayland() and linux.is_gnome():
        menu_items.append(
            pystray.MenuItem("設定系統快捷鍵（Wayland）", lambda: app.setup_system_shortcut())
        )
    menu_items.append(pystray.MenuItem("結束 TapSay", lambda: icon.stop()))

    icon = pystray.Icon(
        "tapsay",
        _IMAGES[IDLE],
        LABELS[IDLE],
        menu=pystray.Menu(*menu_items),
    )

    def on_state(state: str) -> None:
        icon.icon = _IMAGES.get(state, _IMAGES[IDLE])
        icon.title = LABELS.get(state, LABELS[IDLE])

    app.on_state = on_state
    if not linux.IS_LINUX:
        # Linux 的 AppIndicator 後端不一定支援通知，直接走 notify-send 比較可靠
        notify.set_notifier(lambda message, title: icon.notify(message, title))

    app.start_hotkey()
    print(f"[tapsay] 已啟動，快捷鍵 {app.config.get('hotkey', '')}")
    try:
        icon.run()
    finally:
        app.shutdown()
