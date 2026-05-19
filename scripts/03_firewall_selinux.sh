#!/usr/bin/env bash
# Smart Port Billing Infrastructure — Firewall & SELinux Hardening
# RHCSA Skills: firewalld Zone Management, Rich Rules, SELinux Contexts & Booleans
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
BILLING_ZONE="portbilling"
TRUSTED_ADMIN_CIDR="192.168.10.0/24"   # Admin workstation subnet
BILLING_CLIENT_CIDR="10.10.0.0/16"     # Port operations LAN

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root."
command -v firewall-cmd &>/dev/null || die "firewalld not found: dnf install -y firewalld"
command -v semanage    &>/dev/null || die "semanage not found: dnf install -y policycoreutils-python-utils"

systemctl is-active --quiet firewalld || systemctl start firewalld
ok "firewalld is running"

getenforce | grep -qiE '^enforcing$' || {
    warn "SELinux not in enforcing mode — enabling..."
    setenforce 1
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    ok "SELinux set to enforcing (persistent)"
}

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — FIREWALLD
# ══════════════════════════════════════════════════════════════════════════════
log "Configuring firewalld zones..."

# Create dedicated billing zone (idempotent)
if ! firewall-cmd --permanent --get-zones | grep -qw "$BILLING_ZONE"; then
    firewall-cmd --permanent --new-zone="$BILLING_ZONE"
    ok "Zone created: $BILLING_ZONE"
else
    warn "Zone '$BILLING_ZONE' already exists — reconfiguring"
fi

# ── Public Zone — minimal exposure ────────────────────────────────────────────
firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true
firewall-cmd --permanent --zone=public --set-target=DROP
ok "Public zone: target=DROP, SSH removed"

# ── Billing Zone — web + custom SSH ──────────────────────────────────────────
# Allow HTTPS for billing portal
firewall-cmd --permanent --zone="$BILLING_ZONE" --add-service=https
firewall-cmd --permanent --zone="$BILLING_ZONE" --add-service=http

# Custom SSH port in billing zone — restricted to admin subnet only
firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' source address='${TRUSTED_ADMIN_CIDR}' port port='${SSH_PORT}' protocol='tcp' accept"
ok "Rich rule: SSH port $SSH_PORT allowed from $TRUSTED_ADMIN_CIDR"

# Allow billing client LAN to reach HTTP/HTTPS
firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' source address='${BILLING_CLIENT_CIDR}' service name='https' accept"
ok "Rich rule: HTTPS allowed from billing LAN $BILLING_CLIENT_CIDR"

# Rate-limit new connections to prevent billing portal abuse
firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' service name='http' limit value='100/m' accept"
ok "Rich rule: HTTP rate-limited to 100 connections/min"

# Reject (not drop) everything else for better diagnostics
firewall-cmd --permanent --zone="$BILLING_ZONE" --set-target=REJECT

# Apply all changes
firewall-cmd --reload
ok "firewalld reloaded — all rules applied"

# ── Assign Network Interfaces to Zones ───────────────────────────────────────
# Detect primary interface (first non-loopback)
PRIMARY_IF=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
if [[ -n "$PRIMARY_IF" ]]; then
    firewall-cmd --permanent --zone="$BILLING_ZONE" --add-interface="$PRIMARY_IF" 2>/dev/null || \
        firewall-cmd --permanent --zone="$BILLING_ZONE" --change-interface="$PRIMARY_IF"
    firewall-cmd --reload
    ok "Interface $PRIMARY_IF assigned to zone: $BILLING_ZONE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — SELINUX
# ══════════════════════════════════════════════════════════════════════════════
log "Configuring SELinux policies for port billing..."

# ── Custom SSH Port Context ───────────────────────────────────────────────────
if semanage port --list | grep -q "^ssh_port_t.*${SSH_PORT}"; then
    warn "SELinux: SSH port $SSH_PORT already labelled ssh_port_t"
else
    semanage port --add --type ssh_port_t --proto tcp "$SSH_PORT"
    ok "SELinux port context: $SSH_PORT/tcp → ssh_port_t"
fi

# ── Nginx / Application File Contexts ────────────────────────────────────────
declare -A FCONTEXTS=(
    ["/srv/portbill/data(/.*)?"]="httpd_sys_content_t"
    ["/srv/portbill/logs(/.*)?"]="httpd_log_t"
    ["/srv/portbill/backup(/.*)?"]="var_t"
    ["/etc/nginx/conf.d(/.*)?"]="httpd_config_t"
)

for fpath in "${!FCONTEXTS[@]}"; do
    ftype="${FCONTEXTS[$fpath]}"
    semanage fcontext --add --type "$ftype" "$fpath" 2>/dev/null || \
        semanage fcontext --modify --type "$ftype" "$fpath"
    ok "SELinux fcontext: $fpath → $ftype"
done

restorecon -Rv /srv/portbill/ /etc/nginx/ 2>/dev/null || true
ok "restorecon applied to /srv/portbill/ and /etc/nginx/"

# ── SELinux Booleans ──────────────────────────────────────────────────────────
declare -A BOOLEANS=(
    [httpd_can_network_connect]="on"        # Nginx → Podman proxy
    [httpd_read_user_content]="off"         # Least privilege
    [httpd_enable_homedirs]="off"           # Least privilege
    [httpd_use_nfs]="off"                   # Not using NFS
)

for bool_name in "${!BOOLEANS[@]}"; do
    bool_val="${BOOLEANS[$bool_name]}"
    setsebool -P "$bool_name" "$bool_val"
    ok "SELinux boolean: $bool_name=$bool_val (persistent)"
done

# ── Verification ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── Firewall Status ─────────────────────────${RESET}"
firewall-cmd --zone="$BILLING_ZONE" --list-all

echo -e "\n${BOLD}${CYAN}── SELinux Status ──────────────────────────${RESET}"
sestatus | head -5
semanage port --list | grep -E "ssh_port_t.*${SSH_PORT}|^ssh_port_t"
echo ""
ok "Firewall & SELinux hardening complete."
