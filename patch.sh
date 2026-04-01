#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# better-buddy patch — Apply a forged salt to your Claude Code binary
#
# Usage:
#   ./patch.sh                         # Patch with DEFAULT_SALT (edit below)
#   ./patch.sh --salt "YOUR_SALT"      # Patch with a specific salt
#   ./patch.sh --check                 # Show current binary state
#   ./patch.sh --restore               # Restore original binary from backup
#   ./patch.sh --help                  # Show help
#
# After patching, restart Claude Code and run /buddy to hatch your new companion.
# Re-run this script after every Claude Code update.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

# Set this to your forged salt (from forge.ts). Must be exactly 15 characters.
# Override per-run with: ./patch.sh --salt "YOUR_SALT"
DEFAULT_SALT=""

# The original salt compiled into Claude Code — do not change this.
ORIGINAL_SALT="friend-2026-401"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Resolve binary path ──────────────────────────────────────────────────────
resolve_binary() {
  local claude_path
  claude_path="$(which claude 2>/dev/null)" || {
    echo -e "${RED}❌ 'claude' not found in PATH${NC}" >&2
    exit 1
  }
  readlink -f "$claude_path"
}

BINARY="$(resolve_binary)"
BACKUP="${BINARY}.original"

# ── Helpers ───────────────────────────────────────────────────────────────────
count_occurrences() {
  local file="$1" pattern="$2"
  (grep -boa "$pattern" "$file" 2>/dev/null || true) | wc -l | tr -d ' '
}

print_banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║         better-buddy patch           ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── Commands ──────────────────────────────────────────────────────────────────
do_check() {
  print_banner
  local orig_count custom_count
  orig_count=$(count_occurrences "$BINARY" "$ORIGINAL_SALT")

  echo -e "  Binary:  ${DIM}$BINARY${NC}"
  echo -e "  Size:    $(du -h "$BINARY" | cut -f1)"
  echo ""

  if [[ "$orig_count" -gt 0 ]]; then
    # Check if any known custom salt is present
    echo -e "  Status:  ${YELLOW}UNPATCHED${NC} (original salt, $orig_count occurrences)"
  else
    # Try to find what salt is in there by checking common locations
    echo -e "  Status:  ${GREEN}PATCHED${NC} (original salt not found — custom salt active)"
  fi

  if [[ -f "$BACKUP" ]]; then
    echo -e "  Backup:  ${DIM}$BACKUP${NC} ($(du -h "$BACKUP" | cut -f1))"
  else
    echo -e "  Backup:  ${DIM}none${NC}"
  fi
  echo ""
}

do_patch() {
  local salt="$1"
  print_banner

  # Validate salt length
  if [[ ${#salt} -ne 15 ]]; then
    echo -e "${RED}❌ Salt must be exactly 15 characters (got ${#salt}: '$salt')${NC}" >&2
    echo ""
    echo "  The original salt 'friend-2026-401' is 15 bytes. The replacement must be"
    echo "  the same length — different lengths would shift bytes and corrupt the binary."
    exit 1
  fi

  # Validate salt characters (printable ASCII, safe for sed)
  if [[ ! "$salt" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}❌ Salt must contain only: a-z A-Z 0-9 _ -${NC}" >&2
    exit 1
  fi

  local orig_count
  orig_count=$(count_occurrences "$BINARY" "$ORIGINAL_SALT")

  # Check if already patched with this salt
  local custom_count
  custom_count=$(count_occurrences "$BINARY" "$salt")

  if [[ "$orig_count" -eq 0 && "$custom_count" -gt 0 ]]; then
    echo -e "  ${GREEN}✅ Already patched${NC} with '${BOLD}$salt${NC}' ($custom_count occurrences)."
    echo "  Nothing to do."
    exit 0
  fi

  if [[ "$orig_count" -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠️  Original salt not found.${NC}" >&2
    echo "  Binary may already be patched with a different salt." >&2
    echo "  Run ${BOLD}./patch.sh --restore${NC} first, then re-patch." >&2
    exit 1
  fi

  echo -e "  Found ${BOLD}$orig_count${NC} occurrence(s) of original salt."

  # Backup
  if [[ ! -f "$BACKUP" ]]; then
    echo -e "  Creating backup: ${DIM}$BACKUP${NC}"
    cp "$BINARY" "$BACKUP"
  else
    echo -e "  Backup exists:   ${DIM}$BACKUP${NC}"
  fi

  # Patch
  echo -e "  Patching: ${DIM}$ORIGINAL_SALT${NC} → ${BOLD}$salt${NC}"
  sed -i "s/$ORIGINAL_SALT/$salt/g" "$BINARY"

  # Verify
  local new_orig new_custom
  new_orig=$(count_occurrences "$BINARY" "$ORIGINAL_SALT")
  new_custom=$(count_occurrences "$BINARY" "$salt")

  if [[ "$new_orig" -eq 0 && "$new_custom" -gt 0 ]]; then
    echo ""
    echo -e "  ${GREEN}✅ Patched successfully${NC} ($new_custom occurrences replaced)."
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    1. Restart Claude Code"
    echo "    2. Run /buddy to hatch your new companion"
    echo "    3. Re-run this script after each Claude Code update"
    echo ""
  else
    echo -e "  ${RED}⚠️  Patch may be incomplete${NC} (original: $new_orig, custom: $new_custom)" >&2
    echo "  Consider restoring from backup and trying again." >&2
    exit 1
  fi
}

do_restore() {
  print_banner
  if [[ ! -f "$BACKUP" ]]; then
    echo -e "  ${RED}❌ No backup found${NC} at $BACKUP" >&2
    exit 1
  fi

  echo -e "  Restoring: ${DIM}$BACKUP → $BINARY${NC}"
  cp "$BACKUP" "$BINARY"
  chmod +x "$BINARY"

  local orig_count
  orig_count=$(count_occurrences "$BINARY" "$ORIGINAL_SALT")
  echo -e "  ${GREEN}✅ Restored${NC} ($orig_count occurrences of original salt)."
  echo ""
}

do_help() {
  echo ""
  echo -e "${BOLD}better-buddy patch${NC} — Apply a forged salt to your Claude Code binary"
  echo ""
  echo -e "${BOLD}USAGE${NC}"
  echo "  ./patch.sh                         Patch with DEFAULT_SALT (edit the script)"
  echo "  ./patch.sh --salt \"YOUR_SALT\"       Patch with a specific 15-char salt"
  echo "  ./patch.sh --check                 Show current binary state"
  echo "  ./patch.sh --restore               Restore original binary from backup"
  echo ""
  echo -e "${BOLD}SALT REQUIREMENTS${NC}"
  echo "  • Exactly 15 characters (same length as original: 'friend-2026-401')"
  echo "  • Only: a-z A-Z 0-9 _ -"
  echo "  • Find your salt with: bun run forge.ts"
  echo ""
  echo -e "${BOLD}AFTER UPDATES${NC}"
  echo "  Claude Code auto-updates replace the binary. Just re-run:"
  echo "    ./patch.sh --salt \"YOUR_SALT\""
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --check)
    do_check
    ;;
  --restore)
    do_restore
    ;;
  --salt)
    if [[ -z "${2:-}" ]]; then
      echo -e "${RED}Usage: $0 --salt \"YOUR_15_CHAR_SALT\"${NC}" >&2
      exit 1
    fi
    do_patch "$2"
    ;;
  --help|-h)
    do_help
    ;;
  "")
    if [[ -z "$DEFAULT_SALT" ]]; then
      echo -e "${RED}❌ No DEFAULT_SALT configured.${NC}" >&2
      echo "  Either edit DEFAULT_SALT in this script, or use: ./patch.sh --salt \"YOUR_SALT\"" >&2
      exit 1
    fi
    do_patch "$DEFAULT_SALT"
    ;;
  *)
    echo -e "${RED}Unknown option: $1${NC}" >&2
    do_help
    exit 1
    ;;
esac
