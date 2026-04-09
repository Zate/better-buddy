#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# buddy-ensure — Ensure Claude Code companion is patched and synced
#
# Designed to be called from a launcher (e.g., nyx). Quiet when everything
# is already good. Patches if needed, syncs companion soul between configs.
#
# Set BUDDY_SALT env var to your forged salt (from forge.ts), or pass --salt.
#
# Usage:
#   BUDDY_SALT="abc123..." buddy-ensure   # Check, patch if needed, sync
#   buddy-ensure --salt "abc123..."       # Same, inline
#   buddy-ensure --check                  # Just show status
#   buddy-ensure --restore                # Restore original binary
#   buddy-ensure --sync                   # Only sync companion soul between configs
#   buddy-ensure --verbose                # Show all output even when already patched
#
# Exit codes:
#   0 — already patched or patch succeeded
#   1 — error (binary not found, patch failed, etc.)
#   2 — patched this run (caller may want to notify user to restart)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════

ORIGINAL_SALT="friend-2026-401"
CONFIG_FILE="${BUDDY_CONFIG:-$HOME/.config/better-buddy/config}"

# Load salt: env var > config file
SALT="${BUDDY_SALT:-}"
if [[ -z "$SALT" && -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" 2>/dev/null
  SALT="${BUDDY_SALT:-}"
fi

# Config files to check/sync (in priority order)
# CLAUDE_CONFIG_DIR is set by Claude Code when launched with --config-dir
CONFIG_PATHS=(
  "$HOME/.claude.json"
  "$HOME/.claude/.config"
)
# Add CLAUDE_CONFIG_DIR config if set and not already covered
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  _cc_cfg="$CLAUDE_CONFIG_DIR/.claude.json"
  _already=false
  for _p in "${CONFIG_PATHS[@]}"; do
    [[ "$_p" == "$_cc_cfg" ]] && _already=true
  done
  $_already || CONFIG_PATHS+=("$_cc_cfg")
  unset _cc_cfg _already _p
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Colors (suppressed when not a tty)
# ═══════════════════════════════════════════════════════════════════════════════

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Flags
# ═══════════════════════════════════════════════════════════════════════════════

VERBOSE=false
MODE="ensure"  # ensure | check | restore | sync

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --restore)  MODE="restore"; shift ;;
    --sync)     MODE="sync"; shift ;;
    --verbose)  VERBOSE=true; shift ;;
    --salt)     SALT="${2:?--salt requires a value}"; shift 2 ;;
    --help|-h)
      head -17 "$0" | tail -14
      exit 0
      ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════════
# Binary resolution
# ═══════════════════════════════════════════════════════════════════════════════

resolve_binary() {
  local claude_path
  claude_path="$(which claude 2>/dev/null)" || return 1
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: readlink -f not available, use python or greadlink
    python3 -c "import os; print(os.path.realpath('$claude_path'))" 2>/dev/null \
      || greadlink -f "$claude_path" 2>/dev/null \
      || readlink "$claude_path"
  else
    readlink -f "$claude_path"
  fi
}

BINARY="$(resolve_binary)" || {
  [[ "$MODE" == "ensure" ]] && exit 0  # silent fail in launcher mode
  echo -e "${RED}❌ 'claude' not found in PATH${NC}" >&2
  exit 1
}
BACKUP="${BINARY}.original"

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

count_salt() {
  (grep -boa "$1" "$BINARY" 2>/dev/null || true) | wc -l | tr -d ' '
}

is_patched() {
  local orig_count
  orig_count=$(count_salt "$ORIGINAL_SALT")
  [[ "$orig_count" -eq 0 ]]
}

is_macos() {
  [[ "$(uname)" == "Darwin" ]]
}

log() {
  if $VERBOSE || [[ "$MODE" != "ensure" ]]; then
    echo -e "$@"
  fi
}

save_salt() {
  local salt="$1"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
# better-buddy config — auto-managed, but safe to hand-edit
# This file is read by buddy-ensure.sh and patch.sh
BUDDY_SALT="$salt"
EOF
  log "  ${DIM}Salt saved to $CONFIG_FILE${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Config operations
# ═══════════════════════════════════════════════════════════════════════════════

# Find the primary config (the one that has a companion with the most recent hatchedAt)
find_source_config() {
  local best_path="" best_time=0
  for p in "${CONFIG_PATHS[@]}"; do
    [[ -f "$p" ]] || continue
    local t
    t=$(python3 -c "
import json
try:
    d = json.load(open('$p'))
    c = d.get('companion', {})
    print(c.get('hatchedAt', 0))
except: print(0)
" 2>/dev/null) || continue
    if [[ "$t" -gt "$best_time" ]]; then
      best_time="$t"
      best_path="$p"
    fi
  done
  echo "$best_path"
}

# Read companion soul from a config file
read_companion() {
  local path="$1"
  python3 -c "
import json, sys
try:
    d = json.load(open('$path'))
    c = d.get('companion')
    if c:
        json.dump(c, sys.stdout)
    else:
        print('null', end='')
except:
    print('null', end='')
" 2>/dev/null
}

# Write companion soul to a config file (merge, don't overwrite)
write_companion() {
  local path="$1" companion_json="$2"
  python3 -c "
import json, sys

companion = json.loads('$companion_json')
if not companion:
    sys.exit(0)

try:
    with open('$path') as f:
        config = json.load(f)
except:
    config = {}

existing = config.get('companion', {})

# Only update if different (compare name + personality)
if existing.get('name') == companion.get('name') and existing.get('personality') == companion.get('personality'):
    sys.exit(0)

config['companion'] = companion
with open('$path', 'w') as f:
    json.dump(config, f, indent=2)
print('updated')
" 2>/dev/null
}

# Clear companion soul from a config (forces re-hatch)
clear_companion() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  python3 -c "
import json
try:
    with open('$path') as f:
        config = json.load(f)
    if 'companion' in config:
        del config['companion']
        with open('$path', 'w') as f:
            json.dump(config, f, indent=2)
        print('cleared')
except: pass
" 2>/dev/null
}

# Sync companion from source → all other configs
do_sync() {
  local source
  source=$(find_source_config)

  if [[ -z "$source" ]]; then
    log "  ${DIM}No companion found in any config — nothing to sync${NC}"
    return 0
  fi

  local companion
  companion=$(read_companion "$source")

  if [[ "$companion" == "null" || -z "$companion" ]]; then
    log "  ${DIM}Source config has no companion — nothing to sync${NC}"
    return 0
  fi

  local name
  name=$(python3 -c "import json; print(json.loads('$companion').get('name','?'))" 2>/dev/null)

  local synced=0
  for p in "${CONFIG_PATHS[@]}"; do
    [[ -f "$p" ]] || continue
    [[ "$p" == "$source" ]] && continue
    local result
    result=$(write_companion "$p" "$companion")
    if [[ "$result" == "updated" ]]; then
      log "  ${GREEN}✓${NC} Synced ${BOLD}$name${NC} → ${DIM}$p${NC}"
      synced=$((synced + 1))
    fi
  done

  if [[ $synced -eq 0 ]]; then
    log "  ${DIM}$name already synced across configs${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Patch operations
# ═══════════════════════════════════════════════════════════════════════════════

do_patch() {
  # Validate
  if [[ ${#SALT} -ne 15 ]]; then
    echo -e "${RED}❌ Salt must be exactly 15 characters (got ${#SALT})${NC}" >&2
    return 1
  fi

  local orig_count
  orig_count=$(count_salt "$ORIGINAL_SALT")

  if [[ "$orig_count" -eq 0 ]]; then
    # Already patched — check if it's our salt
    local custom_count
    custom_count=$(count_salt "$SALT")
    if [[ "$custom_count" -gt 0 ]]; then
      log "  ${GREEN}✓${NC} Already patched"
      return 0
    else
      log "  ${YELLOW}⚠️${NC}  Patched with unknown salt. Use --restore first." >&2
      return 1
    fi
  fi

  # Backup
  if [[ ! -f "$BACKUP" ]]; then
    cp "$BINARY" "$BACKUP"
    log "  ${DIM}Backup → ${BACKUP}${NC}"
  fi

  # Patch
  sed -i "s/$ORIGINAL_SALT/$SALT/g" "$BINARY"

  # macOS: re-sign binary
  if is_macos; then
    if command -v codesign &>/dev/null; then
      codesign --force --sign - "$BINARY" 2>/dev/null && \
        log "  ${DIM}Re-signed binary (macOS)${NC}" || \
        log "  ${YELLOW}⚠️${NC}  codesign failed — binary may not run on macOS"
    fi
  fi

  # Verify
  local new_orig
  new_orig=$(count_salt "$ORIGINAL_SALT")
  if [[ "$new_orig" -ne 0 ]]; then
    echo -e "${RED}❌ Patch verification failed${NC}" >&2
    return 1
  fi

  # Keep companion soul — name/personality persist, bones regenerate from new salt.

  log "  ${GREEN}✓${NC} Patched Claude binary ${DIM}(restart to apply)${NC}"
  return 0
}

do_restore() {
  if [[ ! -f "$BACKUP" ]]; then
    echo -e "${RED}❌ No backup found at $BACKUP${NC}" >&2
    return 1
  fi

  cp "$BACKUP" "$BINARY"
  chmod +x "$BINARY"

  if is_macos && command -v codesign &>/dev/null; then
    codesign --force --sign - "$BINARY" 2>/dev/null || true
  fi

  log "  ${GREEN}✓${NC} Restored original binary"
}

do_check() {
  echo -e "${BOLD}buddy-ensure status${NC}"
  echo ""
  echo -e "  Binary:  ${DIM}$BINARY${NC}"

  if is_patched; then
    local custom_count
    custom_count=$(count_salt "$SALT")
    if [[ "$custom_count" -gt 0 ]]; then
      echo -e "  Patch:   ${GREEN}ACTIVE${NC} (salt: $SALT)"
    else
      echo -e "  Patch:   ${YELLOW}ACTIVE (unknown salt)${NC}"
    fi
  else
    echo -e "  Patch:   ${YELLOW}NOT APPLIED${NC}"
  fi

  echo -e "  Backup:  ${DIM}$([ -f "$BACKUP" ] && echo "$BACKUP" || echo "none")${NC}"
  echo ""

  # Show companion state across configs
  echo -e "  ${BOLD}Companions:${NC}"
  for p in "${CONFIG_PATHS[@]}"; do
    if [[ -f "$p" ]]; then
      local comp
      comp=$(python3 -c "
import json
try:
    d = json.load(open('$p'))
    c = d.get('companion')
    if c:
        print(f\"{c.get('name', '?')} — {c.get('personality', '?')[:60]}...\")
    else:
        print('(none)')
except: print('(error)')
" 2>/dev/null)
      echo -e "    ${DIM}$(basename "$p")${NC}: $comp"
    fi
  done
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

case "$MODE" in
  check)
    do_check
    ;;
  restore)
    do_restore
    ;;
  sync)
    do_sync
    ;;
  ensure)
    if is_patched; then
      log "  ${GREEN}✓${NC} Buddy patched"
      do_sync
      exit 0
    else
      if [[ -z "$SALT" ]]; then
        log "  ${DIM}Buddy not patched (no BUDDY_SALT set)${NC}"
        exit 0
      fi
      log "  ${CYAN}↻${NC} Patching buddy..."
      if do_patch; then
        save_salt "$SALT"
        exit 2  # signal to caller: patched this run, restart needed
      else
        exit 1
      fi
    fi
    ;;
esac
