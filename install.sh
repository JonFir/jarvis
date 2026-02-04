#!/usr/bin/env zsh
set -euo pipefail

OWNER="JonFir"
REPO="jarvis"
BIN_NAME="jarvisbot"
ASSET_SUFFIX="macos-arm64.zip"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
ENV_FILE="${ENV_FILE:-$HOME/.jarvisbot.env}"

err() { print -u2 -- "Error: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || err "missing dependency: $1"; }

print -- "Installing ${BIN_NAME} from ${OWNER}/${REPO} (latest release) ..."

need_cmd curl
need_cmd unzip

if command -v python3 >/dev/null 2>&1; then
  JSON_PARSER="python3"
elif command -v ruby >/dev/null 2>&1; then
  JSON_PARSER="ruby"
else
  err "need python3 or ruby to parse GitHub API JSON"
fi

API="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
release_json="$(curl -fsSL "$API")"

tag_name="$(
  print -r -- "$release_json" | {
    if [[ "$JSON_PARSER" == "python3" ]]; then
      python3 - <<'PY'
import json,sys
data=json.load(sys.stdin)
print(data.get("tag_name",""))
PY
    else
      ruby -rjson -e 'puts(JSON.parse(STDIN.read)["tag_name"].to_s)'
    fi
  }
)"

[[ -n "$tag_name" ]] || err "could not detect latest release tag (is there a Release?)"

asset_url="$(
  print -r -- "$release_json" | {
    if [[ "$JSON_PARSER" == "python3" ]]; then
      python3 - <<PY
import json,sys
data=json.load(sys.stdin)
suffix="${ASSET_SUFFIX}"
url=""
for a in data.get("assets",[]):
  name=a.get("name","")
  if name.endswith(suffix):
    url=a.get("browser_download_url","")
    break
print(url)
PY
    else
      ASSET_SUFFIX="$ASSET_SUFFIX" ruby -rjson -e '
        data=JSON.parse(STDIN.read)
        suffix=ENV["ASSET_SUFFIX"]
        url=""
        (data["assets"]||[]).each do |a|
          if (a["name"]||"").end_with?(suffix)
            url=a["browser_download_url"].to_s
            break
          end
        end
        puts url
      '
    fi
  }
)"

[[ -n "$asset_url" ]] || err "could not find asset *-${ASSET_SUFFIX} in latest release (${tag_name})"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir" >/dev/null 2>&1 || true }
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

if ! command -v "$BIN_NAME" >/dev/null 2>&1; then
  zshrc="$HOME/.zshrc"
  touch "$zshrc"
  if ! grep -Fq "$INSTALL_DIR" "$zshrc" 2>/dev/null; then
    print -- "" >> "$zshrc"
    print -- "# Added by ${BIN_NAME} installer" >> "$zshrc"
    print -- "export PATH=\"${INSTALL_DIR}:\$PATH\"" >> "$zshrc"
  fi
fi

print -- ""
print -- "Now configure bot credentials (will be written to ${ENV_FILE})"

print -n -- "BOT_TOKEN: "
read -r BOT_TOKEN
print -n -- "CHAT_ID: "
read -r CHAT_ID

umask 077
cat > "$ENV_FILE" <<EOF
BOT_TOKEN=$BOT_TOKEN
CHAT_ID=$CHAT_ID
EOF
chmod 600 "$ENV_FILE"

print -- ""
print -- "Installed:"
print -- "  Binary: ${dst_bin}"
print -- "  Env:    ${ENV_FILE}"
print -- ""
print -- "Tip: restart your terminal (or run: export PATH=\"${INSTALL_DIR}:\$PATH\")"
print -- "Check: ${BIN_NAME} --help"

# --- LaunchAgent install (optional) ---

SERVICE_LABEL="com.jonfir.jarvisbot"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="$LOG_DIR/jarvisbot.log"
STDERR_LOG="$LOG_DIR/jarvisbot.err.log"

install_launchagent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

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
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>set -a; source "${ENV_FILE}"; set +a; exec "${dst_bin}"</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>

  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>

  <!-- Можно ограничить ресурсы/сделать мягче, если надо:
  <key>ThrottleInterval</key>
  <integer>10</integer>
  -->
</dict>
</plist>
EOF

  # Загружаем в сессию текущего пользователя
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1 || true

  print -- ""
  print -- "Daemon installed and started via launchd:"
  print -- "  Label:  ${SERVICE_LABEL}"
  print -- "  Plist:  ${PLIST_PATH}"
  print -- "  Logs:   ${STDOUT_LOG}"
  print -- "          ${STDERR_LOG}"
}

print -- ""
print -n -- "Install as daemon (launchd) and autostart on login? [y/N]: "
read -r install_daemon
if [[ "$install_daemon" == "y" || "$install_daemon" == "Y" ]]; then
  install_launchagent
else
  print -- "Skipped daemon installation."
fi

print -- ""
print -- "Uninstall daemon later:"
print -- "  launchctl bootout gui/$(id -u) \"$PLIST_PATH\""
print -- "  rm -f \"$PLIST_PATH\""
