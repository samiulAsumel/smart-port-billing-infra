#!/usr/bin/env bash
# Smart Port Billing Infrastructure — SSH Hardening
# RHCSA Skills: SSH Configuration, Key-Based Authentication, Service Management
# Run as root on RHEL 9 | Pass --dry-run to preview without making changes
set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO${RESET}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]  OK  ${RESET}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${RESET}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${RESET}  $*" >&2; exit 1; }
dry()  { echo -e "${MAGENTA}[DRY-RUN]${RESET}  $*"; }

# ── Dry-run mode ──────────────────────────────────────────────────────────────
DRY_RUN=false
for _a in "$@"; do [[ "$_a" == "--dry-run" ]] && DRY_RUN=true; done

run() {
    if $DRY_RUN; then dry "Would run: $*"; else "$@"; fi
}

$DRY_RUN && {
    echo -e "\n${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${MAGENTA}${BOLD}║  DRY-RUN MODE — no changes will be made  ║${RESET}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
}

# ── Configuration ─────────────────────────────────────────────────────────────
SSH_PORT=2222
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.pre-hardening.$(date +%Y%m%d%H%M%S)"
ALLOWED_GROUPS="billing-admin"
BANNER_FILE="/etc/ssh/billing-banner"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]          && ! $DRY_RUN && die "Must be run as root."
[[ -f "$SSHD_CONFIG" ]]    || $DRY_RUN   || die "sshd_config not found at $SSHD_CONFIG"

run cp "$SSHD_CONFIG" "$SSHD_BACKUP"
ok "Backup: $SSHD_BACKUP"

# ── Legal Warning Banner ──────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would write legal banner: $BANNER_FILE"
else
    cat > "$BANNER_FILE" <<'EOF'
╔══════════════════════════════════════════════════════════════════╗
║        SMART PORT BILLING INFRASTRUCTURE — AUTHORIZED ACCESS      ║
║                                                                    ║
║  This system is for AUTHORIZED PERSONNEL ONLY.                    ║
║  Unauthorized access or use is STRICTLY PROHIBITED and may be    ║
║  subject to civil and criminal penalties.                         ║
║  All activities on this system are monitored and recorded.        ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    chmod 0644 "$BANNER_FILE"
fi
ok "Legal banner: $BANNER_FILE"

# ── Apply Hardened sshd_config ────────────────────────────────────────────────
log "Writing hardened SSH configuration..."

ssh_set() {
    local key="$1" val="$2"
    if $DRY_RUN; then
        dry "sshd_config: $key → $val"
        return
    fi
    if grep -qiE "^#?[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$SSHD_CONFIG"
    else
        echo "${key} ${val}" >> "$SSHD_CONFIG"
    fi
    log "  $key → $val"
}

ssh_set "Port"                     "$SSH_PORT"
ssh_set "AddressFamily"            "inet"
ssh_set "ListenAddress"            "0.0.0.0"
ssh_set "PermitRootLogin"          "no"
ssh_set "PubkeyAuthentication"     "yes"
ssh_set "PasswordAuthentication"   "no"
ssh_set "PermitEmptyPasswords"     "no"
ssh_set "ChallengeResponseAuthentication" "no"
ssh_set "KbdInteractiveAuthentication"    "no"
ssh_set "UsePAM"                   "yes"
ssh_set "AllowGroups"              "$ALLOWED_GROUPS"
ssh_set "LoginGraceTime"           "30"
ssh_set "MaxAuthTries"             "3"
ssh_set "MaxSessions"              "5"
ssh_set "MaxStartups"              "5:30:10"
ssh_set "ClientAliveInterval"      "300"
ssh_set "ClientAliveCountMax"      "2"
ssh_set "X11Forwarding"            "no"
ssh_set "AllowAgentForwarding"     "no"
ssh_set "AllowTcpForwarding"       "no"
ssh_set "PermitTunnel"             "no"
ssh_set "GatewayPorts"             "no"
ssh_set "PermitUserEnvironment"    "no"
ssh_set "LogLevel"                 "VERBOSE"
ssh_set "SyslogFacility"           "AUTHPRIV"
ssh_set "Banner"                   "$BANNER_FILE"
ssh_set "KexAlgorithms"            "curve25519-sha256,diffie-hellman-group14-sha256"
ssh_set "HostKeyAlgorithms"        "ssh-ed25519,rsa-sha2-512,rsa-sha2-256"
ssh_set "Ciphers"                  "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com"
ssh_set "MACs"                     "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"

ok "Hardened configuration written."

# ── Validate & Restart ────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would validate: sshd -t -f $SSHD_CONFIG"
    dry "Would run: systemctl restart sshd && systemctl enable sshd"
else
    log "Validating sshd_config syntax..."
    if ! sshd -t -f "$SSHD_CONFIG"; then
        warn "Config validation failed — restoring backup"
        cp "$SSHD_BACKUP" "$SSHD_CONFIG"
        die "Restored original config. Review errors above."
    fi
    ok "Configuration syntax valid."
    systemctl restart sshd
    systemctl enable sshd
    ok "sshd restarted and enabled."
fi

# ── Authorized Keys Setup ─────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would create /home/portadmin/.ssh/authorized_keys (0600)"
    dry "WARNING: authorized_keys will be EMPTY — add public key before use"
else
    ADMIN_HOME=$(getent passwd portadmin | cut -d: -f6 2>/dev/null || echo "/home/portadmin")
    SSH_DIR="$ADMIN_HOME/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"
    chmod 0700 "$SSH_DIR"
    chown portadmin:billing-admin "$SSH_DIR"

    if [[ ! -f "$AUTH_KEYS" ]]; then
        touch "$AUTH_KEYS"
        chmod 0600 "$AUTH_KEYS"
        chown portadmin:billing-admin "$AUTH_KEYS"
        warn "authorized_keys created but EMPTY — add public key before restarting sshd!"
        warn "Command: echo '<your_pubkey>' >> $AUTH_KEYS"
    else
        ok "authorized_keys exists: $AUTH_KEYS"
    fi
fi

# ── Verify SELinux Port Context ───────────────────────────────────────────────
if ! $DRY_RUN && command -v semanage &>/dev/null; then
    if ! semanage port --list | grep -q "ssh_port_t.*${SSH_PORT}"; then
        warn "SELinux ssh_port_t not set for port $SSH_PORT — run 03_firewall_selinux.sh first"
    else
        ok "SELinux: port $SSH_PORT correctly labelled ssh_port_t"
    fi
else
    $DRY_RUN && dry "Would verify: semanage port --list | grep ssh_port_t.*$SSH_PORT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── SSH Hardening Summary ───────────────────${RESET}"
echo -e "  Listening port     : ${SSH_PORT}/tcp"
echo -e "  Root login         : DISABLED"
echo -e "  Password auth      : DISABLED (keys only)"
echo -e "  Allowed groups     : ${ALLOWED_GROUPS}"
echo -e "  Max auth tries     : 3"
echo -e "  Session timeout    : 300s idle (2 misses)"
echo -e "  Config backup      : ${SSHD_BACKUP}"
if $DRY_RUN; then
    echo -e "  ${MAGENTA}No system changes were made.${RESET}"
else
    ss -tlnp | grep ":${SSH_PORT}" || true
fi
echo ""
ok "SSH hardening complete."
