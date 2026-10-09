#!/usr/bin/env bash
# TapSay — Ubuntu / Debian 安裝腳本
#
#   curl -LsSf https://raw.githubusercontent.com/juishuyeh/tapsay/main/scripts/install-linux.sh | bash
#
# 或在原始碼資料夾裡執行 ./scripts/install-linux.sh（會安裝這份原始碼）。
# 做的事：apt 裝系統套件 → 用 uv 安裝 tapsay 指令 → 應用程式選單項目 → 開機自動啟動。
set -euo pipefail

SOURCE="${TAPSAY_SOURCE:-git+https://github.com/juishuyeh/tapsay}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../pyproject.toml" ]]; then
  SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

say "安裝系統套件（需要 sudo）"
# libportaudio2：錄音；wl-clipboard / xclip：剪貼簿；libnotify-bin：通知
# gir1.2-ayatanaappindicator3-0.1 + 編譯 PyGObject 所需的開發套件：系統匣圖示
# python3-tk 不需要：uv 下載的 Python 自帶 Tk
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
  libportaudio2 wl-clipboard xclip libnotify-bin \
  gir1.2-ayatanaappindicator3-0.1 libgirepository-2.0-dev libcairo2-dev pkg-config build-essential curl git

if ! command -v uv >/dev/null 2>&1; then
  say "安裝 uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

say "安裝 TapSay（$SOURCE）"
uv tool install --force --python 3.14 --reinstall "$SOURCE"
BIN="$(uv tool dir --bin)/tapsay"

say "建立應用程式選單項目與開機自動啟動"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$APPS" "$AUTOSTART"
for target in "$APPS/tapsay.desktop" "$AUTOSTART/tapsay.desktop"; do
  cat > "$target" <<DESKTOP
[Desktop Entry]
Type=Application
Name=TapSay
Comment=按一下快捷鍵、說話，文字出現在游標位置
Exec=$BIN
Icon=audio-input-microphone
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
DESKTOP
done
cat > "$APPS/tapsay-settings.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=TapSay 設定
Exec=$BIN --settings
Icon=preferences-desktop
Terminal=false
Categories=Utility;Settings;
DESKTOP

if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && command -v gsettings >/dev/null 2>&1; then
  say "Wayland：在 GNOME 設定快捷鍵（按下時執行 tapsay --toggle）"
  "$BIN" --setup-shortcut || true
fi

say "完成"
cat <<MSG
接下來：
  1. 從應用程式選單打開「TapSay 設定」，填 STT / LLM 的 Endpoint、API Key、Model
  2. 打開「TapSay」（之後登入會自動啟動）
  3. 預設快捷鍵 Ctrl+Alt+Space：按一下開始說話、再按一下送出

Wayland 下要自動貼上的話，另外安裝並啟動 ydotool（見 README「Ubuntu」一節），
否則結果會放在剪貼簿，自己按 Ctrl+V。
MSG
