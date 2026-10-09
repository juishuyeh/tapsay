"""TapSay — 按一下、說話、再按一下，整理好的文字出現在游標位置。"""

from __future__ import annotations

import sys

USAGE = """用法：tapsay [--settings | --toggle | --setup-shortcut | --no-tray]
  （無參數）        常駐執行，顯示 tray / menu bar 圖示
  --settings        只開啟設定視窗
  --toggle          讓執行中的 TapSay 開始 / 停止錄音（給桌面環境的快捷鍵用）
  --setup-shortcut  在 GNOME 設定快捷鍵，按下時執行 tapsay --toggle（Wayland 用）
  --no-tray         不顯示圖示，只註冊快捷鍵（除錯用）"""


def main() -> None:
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command in ("-h", "--help"):
        print(USAGE)
        return
    if command == "--settings":
        from .ui import run as run_settings

        run_settings()
        return
    if command == "--toggle":
        sys.exit(_toggle())
    if command == "--setup-shortcut":
        sys.exit(_setup_shortcut())
    if command == "--no-tray":
        _run_without_tray()
        return
    if command:
        print(f"不認得的參數：{command}\n\n{USAGE}", file=sys.stderr)
        sys.exit(2)

    from .tray import run as run_tray

    run_tray()


def _toggle() -> int:
    from . import ipc, notify

    try:
        reply = ipc.send("toggle")
    except ConnectionError as exc:
        # 通常是從桌面快捷鍵觸發的，沒有終端機可看，所以也跳通知
        notify.notify(f"{exc}，請先啟動 TapSay")
        print(f"[tapsay] {exc}", file=sys.stderr)
        return 1
    if reply != "ok":
        print(f"[tapsay] {reply}", file=sys.stderr)
        return 1
    return 0


def _setup_shortcut() -> int:
    from . import config, linux

    combo = config.load().get("hotkey", "")
    try:
        binding = linux.install_gnome_shortcut(combo)
    except Exception as exc:
        print(f"[tapsay] 設定失敗：{exc}", file=sys.stderr)
        return 1
    print(f"[tapsay] 已設定 GNOME 快捷鍵 {binding} → {' '.join(linux.toggle_command())}")
    return 0


def _run_without_tray() -> None:
    import threading

    from . import ipc
    from .app import TapSay

    app = TapSay()
    try:
        app.start_ipc()
    except ipc.AlreadyRunning as exc:
        print(f"[tapsay] {exc}", file=sys.stderr)
        sys.exit(1)
    app.start_hotkey()
    print(f"[tapsay] 已啟動（無 tray），快捷鍵 {app.config.get('hotkey')}，Ctrl+C 結束")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        app.shutdown()
