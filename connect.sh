#!/usr/bin/env bash
#
# connect.sh — run from YOUR OWN machine to bootstrap a freshly-bought VPS.
#
# It connects to the server over SSH and runs setup.sh there. The whole point
# is to remove the friction of configuring a new VPS WITHOUT this script ever
# touching the server's root password.
#
# SECURITY — how the password is handled:
#   This script NEVER reads, stores, passes, or echoes the root password.
#   There is no sshpass, no expect, and the password is never a command
#   argument. You type it exactly once, at OpenSSH's own native prompt, which
#   is designed to keep it off the screen and out of any process arguments.
#
# What it does:
#   1. Asks (interactively) for the server IP and the SSH username (default root).
#   2. Optionally asks for a local SSH PUBLIC key to install for the new admin.
#   3. Opens an interactive SSH session (ssh -t) and runs setup.sh on the remote
#      by piping it from raw.githubusercontent.com. SSH prompts for the password
#      itself; setup.sh's interactive wizard runs over the same TTY.
#
# Usage:
#   bash connect.sh
#   curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/connect.sh | bash
#
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/setup.sh"
LOG_PREFIX="[connect]"

log()  { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn() { printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

# All prompts read from /dev/tty so this works even when run via `curl ... | bash`.
ask() {
  # $1 = prompt, $2 = default (may be empty). Echoes the chosen value.
  local prompt="$1" def="${2:-}" reply
  if [ -n "$def" ]; then
    read -r -p "$LOG_PREFIX $prompt [$def]: " reply </dev/tty || true
    printf '%s' "${reply:-$def}"
  else
    read -r -p "$LOG_PREFIX $prompt: " reply </dev/tty || true
    printf '%s' "$reply"
  fi
}

confirm() {
  # $1 = prompt. Returns 0 if yes.
  local reply
  read -r -p "$LOG_PREFIX $1 [y/N] " reply </dev/tty || true
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

valid_ip() {
  # Accept IPv4 (strict octets) or a loose IPv6 literal.
  local ip="$1" n
  if [[ "$ip" == *:* ]]; then
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && return 0 || return 1
  fi
  local IFS=. parts
  read -ra parts <<< "$ip"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for n in "${parts[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
  done
  return 0
}

valid_ssh_key() {
  case "$1" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) return 0 ;;
    *) return 1 ;;
  esac
}

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

command -v ssh >/dev/null 2>&1 || die "ssh is not installed on this machine. Install OpenSSH client first."

# Ensure we have a usable terminal for the prompts.
if ! { : < /dev/tty; } 2>/dev/null; then
  die "No terminal available — run connect.sh from an interactive shell."
fi

cat >&2 <<EOF
$LOG_PREFIX =====================================================
$LOG_PREFIX  Bootstrap a freshly-bought VPS from your own machine
$LOG_PREFIX =====================================================
$LOG_PREFIX  This connects over SSH and runs the setup on the server.
$LOG_PREFIX  Your server password is typed ONCE, at SSH's own prompt —
$LOG_PREFIX  this script never sees, stores, or passes it.
$LOG_PREFIX =====================================================
EOF

# --- Server IP (required, validated) ---------------------------------------
SERVER_IP=""
while true; do
  SERVER_IP="$(ask "Server IP address" "")"
  [ -z "$SERVER_IP" ] && { warn "Server IP is required."; continue; }
  valid_ip "$SERVER_IP" && break
  warn "That doesn't look like a valid IP address. Try again."
done

# --- SSH username (default root) -------------------------------------------
SSH_USER="$(ask "SSH username to connect as" "root")"

# --- Optional local SSH PUBLIC key to install ------------------------------
# Suggest a sensible default if the user already has one.
DEFAULT_PUBKEY=""
for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$cand" ] && { DEFAULT_PUBKEY="$cand"; break; }
done

if [ -z "$DEFAULT_PUBKEY" ]; then
  warn "No local SSH key found (~/.ssh/id_ed25519.pub or id_rsa.pub)."
  warn "Generate one with:  ssh-keygen -t ed25519"
  warn "You can continue without one and decide on the server, but key-based"
  warn "access is strongly recommended."
fi

PUBKEY_CONTENT=""
while true; do
  PUBKEY_PATH="$(ask "Path to a local SSH PUBLIC key to install (empty to decide on the server)" "$DEFAULT_PUBKEY")"
  [ -z "$PUBKEY_PATH" ] && break
  if [ ! -f "$PUBKEY_PATH" ]; then
    warn "No such file: $PUBKEY_PATH"
    continue
  fi
  PUBKEY_CONTENT="$(cat "$PUBKEY_PATH")"
  if valid_ssh_key "$PUBKEY_CONTENT"; then
    break
  fi
  warn "That file doesn't look like a public key (expected ssh-ed25519/ssh-rsa/ecdsa-sha2-/sk-...)."
  warn "Did you point at the PRIVATE key by mistake? Use the .pub file."
  PUBKEY_CONTENT=""
done

# --- Build the remote command ----------------------------------------------
# The public key is NOT secret; it is safe to pass as an argument. The password
# is never part of this command — SSH prompts for it interactively.
REMOTE_CMD="curl -fsSL $RAW_URL | sudo bash -s --"
if [ -n "$PUBKEY_CONTENT" ]; then
  REMOTE_CMD="$REMOTE_CMD --ssh-key '$PUBKEY_CONTENT'"
fi

# --- Summary + confirm ------------------------------------------------------
cat >&2 <<EOF
$LOG_PREFIX -----------------------------------------------------
$LOG_PREFIX  About to:
$LOG_PREFIX    connect : ssh -t $SSH_USER@$SERVER_IP
$LOG_PREFIX    ssh key : ${PUBKEY_PATH:-none (you'll be asked on the server)}
$LOG_PREFIX    then run: setup.sh (its wizard will ask for the rest)
$LOG_PREFIX
$LOG_PREFIX  You will be asked for the server password by SSH itself.
$LOG_PREFIX  This script never sees or stores it.
$LOG_PREFIX -----------------------------------------------------
EOF
confirm "Proceed?" || die "Aborted by user."

log "Connecting... (enter the server password at SSH's prompt)"
exec ssh -t "$SSH_USER@$SERVER_IP" "$REMOTE_CMD"
