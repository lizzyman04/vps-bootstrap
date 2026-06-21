#!/usr/bin/env bash
#
# vps-setup.sh — A script to execute common setup tasks on a newly created VPS.
#
# Multi-distro (Debian/Ubuntu, RHEL/Rocky/Alma/Fedora). Idempotent where possible.
# Creates an admin user with an SSH key, hardens SSH (key-only, no root login),
# configures a firewall, installs fail2ban, and applies system updates — all in
# a single command.
#
# WHY THE DEFENSIVE STYLE: this script encodes lessons learned the hard way —
#   * It NEVER changes the SSH port via systemd socket without binding BOTH
#     0.0.0.0 AND [::] explicitly (a bare "ListenStream=PORT" can end up
#     IPv6-only and lock you out).
#   * It configures fail2ban's ignoreip BEFORE the jail is active, so the
#     machine you run this from is never auto-banned mid-setup.
#   * It validates sshd config with `sshd -t` BEFORE restarting sshd. A bad
#     config aborts instead of bricking remote access.
#   * It writes the admin SSH key BEFORE disabling password auth, and refuses
#     to disable passwords if no key is present (prevents lockout).
#
# Usage:
#   sudo ./vps-setup.sh --user NAME --ssh-key "ssh-ed25519 AAAA... comment"
#
# Run `sudo ./vps-setup.sh --help` for all options.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via flags or environment)
# ---------------------------------------------------------------------------
ADMIN_USER=""
SSH_PUBKEY=""
SSH_PORT="22"                 # keep 22 unless you have a strong reason
DISABLE_PASSWORD_AUTH="yes"   # key-only SSH
DISABLE_ROOT_LOGIN="yes"
INSTALL_FAIL2BAN="yes"
INSTALL_FIREWALL="yes"
INSTALL_DOCKER="no"
DO_UPGRADE="yes"
EXTRA_TCP_PORTS=""            # e.g. "80,443"
IGNORE_IP=""                  # CIDR/IP allowed to bypass fail2ban (your admin IP)
ASSUME_YES="no"

LOG_PREFIX="[vps-setup]"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn() { printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2; }
die()  { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
vps-setup.sh — common setup tasks for a freshly created VPS (multi-distro)

REQUIRED:
  --user NAME              Admin (sudo) user to create.
  --ssh-key "KEY"          Public SSH key to install for that user.
                           (or --ssh-key-file PATH to read it from a file)

OPTIONAL:
  --ssh-port N             SSH port (default: 22).
  --extra-ports "80,443"   Extra TCP ports to open in the firewall.
  --ignore-ip CIDR         IP/CIDR exempt from fail2ban (your admin IP).
  --no-disable-password    Keep password auth enabled (NOT recommended).
  --no-disable-root        Keep direct root SSH login enabled.
  --no-fail2ban            Skip fail2ban.
  --no-firewall            Skip firewall setup.
  --no-upgrade             Skip system package upgrade.
  --with-docker            Install Docker Engine.
  --yes                    Run non-interactively (assume yes to prompts).
  --help                   Show this help.

EXAMPLE:
  sudo ./vps-setup.sh \
    --user lizzyman04 \
    --ssh-key-file ~/.ssh/id_ed25519.pub \
    --extra-ports "80,443" \
    --with-docker --yes
EOF
}

confirm() {
  # $1 = prompt. Returns 0 if yes.
  [ "$ASSUME_YES" = "yes" ] && return 0
  local reply
  read -r -p "$LOG_PREFIX $1 [y/N] " reply </dev/tty || true
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --user)               ADMIN_USER="$2"; shift 2 ;;
    --ssh-key)            SSH_PUBKEY="$2"; shift 2 ;;
    --ssh-key-file)       SSH_PUBKEY="$(cat "$2")"; shift 2 ;;
    --ssh-port)           SSH_PORT="$2"; shift 2 ;;
    --extra-ports)        EXTRA_TCP_PORTS="$2"; shift 2 ;;
    --ignore-ip)          IGNORE_IP="$2"; shift 2 ;;
    --no-disable-password) DISABLE_PASSWORD_AUTH="no"; shift ;;
    --no-disable-root)    DISABLE_ROOT_LOGIN="no"; shift ;;
    --no-fail2ban)        INSTALL_FAIL2BAN="no"; shift ;;
    --no-firewall)        INSTALL_FIREWALL="no"; shift ;;
    --no-upgrade)         DO_UPGRADE="no"; shift ;;
    --with-docker)        INSTALL_DOCKER="yes"; shift ;;
    --yes)                ASSUME_YES="yes"; shift ;;
    --help|-h)            usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."
[ -n "$ADMIN_USER" ] || die "--user is required."

# A key is mandatory unless you explicitly keep password auth on.
if [ -z "$SSH_PUBKEY" ] && [ "$DISABLE_PASSWORD_AUTH" = "yes" ]; then
  die "No SSH key given but password auth would be disabled — that locks you out. Provide --ssh-key/--ssh-key-file or pass --no-disable-password."
fi
if [ -n "$SSH_PUBKEY" ]; then
  case "$SSH_PUBKEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) : ;;
    *) die "SSH key doesn't look valid (must start with ssh-ed25519/ssh-rsa/ecdsa/sk-...)." ;;
  esac
fi

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------
PKG=""        # apt | dnf | yum
OS_FAMILY=""  # debian | rhel
detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PKG="apt"; OS_FAMILY="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"; OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG="yum"; OS_FAMILY="rhel"
  else
    die "Unsupported distro: no apt/dnf/yum found."
  fi
  log "Detected ${PRETTY_NAME:-unknown} (family: $OS_FAMILY, pkg: $PKG)"
}

pkg_update_index() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf) dnf -y makecache ;;
    yum) yum -y makecache ;;
  esac
}
pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
  esac
}
pkg_upgrade() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ;;
    dnf) dnf -y upgrade ;;
    yum) yum -y update ;;
  esac
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step_update() {
  log "Updating package index..."
  pkg_update_index
  if [ "$DO_UPGRADE" = "yes" ]; then
    log "Upgrading installed packages (may take a while)..."
    pkg_upgrade
  fi
}

step_base_tools() {
  log "Installing base tools..."
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg_install sudo ca-certificates curl ufw fail2ban || true
  else
    pkg_install sudo ca-certificates curl firewalld fail2ban || true
  fi
}

step_create_user() {
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    log "User '$ADMIN_USER' already exists — leaving it as is."
  else
    log "Creating user '$ADMIN_USER'..."
    useradd -m -s /bin/bash "$ADMIN_USER"
  fi
  # Add to sudo/wheel group
  if [ "$OS_FAMILY" = "debian" ]; then
    usermod -aG sudo "$ADMIN_USER"
  else
    usermod -aG wheel "$ADMIN_USER"
  fi
  # Passwordless sudo is NOT set — admin keeps a password for sudo by design.
  log "User '$ADMIN_USER' is now an administrator."
}

step_install_key() {
  [ -n "$SSH_PUBKEY" ] || { log "No SSH key to install — skipping."; return; }
  local home auth_dir auth_file
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  auth_dir="$home/.ssh"
  auth_file="$auth_dir/authorized_keys"
  log "Installing SSH key for '$ADMIN_USER'..."
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$auth_dir"
  # Append only if not already present (idempotent)
  touch "$auth_file"
  if ! grep -qF "$SSH_PUBKEY" "$auth_file" 2>/dev/null; then
    printf '%s\n' "$SSH_PUBKEY" >> "$auth_file"
  fi
  chmod 600 "$auth_file"
  chown "$ADMIN_USER:$ADMIN_USER" "$auth_file"
  log "Key installed."
}

step_firewall() {
  [ "$INSTALL_FIREWALL" = "yes" ] || { log "Firewall step skipped."; return; }
  log "Configuring firewall (allowing SSH port $SSH_PORT + extra ports)..."
  if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"
    if [ -n "$EXTRA_TCP_PORTS" ]; then
      IFS=',' read -ra _ports <<< "$EXTRA_TCP_PORTS"
      for p in "${_ports[@]}"; do ufw allow "${p//[[:space:]]/}/tcp"; done
    fi
    ufw --force enable
    ufw status verbose || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
    if [ -n "$EXTRA_TCP_PORTS" ]; then
      IFS=',' read -ra _ports <<< "$EXTRA_TCP_PORTS"
      for p in "${_ports[@]}"; do firewall-cmd --permanent --add-port="${p//[[:space:]]/}/tcp"; done
    fi
    firewall-cmd --reload
    firewall-cmd --list-all || true
  else
    warn "No ufw or firewalld available — skipping firewall."
  fi
}

step_ssh_port_socket() {
  # Only touch the systemd socket if the port is NOT 22 and ssh.socket is in use.
  [ "$SSH_PORT" != "22" ] || return 0
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    log "ssh.socket is in use — binding port $SSH_PORT on BOTH IPv4 and IPv6 explicitly..."
    install -d /etc/systemd/system/ssh.socket.d
    # CRITICAL: declare 0.0.0.0 AND [::] or you risk an IPv6-only listener.
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
  fi
}

step_harden_ssh() {
  log "Hardening SSH..."
  local dropin="/etc/ssh/sshd_config.d/99-vps-setup.conf"
  # Some images ship a 50-cloud-init.conf that re-enables PasswordAuthentication.
  # sshd uses the FIRST occurrence of a directive across files read in order,
  # so a lower-numbered file wins. Neutralize known offenders.
  local ci="/etc/ssh/sshd_config.d/50-cloud-init.conf"
  if [ -f "$ci" ] && grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$ci"; then
    log "Neutralizing PasswordAuthentication in 50-cloud-init.conf..."
    sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]]\+yes/# &/I' "$ci"
  fi

  install -d /etc/ssh/sshd_config.d 2>/dev/null || true
  {
    echo "# Managed by vps-setup.sh"
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    [ "$DISABLE_PASSWORD_AUTH" = "yes" ] && echo "PasswordAuthentication no"
    [ "$DISABLE_PASSWORD_AUTH" = "yes" ] && echo "KbdInteractiveAuthentication no"
    [ "$DISABLE_ROOT_LOGIN" = "yes" ]    && echo "PermitRootLogin no"
  } > "$dropin"

  # If sshd_config.d isn't included on this distro, append an include guard.
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    if [ -d /etc/ssh/sshd_config.d ]; then
      echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
    fi
  fi

  # VALIDATE before restarting — a bad config must not brick access.
  if ! sshd -t; then
    die "sshd config failed validation. NOT restarting. Review $dropin."
  fi
  log "sshd config valid. Restarting SSH service..."
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || \
    systemctl restart ssh.socket 2>/dev/null || warn "Could not restart SSH service."
}

step_fail2ban() {
  [ "$INSTALL_FAIL2BAN" = "yes" ] || { log "fail2ban step skipped."; return; }
  command -v fail2ban-server >/dev/null 2>&1 || pkg_install fail2ban || true
  log "Configuring fail2ban (jail for SSH on port $SSH_PORT)..."
  # Build ignoreip: ALWAYS include loopback; add admin IP if given.
  local ignore="127.0.0.1/8 ::1"
  [ -n "$IGNORE_IP" ] && ignore="$ignore $IGNORE_IP"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = $ignore
bantime  = 10m
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 1
  fail2ban-client status sshd 2>/dev/null || true
}

step_docker() {
  [ "$INSTALL_DOCKER" = "yes" ] || return 0
  log "Installing Docker Engine..."
  if [ "$OS_FAMILY" = "debian" ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    pkg_update_index
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    pkg_install dnf-plugins-core || true
    dnf config-manager --add-repo "https://download.docker.com/linux/${ID}/docker-ce.repo" 2>/dev/null || \
      yum-config-manager --add-repo "https://download.docker.com/linux/${ID}/docker-ce.repo" 2>/dev/null || true
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  fi
  systemctl enable --now docker || true
  usermod -aG docker "$ADMIN_USER" || true
  log "Docker installed; '$ADMIN_USER' added to docker group (re-login required)."
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
main() {
  detect_distro

  log "About to configure this VPS with:"
  log "  admin user        : $ADMIN_USER"
  log "  ssh port          : $SSH_PORT"
  log "  disable passwords : $DISABLE_PASSWORD_AUTH"
  log "  disable root login: $DISABLE_ROOT_LOGIN"
  log "  firewall          : $INSTALL_FIREWALL (extra ports: ${EXTRA_TCP_PORTS:-none})"
  log "  fail2ban          : $INSTALL_FAIL2BAN (ignoreip: ${IGNORE_IP:-loopback only})"
  log "  docker            : $INSTALL_DOCKER"
  log "  upgrade system    : $DO_UPGRADE"
  confirm "Proceed?" || die "Aborted by user."

  step_update
  step_base_tools
  step_create_user
  step_install_key
  step_firewall          # open the port BEFORE touching sshd
  step_ssh_port_socket   # safe IPv4+IPv6 port bind if changing port
  step_fail2ban          # ignoreip set BEFORE jail goes hot
  step_harden_ssh        # validated, key already in place
  step_docker

  cat >&2 <<EOF

$LOG_PREFIX =====================================================
$LOG_PREFIX  SETUP COMPLETE
$LOG_PREFIX =====================================================
$LOG_PREFIX  Connect with:
$LOG_PREFIX    ssh -p ${SSH_PORT} ${ADMIN_USER}@<server-ip>
$LOG_PREFIX
$LOG_PREFIX  IMPORTANT — before you log out of THIS session, open a
$LOG_PREFIX  NEW terminal and confirm the command above works. If it
$LOG_PREFIX  doesn't, fix it from this still-open session (or the
$LOG_PREFIX  provider's VNC/serial console) before disconnecting.
$LOG_PREFIX
$LOG_PREFIX  Set a strong password for '${ADMIN_USER}' (used for sudo):
$LOG_PREFIX    sudo passwd ${ADMIN_USER}
$LOG_PREFIX =====================================================
EOF
}

main "$@"
