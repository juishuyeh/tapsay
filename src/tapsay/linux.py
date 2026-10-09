"""Linux 專用：Wayland 偵測、GNOME 自訂快捷鍵、Wayland 下的自動貼上。

Wayland 基於安全設計，一般程式**收不到全域按鍵、也不能模擬按鍵**（pynput 只看得到
XWayland 視窗）。所以 Wayland 下改成：
- 快捷鍵：交給桌面環境，綁定指令 `tapsay --toggle`（GNOME 可由 TapSay 代為設定）
- 自動貼上：借用 ydotool / wtype；都沒有就只寫進剪貼簿
"""

from __future__ import annotations

import ast
import os
import shlex
import shutil
import subprocess
import sys

IS_LINUX = sys.platform.startswith("linux")

GNOME_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
GNOME_PATH = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/tapsay/"


def is_wayland() -> bool:
    if not IS_LINUX:
        return False
    if os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland":
        return True
    return bool(os.environ.get("WAYLAND_DISPLAY"))


def is_gnome() -> bool:
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "") + ":" + os.environ.get("DESKTOP_SESSION", "")
    return "gnome" in desktop.lower() or "ubuntu" in desktop.lower()


# ---- tapsay --toggle 的完整指令 ----


def toggle_command() -> list[str]:
    """給桌面環境快捷鍵用的指令。打包版是執行檔本身，跑原始碼時是 python -m tapsay。"""
    if getattr(sys, "frozen", False):
        return [sys.executable, "--toggle"]
    return [sys.executable, "-m", "tapsay", "--toggle"]


# ---- pynput 格式 → GNOME 格式 ----

_MODIFIERS = {
    "ctrl": "<Control>",
    "ctrl_l": "<Control>",
    "ctrl_r": "<Control>",
    "alt": "<Alt>",
    "alt_l": "<Alt>",
    "alt_r": "<Alt>",
    "alt_gr": "<Alt>",
    "shift": "<Shift>",
    "shift_l": "<Shift>",
    "shift_r": "<Shift>",
    "cmd": "<Super>",
    "cmd_l": "<Super>",
    "cmd_r": "<Super>",
}
_KEYS = {
    "space": "space",
    "enter": "Return",
    "tab": "Tab",
    "esc": "Escape",
    "backspace": "BackSpace",
    "delete": "Delete",
    "insert": "Insert",
    "home": "Home",
    "end": "End",
    "page_up": "Page_Up",
    "page_down": "Page_Down",
    "up": "Up",
    "down": "Down",
    "left": "Left",
    "right": "Right",
    "pause": "Pause",
    "print_screen": "Print",
    "scroll_lock": "Scroll_Lock",
    "menu": "Menu",
}


def to_gnome_binding(combo: str) -> str:
    """'<ctrl>+<alt>+<space>' -> '<Control><Alt>space'。不支援的格式丟 ValueError。"""
    combo = (combo or "").strip()
    if combo.startswith("double:"):
        raise ValueError("Wayland 下不支援連擊快捷鍵（double:），請改用組合鍵，例如 <ctrl>+<alt>+<space>")
    mods: list[str] = []
    key = ""
    for part in (p.strip() for p in combo.split("+")):
        if not part:
            raise ValueError(f"快捷鍵格式不正確：{combo}")
        name = part[1:-1].lower() if part.startswith("<") and part.endswith(">") else part
        if name in _MODIFIERS:
            if _MODIFIERS[name] not in mods:
                mods.append(_MODIFIERS[name])
            continue
        if key:
            raise ValueError(f"快捷鍵只能有一個主要按鍵：{combo}")
        if name in _KEYS:
            key = _KEYS[name]
        elif len(name) >= 2 and name[0] == "f" and name[1:].isdigit():
            key = name.upper()
        elif len(name) == 1:
            key = name.lower()
        else:
            raise ValueError(f"不認得的按鍵：{part}")
    if not key:
        raise ValueError(f"快捷鍵缺少主要按鍵：{combo}")
    return "".join(mods) + key


# ---- GNOME 自訂快捷鍵（gsettings） ----


def _gsettings(*args: str) -> str:
    if not shutil.which("gsettings"):
        raise RuntimeError("找不到 gsettings（不是 GNOME 桌面？）")
    proc = subprocess.run(["gsettings", *args], capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"gsettings {' '.join(args)} 失敗")
    return proc.stdout.strip()


def _parse_gvariant_strings(text: str) -> list[str]:
    """gsettings 回傳的字串陣列，例如 "@as []" 或 "['/a/', '/b/']"。"""
    text = text.strip()
    if text.startswith("@as"):
        text = text[3:].strip()
    try:
        value = ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return []
    return [str(v) for v in value] if isinstance(value, (list, tuple)) else []


def _gvariant_strings(items: list[str]) -> str:
    return "[" + ", ".join("'" + i.replace("\\", "\\\\").replace("'", "\\'") + "'" for i in items) + "]"


def gnome_shortcut_installed() -> bool:
    try:
        paths = _parse_gvariant_strings(_gsettings("get", GNOME_SCHEMA, "custom-keybindings"))
    except Exception:
        return False
    return GNOME_PATH in paths


def install_gnome_shortcut(combo: str) -> str:
    """在 GNOME「設定 → 鍵盤 → 自訂快捷鍵」加一筆 TapSay，已存在就更新。回傳 GNOME 格式的按鍵。"""
    binding = to_gnome_binding(combo)
    schema = f"{GNOME_SCHEMA}.custom-keybinding:{GNOME_PATH}"
    _gsettings("set", schema, "name", "TapSay")
    _gsettings("set", schema, "command", shlex.join(toggle_command()))
    _gsettings("set", schema, "binding", binding)
    paths = _parse_gvariant_strings(_gsettings("get", GNOME_SCHEMA, "custom-keybindings"))
    if GNOME_PATH not in paths:
        _gsettings("set", GNOME_SCHEMA, "custom-keybindings", _gvariant_strings(paths + [GNOME_PATH]))
    return binding


# ---- Wayland 下的自動貼上 ----


def paste_wayland() -> None:
    """送出 Ctrl+V。依序嘗試 ydotool（任何桌面，需 ydotoold）與 wtype（wlroots / KDE，GNOME 不支援）。"""
    attempts = []
    if shutil.which("ydotool"):
        # Linux input event codes：KEY_LEFTCTRL=29、KEY_V=47
        attempts.append(["ydotool", "key", "29:1", "47:1", "47:0", "29:0"])
    if shutil.which("wtype"):
        attempts.append(["wtype", "-M", "ctrl", "v", "-m", "ctrl"])
    if not attempts:
        raise RuntimeError("Wayland 下自動貼上需要 ydotool（或 wtype）")
    errors = []
    for cmd in attempts:
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        except Exception as exc:
            errors.append(f"{cmd[0]}: {exc}")
            continue
        if proc.returncode == 0:
            return
        errors.append(f"{cmd[0]}: {(proc.stderr or proc.stdout).strip()[:120] or proc.returncode}")
    raise RuntimeError("；".join(errors))


def notify_send(message: str, title: str) -> bool:
    if not shutil.which("notify-send"):
        return False
    try:
        subprocess.Popen(["notify-send", "--app-name=TapSay", title, message])
        return True
    except Exception:
        return False
