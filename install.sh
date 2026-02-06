#!/usr/bin/env bash
set -euo pipefail

# Configuration

OWNER="JonFir"
REPO="jarvis"
BIN_NAME="jarvisbot"
ASSET_SUFFIX="macos-arm64.zip"

# Environment variables

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
ENV_FILE="${ENV_FILE:-$HOME/.jarvisbot.env}"
API="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"

# Utilities

err() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || err "missing dependency: $1"; }

# Main installation logic

printf 'Installing %s from %s/%s (latest release) ...\n' "$BIN_NAME" "$OWNER" "$REPO"

# Check dependencies

need_cmd curl
need_cmd unzip

if command -v jq >/dev/null 2>&1; then
  :
elif command -v brew >/dev/null 2>&1; then
  brew install jq
else
  err "missing dependency: jq (install Homebrew first)"
fi

release_json="$(curl -fsSL "$API")"
[[ -n "$release_json" ]] || err "GitHub API returned empty response"

tag_name="$(printf '%s\n' "$release_json" | jq -r '.tag_name // ""')"

[[ -n "$tag_name" ]] || err "could not detect latest release tag (is there a Release?)"

asset_url="$(
  printf '%s\n' "$release_json" | jq -r --arg suffix "$ASSET_SUFFIX" '
    .assets[]? | select(.name | endswith($suffix)) | .browser_download_url
  ' | head -n 1
)"

[[ -n "$asset_url" ]] || err "could not find asset *-${ASSET_SUFFIX} in latest release (${tag_name})"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

zip_path="$tmpdir/release.zip"
curl -fsSL -o "$zip_path" "$asset_url"

mkdir -p "$tmpdir/out"
unzip -q "$zip_path" -d "$tmpdir/out"

src_bin="$tmpdir/out/${BIN_NAME}-macos-arm64"
[[ -f "$src_bin" ]] || err "expected binary not found in zip: ${BIN_NAME}-macos-arm64"

mkdir -p "$INSTALL_DIR"
dst_bin="$INSTALL_DIR/$BIN_NAME"
cp "$src_bin" "$dst_bin"
chmod +x "$dst_bin"

cleanup
trap - EXIT INT TERM

if ! command -v "$BIN_NAME" >/dev/null 2>&1; then
  zshrc="$HOME/.zshrc"
  touch "$zshrc"
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]] && ! grep -Fq "$INSTALL_DIR" "$zshrc" 2>/dev/null; then
    printf '\n' >> "$zshrc"
    printf '# Added by %s installer\n' "$BIN_NAME" >> "$zshrc"
    printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$zshrc"
  fi
fi

printf '\n'
printf 'Now configure bot credentials (will be written to %s)\n' "$ENV_FILE"

printf 'BOT_TOKEN: '
read -rs BOT_TOKEN
printf '\n'
printf 'CHAT_ID: '
read -r CHAT_ID

umask 077
cat > "$ENV_FILE" <<EOF
BOT_TOKEN=$BOT_TOKEN
CHAT_ID=$CHAT_ID
EOF
chmod 600 "$ENV_FILE"

printf '\n'
printf 'Installed:\n'
printf '  Binary: %s\n' "$dst_bin"
printf '  Env:    %s\n' "$ENV_FILE"
printf '\n'
printf 'Tip: restart your terminal (or run: export PATH="%s:$PATH")\n' "$INSTALL_DIR"
printf 'Check: %s --help\n' "$BIN_NAME"

# --- LaunchAgent install (optional) ---

SERVICE_LABEL="ru.jonfir.jarvisbot"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="$LOG_DIR/jarvisbot.log"
STDERR_LOG="$LOG_DIR/jarvisbot.err.log"

install_launchagent() {
  mkdir -p "/Library/LaunchAgents" "$LOG_DIR"

  # Останавливаем/выгружаем старую версию, если была
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true

  # Делаем так, чтобы env-файл гарантированно подхватывался:
  # zsh -lc "set -a; source ~/.jarvisbot.env; set +a; exec ~/.local/bin/jarvisbot"
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${dst_bin}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>

  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

  # Загружаем в сессию текущего пользователя
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1 || true

  printf '\n'
  printf 'Daemon installed and started via launchd:\n'
  printf '  Label:  %s\n' "$SERVICE_LABEL"
  printf '  Plist:  %s\n' "$PLIST_PATH"
  printf '  Logs:   %s\n' "$STDOUT_LOG"
  printf '          %s\n' "$STDERR_LOG"
}

printf '\n'
printf 'Install as daemon (launchd) and autostart on login? [y/N]: '
read -r install_daemon
if [[ "$install_daemon" == "y" || "$install_daemon" == "Y" ]]; then
  install_launchagent
else
  printf 'Skipped daemon installation.\n'
fi

printf '\n'
printf 'Uninstall daemon later:\n'
printf '  launchctl bootout gui/%s "%s"\n' "$(id -u)" "$PLIST_PATH"
printf '  rm -f "%s"\n' "$PLIST_PATH"
