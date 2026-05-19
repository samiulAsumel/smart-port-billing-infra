#!/usr/bin/env bash
# Smart Port Billing Infrastructure — SSH Hardening
# RHCSA Skills: SSH Configuration, Key-Based Authentication, Service Management
# Run as root on RHEL 9
set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO${RESET}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]  OK  ${RESET}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${RESET}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${RESET}  $*" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
SSH_PORT=2222
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.pre-hardening.$(date +%Y%m%d%H%M%S)"
ALLOWED_GROUPS="billing-admin"
BANNER_FILE="/etc/ssh/billing-banner"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root."
[[ -f "$SSHD_CONFIG" ]] || die "sshd_config not found at $SSHD_CONFIG"

# Backup original config
cp "$SSHD_CONFIG" "$SSHD_BACKUP"
ok "Backup created: $SSHD_BACKUP"

# ── Legal Warning Banner ──────────────────────────────────────────────────────
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
ok "Legal banner created: $BANNER_FILE"

# ── Apply Hardened sshd_config ────────────────────────────────────────────────
log "Writing hardened SSH configuration..."

# Helper: set or replace a directive (case-insensitive key match)
ssh_set() {
    local key="$1" val="$2"
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

# Authentication hardening
ssh_set "PermitRootLogin"          "no"
ssh_set "PubkeyAuthentication"     "yes"
ssh_set "PasswordAuthentication"   "no"
ssh_set "PermitEmptyPasswords"     "no"
ssh_set "ChallengeResponseAuthentication" "no"
ssh_set "KbdInteractiveAuthentication"    "no"
ssh_set "UsePAM"                   "yes"

# Restrict access to billing-admin group only
ssh_set "AllowGroups"              "$ALLOWED_GROUPS"

# Connection hardening
ssh_set "LoginGraceTime"           "30"
ssh_set "MaxAuthTries"             "3"
ssh_set "MaxSessions"              "5"
ssh_set "MaxStartups"              "5:30:10"
ssh_set "ClientAliveInterval"      "300"
ssh_set "ClientAliveCountMax"      "2"

# Disable unused features
ssh_set "X11Forwarding"            "no"
ssh_set "AllowAgentForwarding"     "no"
ssh_set "AllowTcpForwarding"       "no"
ssh_set "PermitTunnel"             "no"
ssh_set "GatewayPorts"             "no"
ssh_set "PermitUserEnvironment"    "no"

# Logging
ssh_set "LogLevel"                 "VERBOSE"
ssh_set "SyslogFacility"           "AUTHPRIV"

# Legal banner
ssh_set "Banner"                   "$BANNER_FILE"

# Secure algorithms only (RHEL 9 crypto policy compliant)
ssh_set "KexAlgorithms"            "curve25519-sha256,diffie-hellman-group14-sha256"
ssh_set "HostKeyAlgorithms"        "ssh-ed25519,rsa-sha2-512,rsa-sha2-256"
ssh_set "Ciphers"                  "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com"
ssh_set "MACs"                     "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"

ok "Hardened configuration written."

# ── Validate Config Before Restart ───────────────────────────────────────────
log "Validating sshd_config syntax..."
if ! sshd -t -f "$SSHD_CONFIG"; then
    warn "Config validation failed — restoring backup"
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    die "Restored original config. Review errors above."
fi
ok "Configuration syntax valid."

# ── Authorized Keys Setup ─────────────────────────────────────────────────────
ADMIN_HOME=$(getent passwd portadmin | cut -d: -f6)
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

# ── Restart SSH Service ───────────────────────────────────────────────────────
log "Restarting sshd..."
systemctl restart sshd
systemctl enable sshd
ok "sshd restarted and enabled."

# ── Verify SELinux Port Context ───────────────────────────────────────────────
if command -v semanage &>/dev/null; then
    if ! semanage port --list | grep -q "ssh_port_t.*${SSH_PORT}"; then
        warn "SELinux ssh_port_t not set for port $SSH_PORT — run 03_firewall_selinux.sh first"
    else
        ok "SELinux: port $SSH_PORT correctly labelled ssh_port_t"
    fi
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
echo -e "  Authorized keys    : ${AUTH_KEYS}"
echo ""
ss -tlnp | grep ":${SSH_PORT}"
ok "SSH hardening complete."
