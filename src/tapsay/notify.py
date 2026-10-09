"""極簡通知：有 tray 就用 tray 的原生通知，否則退回系統指令。"""

from __future__ import annotations

import subprocess
import sys

from .linux import notify_send

_notifier = None  # 由 tray 設定


def set_notifier(func) -> None:
    global _notifier
    _notifier = func


def notify(message: str, title: str = "TapSay") -> None:
    if _notifier is not None:
        try:
            _notifier(message, title)
            return
        except Exception:
            pass
    _fallback(message, title)


def _fallback(message: str, title: str) -> None:
    try:
        if sys.platform == "darwin":
            script = 'display notification "{}" with title "{}"'.format(
                message.replace("\\", "\\\\").replace('"', '\\"'),
                title.replace("\\", "\\\\").replace('"', '\\"'),
            )
            subprocess.Popen(["osascript", "-e", script])
        elif sys.platform.startswith("linux") and notify_send(message, title):
            pass
        else:
            print(f"[{title}] {message}", file=sys.stderr)
    except Exception:
        pass
