"""剪貼簿與自動貼上。順序永遠是先寫剪貼簿，再嘗試貼上。"""

from __future__ import annotations

import sys
import time

import pyperclip

from . import linux

_keyboard = None


def copy(text: str) -> None:
    try:
        pyperclip.copy(text)
    except Exception as exc:
        hint = ""
        if linux.IS_LINUX:
            hint = "（請安裝 wl-clipboard 或 xclip：sudo apt install wl-clipboard xclip）"
        raise RuntimeError(f"寫入剪貼簿失敗：{exc}{hint}") from exc


def paste() -> None:
    """對目前游標位置送出 Cmd+V / Ctrl+V。"""
    time.sleep(0.05)  # 等剪貼簿內容就緒
    if linux.is_wayland():
        # pynput 送的按鍵只有 XWayland 視窗收得到，原生 Wayland 視窗要靠外部工具
        linux.paste_wayland()
        return

    global _keyboard
    from pynput.keyboard import Controller, Key

    if _keyboard is None:
        _keyboard = Controller()
    modifier = Key.cmd if sys.platform == "darwin" else Key.ctrl
    try:
        with _keyboard.pressed(modifier):
            _keyboard.press("v")
            _keyboard.release("v")
    except Exception as exc:  # macOS 未授權輔助使用時會失敗
        raise RuntimeError(f"自動貼上失敗：{exc}") from exc
