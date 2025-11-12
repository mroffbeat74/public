#!/usr/bin/env bash
# uninstall_patchmon.sh (v1.1)
# Safe, scoped uninstall for PatchMon agent (Go). Dry-run by default.

set -euo pipefail

DRY_RUN=1
[[ "${1:-}" == "--apply" ]] && DRY_RUN=0

say()  { printf "%s\n" "$*"; }
doit() { if (( DRY_RUN )); then echo "[DRY-RUN] $*"; else eval "$@"; fi }

found_any=0

# Known paths (scoped: do not widen these)
BIN="/usr/local/bin/patchmon-agent"
UNIT_ETC="/etc/systemd/system/patchmon-agent.service"
UNIT_LIB="/lib/systemd/system/patchmon-agent.service"
CONF_DIR="/etc/patchmon"
CONF_YML="$CONF_DIR/config.yml"
CREDS_YML="$CONF_DIR/credentials.yml"
LEGACY_CREDS="/etc/patchmon/credentials"  # legacy from bash agent
LOG1="$CONF_DIR/logs/patchmon-agent.log"
LOG2="/var/log/patchmon-agent.log"

say "== PatchMon uninstall helper =="
say "Mode: $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN (no changes)' || echo 'APPLY (will remove)')"
say ""

#####################################
# 1) Detect running service / process
#####################################
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q '^patchmon-agent\.service'; then
    found_any=1
    say "• systemd unit found: patchmon-agent.service"
    if systemctl is-active --quiet patchmon-agent.service; then
      say "  - Service is active -> will stop"
      doit "systemctl stop patchmon-agent.service"
    fi
    say "  - Will disable + remove the unit if present"
    doit "systemctl disable patchmon-agent.service 2>/dev/null || true"
    for unit in "$UNIT_ETC" "$UNIT_LIB"; do
      [[ -f "$unit" ]] && doit "rm -f '$unit'"
    done
    doit "systemctl daemon-reload"
  fi
fi

# Kill any stray process by exact binary path
if pgrep -f "/usr/local/bin/patchmon-agent serve" >/dev/null 2>&1; then
  found_any=1
  say "• Running agent process detected -> will kill"
  doit "pkill -f '/usr/local/bin/patchmon-agent serve' || true"
fi

#####################################
# 2) Remove binary (exact path only)
#####################################
if [[ -x "$BIN" ]]; then
  found_any=1
  say "• Agent binary found: $BIN -> will remove"
  doit "rm -f '$BIN'"
fi

#####################################
# 3) Remove configs (ONLY known files)
#####################################
if [[ -f "$CONF_YML" ]] || [[ -f "$CREDS_YML" ]] || [[ -f "$LEGACY_CREDS" ]] || [[ -d "$CONF_DIR" ]]; then
  found_any=1
  # remove only the known files first; don't touch dir yet
  if [[ -f "$CONF_YML" ]] || [[ -f "$CREDS_YML" ]] || [[ -f "$LEGACY_CREDS" ]]; then
    say "• Config/credential files detected -> will remove known files only"
    for f in "$CONF_YML" "$CREDS_YML" "$LEGACY_CREDS"; do
      [[ -f "$f" ]] && doit "rm -f '$f'"
    done
  fi
fi

#####################################
# 4) Logs (ONLY known files)
#####################################
for logf in "$LOG1" "$LOG2"; do
  if [[ -f "$logf" ]]; then
    found_any=1
    say "• Log file found: $logf -> will remove"
    doit "rm -f '$logf'"
  fi
done

# Try to remove the parent logs dir(s) if empty (only the immediate dir)
for parent in "$(dirname "$LOG1")" "$(dirname "$LOG2")"; do
  [[ -d "$parent" ]] || continue
  # Only delete if now empty (files only; leave if other stuff exists)
  if [[ -z "$(find "$parent" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)" ]]; then
    doit "rmdir '$parent' || true"
  fi
done

#####################################
# 5) Cron entries (only lines containing 'patchmon-agent')
#####################################
current_cron="$(crontab -l 2>/dev/null || true)"
if [[ -n "$current_cron" ]] && echo "$current_cron" | grep -q "patchmon-agent"; then
  found_any=1
  say "• Crontab entries referencing 'patchmon-agent' detected -> will remove only those lines"
  new_cron="$(echo "$current_cron" | grep -v 'patchmon-agent' || true)"
  if (( DRY_RUN )); then
    say "---- current crontab:"
    printf "%s\n" "$current_cron"
    say "---- proposed crontab after removal:"
    printf "%s\n" "$new_cron"
  else
    if [[ -n "$new_cron" ]]; then
      printf "%s\n" "$new_cron" | crontab -
    else
      crontab -r 2>/dev/null || true
    fi
  fi
fi

#####################################
# 6) Final: clean empty subdirs then try /etc/patchmon again
#####################################
if [[ -d "$CONF_DIR" ]]; then
  # Remove any empty subdirectories first
  doit "find '$CONF_DIR' -type d -empty -delete"
  # Only remove /etc/patchmon if it is now empty of files and subdirs
  if [[ -z "$(find "$CONF_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    say "• '$CONF_DIR' appears empty -> will remove directory"
    doit "rmdir '$CONF_DIR' || true"
  else
    say "• '$CONF_DIR' not empty -> leaving directory as-is"
  fi
fi

#####################################
# Summary
#####################################
echo
if (( found_any == 0 )); then
  say "No PatchMon files/processes/units were found. Nothing to do."
else
  if (( DRY_RUN )); then
    say "DRY-RUN complete. If this looks correct, run again with:  $0 --apply"
  else
    say "Removal complete. Suggested verification:"
    say "  - systemctl status patchmon-agent (should be not-found/inactive)"
    say "  - command -v patchmon-agent (should not find it)"
    say "  - crontab -l (should not contain patchmon-agent lines)"
    say "  - test -d /etc/patchmon || echo '/etc/patchmon removed'"
  fi
fi
