#!/bin/bash
# windows-migration-skill :: collector (macOS)
#
# EXPERIMENTAL. Written against macOS 12+ conventions but NOT yet verified
# on real hardware by the maintainer. Please open an issue with your output.
#
# READ-ONLY. No sudo. No network upload. Writes one JSON file.
# Uses only what ships with macOS: bash 3.2, sw_vers, plutil/PlistBuddy, du, brew (optional).
#
# Usage:
#   bash collect/mac.sh [output.json]

set -u

OUT="${1:-profile.raw.json}"
WARN_FILE="$(mktemp -t wms_warn.XXXXXX)"
: > "$WARN_FILE"

warn() {
  printf '%s\n' "$1" >> "$WARN_FILE"
  printf '  ! %s\n' "$1" >&2
}

# JSON string escaping, no external deps (BSD tr/sed).
esc() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

plist_val() {
  # $1 = plist path, $2 = key
  local v
  v=$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null) || return 0
  printf '%s' "$v"
}

have() { command -v "$1" >/dev/null 2>&1; }

echo "windows-migration-skill :: collector (macOS)"
echo "Read-only scan. Nothing is installed, changed or deleted."

# ---------------------------------------------------------------- machine

OS_NAME=$(sw_vers -productName 2>/dev/null || echo "macOS")
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "")
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null || echo "")
ARCH=$(uname -m 2>/dev/null || echo "arm64")
CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
HOST=$(scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || echo "")

# ---------------------------------------------------------------- app bundles

APPS=""
APPS_SEP=""
APP_COUNT=0

scan_app() {
  local app="$1"
  local info="$app/Contents/Info.plist"
  [ -d "$app" ] || return 0
  [ -f "$info" ] || return 0

  local name bid ver hints hint_json hsep hint
  name=$(plist_val "$info" CFBundleName)
  [ -n "$name" ] || name=$(basename "$app" .app)
  bid=$(plist_val "$info" CFBundleIdentifier)
  ver=$(plist_val "$info" CFBundleShortVersionString)
  [ -n "$ver" ] || ver=$(plist_val "$info" CFBundleVersion)

  hints=""
  hsep=""
  for hint in \
    "$HOME/Library/Application Support/$name" \
    "$HOME/Library/Application Support/$bid" \
    "$HOME/Library/Containers/$bid" \
    "$HOME/Library/Preferences/$bid.plist" \
    "$HOME/Library/Caches/$bid"; do
    [ -e "$hint" ] || continue
    hints="${hints}${hsep}\"$(esc "$hint")\""
    hsep=","
  done

  APPS="${APPS}${APPS_SEP}{\"name\":\"$(esc "$name")\",\"bundle_id\":\"$(esc "$bid")\",\"version\":\"$(esc "$ver")\",\"path\":\"$(esc "$app")\",\"config_hints\":[${hints}],\"source\":\"app_bundle\"}"
  APPS_SEP=","
  APP_COUNT=$((APP_COUNT + 1))
}

for app in /Applications/*.app "$HOME"/Applications/*.app /Applications/Utilities/*.app; do
  [ -d "$app" ] || continue
  scan_app "$app"
done

echo "  found $APP_COUNT app bundles"

# ---------------------------------------------------------------- homebrew

BREWS=""
BREW_SEP=""
BREW_COUNT=0

if have brew; then
  for f in $(brew list --formula 2>/dev/null); do
    BREWS="${BREWS}${BREW_SEP}{\"name\":\"$(esc "$f")\",\"kind\":\"formula\"}"
    BREW_SEP=","
    BREW_COUNT=$((BREW_COUNT + 1))
  done
  for c in $(brew list --cask 2>/dev/null); do
    BREWS="${BREWS}${BREW_SEP}{\"name\":\"$(esc "$c")\",\"kind\":\"cask\"}"
    BREW_SEP=","
    BREW_COUNT=$((BREW_COUNT + 1))
  done
  echo "  found $BREW_COUNT homebrew packages"
else
  warn "homebrew not found; package identification limited."
fi

# ---------------------------------------------------------------- dotfiles

DOTFILES=""
DOT_SEP=""
DOT_COUNT=0

for d in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.gitconfig" "$HOME/.ssh" \
         "$HOME/.config" "$HOME/.npmrc" "$HOME/.aws" "$HOME/.kube" \
         "$HOME/.vimrc" "$HOME/.tmux.conf" "$HOME/.claude" "$HOME/.cursor" \
         "$HOME/.ollama" "$HOME/.cache/huggingface"; do
  [ -e "$d" ] || continue
  DOTFILES="${DOTFILES}${DOT_SEP}\"$(esc "$d")\""
  DOT_SEP=","
  DOT_COUNT=$((DOT_COUNT + 1))
done

echo "  found $DOT_COUNT dotfile entries"

# ---------------------------------------------------------------- large folders

BIG=""
BIG_SEP=""
BIG_COUNT=0

add_big() {
  local label="$1" path="$2" kind="$3" kb
  [ -e "$path" ] || return 0
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  [ -n "$kb" ] || kb=0
  BIG="${BIG}${BIG_SEP}{\"label\":\"$(esc "$label")\",\"path\":\"$(esc "$path")\",\"kind\":\"$(esc "$kind")\",\"size_bytes\":$((kb * 1024))}"
  BIG_SEP=","
  BIG_COUNT=$((BIG_COUNT + 1))
}

add_big "Ollama models"      "$HOME/.ollama/models"                                   "local_models"
add_big "LM Studio"          "$HOME/.lmstudio"                                        "local_models"
add_big "LM Studio cache"    "$HOME/.cache/lm-studio"                                 "local_models"
add_big "HuggingFace cache"  "$HOME/.cache/huggingface"                               "local_models"
add_big "ComfyUI"            "$HOME/ComfyUI"                                          "local_models"
add_big "Docker disk"        "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" "vm_disk"
add_big "Steam library"      "$HOME/Library/Application Support/Steam/steamapps/common" "game_library"
add_big "Xcode DerivedData"  "$HOME/Library/Developer/Xcode/DerivedData"              "build_cache"
add_big "iOS Simulators"     "$HOME/Library/Developer/CoreSimulator/Devices"          "build_cache"
add_big "Xcode DeviceSupport" "$HOME/Library/Developer/Xcode/iOS DeviceSupport"       "build_cache"

echo "  measured $BIG_COUNT large folders"

# ---------------------------------------------------------------- warnings

WARNS=""
WARN_SEP=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  WARNS="${WARNS}${WARN_SEP}\"$(esc "$line")\""
  WARN_SEP=","
done < "$WARN_FILE"
rm -f "$WARN_FILE"

# ---------------------------------------------------------------- write

TMP="${OUT}.tmp"
cat > "$TMP" <<EOF
{
  "schema_version": "0.1",
  "tool": "windows-migration-skill",
  "platform": "macos",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "machine": {
    "os": "$(esc "$OS_NAME")",
    "os_display": "$(esc "$OS_NAME $OS_VER")",
    "os_version": "$(esc "$OS_VER")",
    "build": "$(esc "$OS_BUILD")",
    "arch": "$(esc "$ARCH")",
    "cpu": "$(esc "$CPU")",
    "hostname": "$(esc "$HOST")",
    "locale": "$(esc "${LANG:-}")"
  },
  "apps": [${APPS}],
  "brews": [${BREWS}],
  "dotfiles": [${DOTFILES}],
  "big_paths": [${BIG}],
  "warnings": [${WARNS}]
}
EOF

mv "$TMP" "$OUT"

echo ""
echo "  OK  $APP_COUNT apps, $BREW_COUNT brew packages, $DOT_COUNT dotfiles, $BIG_COUNT large folders"
echo "      -> $OUT"
echo ""
echo "Next: hand this file to your agent and ask it to classify and render the report."
