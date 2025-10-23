#!/usr/bin/env bash
# once — run a command at most once per period or rolling window
# Bash + coreutils. Designed to be ShellCheck-clean.

set -euo pipefail

VERSION="1.0.1"

# Defaults
STATE_DIR="${XDG_STATE_HOME:-"$HOME/.local/state"}/once"
PERIOD=""          # hour|day|week|month (calendar)
WINDOW=""          # e.g. 6h|24h|90m|2d (rolling)
KEY_EXTRA=""
FORCE=0
DRY_RUN=0
EXPLAIN=0

usage() {
  cat <<EOF
Usage:
  once [--period {hour|day|week|month} | --window {6h|24h|2d}] [options] -- <command> [args...]

Options:
  --period P         Calendar period: hour|day|week|month
  --window D         Rolling window: 1h, 30m, 2d, etc.
  --key-extra STR    Add extra material to the identity key
  --state-dir DIR    Override state dir (default: ${STATE_DIR})
  --force            Force execution (ignore stamps)
  --dry-run          Report action but don't execute
  --explain          Print derived identity/bucket/paths
  -h|--help          Show help and exit

Exit codes:
  0 executed (or would execute with --dry-run)
  1 underlying command failed or bad usage
  3 skipped due to period/window rule
  4 another instance already running for this key
EOF
}

log() { printf '%s\n' "$*" >&2; }

ensure_dir() {
  # 0700 perms, safe if exists
  if [[ ! -d "$1" ]]; then
    umask 077
    mkdir -p -- "$1"
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
  else
    log "Need sha256sum, shasum, or openssl."
    exit 1
  fi
}

parse_duration() {
  # Accept Ns|Nm|Nh|Nd|Nw or raw seconds. Validate N is integer.
  local d="$1" n
  case "$d" in
    *s) n=${d%s} ;;
    *m) n=${d%m}; n=$(( n*60 )) ;;
    *h) n=${d%h}; n=$(( n*3600 )) ;;
    *d) n=${d%d}; n=$(( n*86400 )) ;;
    *w) n=${d%w}; n=$(( n*604800 )) ;;
    *)  n=$d ;;
  esac
  [[ "$n" =~ ^[0-9]+$ ]] || { log "Invalid duration: $d"; return 1; }
  printf '%s\n' "$n"
}

period_bucket() {
  # hour→YYYY-MM-DDTHH, day→YYYY-MM-DD, month→YYYY-MM
  # week→ISO week YYYY-Www (requires GNU date or gdate)
  case "$1" in
    hour)  date +%Y-%m-%dT%H ;;
    day)   date +%Y-%m-%d ;;
    month) date +%Y-%m ;;
    week)
      if date +%G-W%V >/dev/null 2>&1; then
        date +%G-W%V
      elif command -v gdate >/dev/null 2>&1; then
        gdate +%G-W%V
      else
        log "ISO week bucket needs GNU date (date +%G-W%V) or gdate."
        return 1
      fi
      ;;
    *) log "Invalid --period '$1'"; return 1 ;;
  esac
}

abs_on_path() {
  # Resolve an executable to an absolute path (no symlink canonicalization).
  # We prefer not to use realpath to avoid portability issues.
  local found
  found=$(command -v -- "$1" || true)
  [[ -n "$found" ]] || { log "Command not found: $1"; return 1; }
  printf '%s\n' "$found"
}

file_mtime_epoch() {
  # Linux stat, then macOS/BSD stat
  local f="$1"
  if stat -c %Y -- "$f" >/dev/null 2>&1; then
    stat -c %Y -- "$f"
  elif stat -f %m -- "$f" >/dev/null 2>&1; then
    stat -f %m -- "$f"
  else
    log "Cannot get mtime for: $f"
    return 1
  fi
}

lock_acquire() {
  # Atomic mkdir lock; cleaned via trap on EXIT
  local lock="$1"
  if mkdir -- "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid"
    trap 'rm -rf -- "'"$lock"'" >/dev/null 2>&1 || true' EXIT
    return 0
  fi
  return 1
}

# ---------- Parse args ----------
if [[ $# -eq 0 ]]; then usage; exit 0; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --period)   [[ $# -ge 2 ]] || { log "--period needs a value"; exit 1; }
                PERIOD="$2"; shift 2 ;;
    --window)   [[ $# -ge 2 ]] || { log "--window needs a value"; exit 1; }
                WINDOW="$2"; shift 2 ;;
    --key-extra) [[ $# -ge 2 ]] || { log "--key-extra needs a value"; exit 1; }
                KEY_EXTRA="$2"; shift 2 ;;
    --state-dir) [[ $# -ge 2 ]] || { log "--state-dir needs a value"; exit 1; }
                STATE_DIR="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --explain)  EXPLAIN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    --) shift; break ;;
    *)  break ;;
  esac
done

if [[ -n "$PERIOD" && -n "$WINDOW" ]]; then
  log "Use either --period or --window, not both."
  exit 1
fi
if [[ -z "$PERIOD" && -z "$WINDOW" ]]; then
  PERIOD="day"
fi
if [[ $# -lt 1 ]]; then
  log "Missing command after --"
  exit 1
fi

# ---------- Identity ----------
# Capture the command *exactly as passed* after `--`
declare -a CMD=("$@")
ABS_CMD=""
if [[ "${CMD[0]}" == */* ]]; then
  # Has a slash: treat as path
  # shellcheck disable=SC2164
  ABS_CMD="$(cd -- "$(dirname -- "${CMD[0]}")" && pwd -P)/$(basename -- "${CMD[0]}")"
else
  ABS_CMD="$(abs_on_path "${CMD[0]}")"
fi

CWD="$(pwd -P)"

# Identity string (no secrets stored beyond argv; consider redaction if needed)
IDENTITY=$'exe='"$ABS_CMD"$'\nargs='"${CMD[*]}"$'\ncwd='"$CWD"$'\nextra='"$KEY_EXTRA"
HASH="$(printf '%s' "$IDENTITY" | sha256_stdin)"

LOCK_DIR="${STATE_DIR}/locks/${HASH}.lock"
ensure_dir "${STATE_DIR}/locks"

# Precompute stamp locations (for --explain)
STAMP=""
BUCKET=""
if [[ -n "$PERIOD" ]]; then
  BUCKET="$(period_bucket "$PERIOD")" || { log "Bad period"; exit 1; }
  STAMP="${STATE_DIR}/periods/${BUCKET}/${HASH}.stamp"
else
  STAMP="${STATE_DIR}/windows/${HASH}.stamp"
fi

if (( EXPLAIN )); then
  printf '%s\n' "[once] v${VERSION}"
  printf '  period:   %s\n' "${PERIOD:-"(none)"}"
  printf '  window:   %s\n' "${WINDOW:-"(none)"}"
  printf '  bucket:   %s\n' "${BUCKET:-"(n/a)"}"
  printf '  state:    %s\n' "$STATE_DIR"
  printf '  lock:     %s\n' "$LOCK_DIR"
  printf '  stamp:    %s\n' "$STAMP"
  printf '  hash:     %s\n' "$HASH"
fi

# ---------- Forced run ----------
if (( FORCE )); then
  if (( DRY_RUN )); then
    log "DRY-RUN: would RUN (forced) → ${CMD[*]}"
    exit 0
  fi
  if ! lock_acquire "$LOCK_DIR"; then
    log "Another instance is already running for this key."
    exit 4
  fi
  # Record stamp on success even for force
  if "${CMD[@]}"; then
    if [[ -n "$PERIOD" ]]; then
      ensure_dir "$(dirname -- "$STAMP")"
      : >"$STAMP"
    else
      ensure_dir "$(dirname -- "$STAMP")"
      : >"$STAMP"
    fi
    exit 0
  fi
  exit 1
fi

# ---------- Acquire lock ----------
if ! lock_acquire "$LOCK_DIR"; then
  log "Another instance is already running for this key."
  exit 4
fi

# ---------- Decision & run ----------
if [[ -n "$PERIOD" ]]; then
  # Calendar semantics
  if [[ -f "$STAMP" ]]; then
    if (( DRY_RUN )); then
      log "DRY-RUN: would SKIP (already ran during $BUCKET)"
      exit 3
    fi
    log "Skipped: already ran during $BUCKET."
    exit 3
  fi

  if (( DRY_RUN )); then
    log "DRY-RUN: would RUN (first run in $PERIOD: $BUCKET) → ${CMD[*]}"
    exit 0
  fi

  if "${CMD[@]}"; then
    ensure_dir "$(dirname -- "$STAMP")"
    : >"$STAMP"
    exit 0
  else
    # Do not stamp on failure
    exit 1
  fi

else
  # Rolling window semantics
  local_secs="$(parse_duration "$WINDOW")" || exit 1
  ensure_dir "$(dirname -- "$STAMP")"

  if [[ -f "$STAMP" ]]; then
    now="$(date +%s)"
    mtime="$(file_mtime_epoch "$STAMP")"
    # Guard against clock skew or weird mtimes:
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
      elapsed=$(( now - mtime ))
      if (( elapsed < local_secs )); then
        if (( DRY_RUN )); then
          log "DRY-RUN: would SKIP (ran ${elapsed}s ago; window $WINDOW)"
          exit 3
        fi
        log "Skipped: ran ${elapsed}s ago; window $WINDOW."
        exit 3
      fi
    fi
  fi

  if (( DRY_RUN )); then
    log "DRY-RUN: would RUN (window $WINDOW satisfied) → ${CMD[*]}"
    exit 0
  fi

  if "${CMD[@]}"; then
    : >"$STAMP"
    exit 0
  else
    exit 1
  fi
fi
