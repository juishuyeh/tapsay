"""核心流程：Hotkey -> Record -> STT -> LLM -> Clipboard -> Paste。"""

from __future__ import annotations

import shlex
import threading
import time

from . import api, config, ipc, linux, notify, paste
from . import hotkey as hotkey_mod
from .recorder import Recorder, RecorderError

IDLE = "idle"
RECORDING = "recording"
PROCESSING = "processing"
SUCCESS = "success"
ERROR = "error"


class TapSay:
    def __init__(self) -> None:
        self.config = config.load()
        api.set_ca_bundle(self.config.get("ca_bundle", ""))
        api.set_insecure_ssl(self.config.get("insecure_ssl", False))
        self.recorder = Recorder()
        self.state = IDLE
        self.on_state = lambda state: None  # 由 tray 覆寫
        self._lock = threading.Lock()
        self._hotkey = None
        self._ipc: ipc.Server | None = None

    # ---- 狀態 ----

    def _set_state(self, state: str, message: str | None = None) -> None:
        self.state = state
        try:
            self.on_state(state)
        except Exception:
            pass
        if message:
            notify.notify(message)

    def _flash_back_to_idle(self, from_state: str, delay: float) -> None:
        def revert() -> None:
            if self.state == from_state:
                self._set_state(IDLE)

        timer = threading.Timer(delay, revert)
        timer.daemon = True
        timer.start()

    # ---- 快捷鍵 ----

    def start_ipc(self) -> None:
        """讓 `tapsay --toggle` 能控制這個行程。已經有一份在跑時丟 ipc.AlreadyRunning。"""
        self._ipc = ipc.Server({"toggle": self.toggle})
        try:
            self._ipc.start()
        except ipc.AlreadyRunning:
            self._ipc = None
            raise
        except OSError as exc:  # 只是少了 --toggle，不影響主要功能
            self._ipc = None
            print(f"[tapsay] 無法建立 {ipc.socket_path()}：{exc}")

    def shutdown(self) -> None:
        self.recorder.cancel()
        if self._ipc is not None:
            self._ipc.stop()
            self._ipc = None

    def start_hotkey(self) -> None:
        combo = self.config.get("hotkey", "")
        if linux.is_wayland():
            self._start_wayland_hotkey(combo)
            return
        try:
            self._hotkey = hotkey_mod.create_listener(
                combo, self.toggle, int(self.config.get("double_tap_ms", 400))
            )
            self._hotkey.start()
        except Exception as exc:
            self._hotkey = None
            notify.notify(f"快捷鍵 {combo} 無法註冊：{exc}")
            return
        # macOS 沒有「輔助使用」權限時，pynput 不會報錯，只是永遠收不到按鍵，
        # 表現就是「快捷鍵沒反應」。所以這裡主動檢查並告訴使用者。
        if not hotkey_mod.is_trusted():
            notify.notify(
                f"快捷鍵 {combo} 需要「輔助使用」權限才會生效，"
                "請在系統設定中勾選 TapSay"
            )
            hotkey_mod.request_trust()
            self._watch_for_trust()

    def _start_wayland_hotkey(self, combo: str) -> None:
        """Wayland 收不到全域按鍵，改由桌面環境執行 `tapsay --toggle`。"""
        if linux.is_gnome() and linux.gnome_shortcut_installed():
            try:
                linux.install_gnome_shortcut(combo)  # 同步設定視窗改過的按鍵
            except Exception as exc:
                notify.notify(f"更新 GNOME 快捷鍵失敗：{exc}")
            return
        if linux.is_gnome():
            notify.notify("Wayland 下要由 GNOME 代為處理快捷鍵：請從圖示選單點「設定系統快捷鍵」")
        else:
            notify.notify(
                "Wayland 下收不到全域按鍵：請在桌面環境的快捷鍵設定綁定指令 "
                f"`{shlex.join(linux.toggle_command())}`"
            )

    def setup_system_shortcut(self) -> None:
        """選單「設定系統快捷鍵」：GNOME 直接寫入自訂快捷鍵。"""
        combo = self.config.get("hotkey", "")
        try:
            binding = linux.install_gnome_shortcut(combo)
        except Exception as exc:
            notify.notify(f"設定失敗：{exc}")
            return
        notify.notify(f"已在 GNOME 設定快捷鍵 {binding}，按下就會開始 / 停止錄音")

    def _watch_for_trust(self) -> None:
        """使用者在系統設定勾選之後自動把監聽器重開，不必叫他重啟程式。"""

        def poll() -> None:
            for _ in range(300):  # 最多等 10 分鐘
                time.sleep(2)
                if hotkey_mod.is_trusted():
                    self.restart_hotkey()
                    notify.notify("已取得輔助使用權限，快捷鍵可以用了")
                    return

        watcher = threading.Thread(target=poll, daemon=True)
        watcher.start()

    def restart_hotkey(self) -> None:
        if self._hotkey is not None:
            self._hotkey.stop()
            self._hotkey = None
        self.start_hotkey()

    def reload_config(self) -> None:
        old = self.config.get("hotkey")
        self.config = config.load()
        api.set_ca_bundle(self.config.get("ca_bundle", ""))
        api.set_insecure_ssl(self.config.get("insecure_ssl", False))
        if self.config.get("hotkey") != old:
            self.restart_hotkey()

    # ---- 主流程 ----

    def toggle(self) -> None:
        with self._lock:
            if self.state == PROCESSING:
                return
            if self.recorder.is_recording:
                try:
                    wav = self.recorder.stop()
                except RecorderError as exc:
                    self._set_state(ERROR, str(exc))
                    self._flash_back_to_idle(ERROR, 2.0)
                    return
                self._set_state(PROCESSING)
                worker = threading.Thread(target=self._process, args=(wav,), daemon=True)
                worker.start()
            else:
                try:
                    self.recorder.start()
                except RecorderError as exc:
                    self._set_state(ERROR, str(exc))
                    self._flash_back_to_idle(ERROR, 2.0)
                    return
                self._set_state(RECORDING)

    def _process(self, wav: bytes) -> None:
        started = time.monotonic()
        try:
            text = self._transcribe_and_refine(wav)
        except api.ApiError as exc:
            self._set_state(ERROR, f"處理失敗：{exc}")
            self._flash_back_to_idle(ERROR, 3.0)
            return
        except Exception as exc:  # 任何意外都不該讓常駐程式死掉
            self._set_state(ERROR, f"未預期錯誤：{exc}")
            self._flash_back_to_idle(ERROR, 3.0)
            return

        # 保底：先寫剪貼簿，再嘗試自動貼上
        try:
            paste.copy(text)
        except Exception as exc:
            self._set_state(ERROR, str(exc))
            self._flash_back_to_idle(ERROR, 3.0)
            return

        if self.config.get("auto_paste", True):
            try:
                paste.paste()
            except Exception:
                self._set_state(ERROR, "自動貼上失敗 — 文字已複製到剪貼簿")
                self._flash_back_to_idle(ERROR, 3.0)
                return

        print(f"[tapsay] 完成，耗時 {time.monotonic() - started:.1f}s、{len(text)} 字")
        self._set_state(SUCCESS)
        self._flash_back_to_idle(SUCCESS, 1.2)

    def _transcribe_and_refine(self, wav: bytes) -> str:
        stt = self.config["stt"]
        raw = api.transcribe(stt["endpoint"], config.get_api_key("stt"), stt["model"], wav)
        llm = self.config["llm"]
        return api.refine(
            llm["endpoint"], config.get_api_key("llm"), llm["model"], llm["prompt"], raw
        )
