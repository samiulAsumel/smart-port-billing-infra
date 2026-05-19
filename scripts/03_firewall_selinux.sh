#!/usr/bin/env bash
# Smart Port Billing Infrastructure — Firewall & SELinux Hardening
# RHCSA Skills: firewalld Zone Management, Rich Rules, SELinux Contexts & Booleans
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
BILLING_ZONE="portbilling"
TRUSTED_ADMIN_CIDR="192.168.10.0/24"
BILLING_CLIENT_CIDR="10.10.0.0/16"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && ! $DRY_RUN && die "Must be run as root."
if ! $DRY_RUN; then
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
else
    dry "Would verify: firewalld running, SELinux enforcing"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — FIREWALLD
# ══════════════════════════════════════════════════════════════════════════════
log "Configuring firewalld zones..."

if $DRY_RUN; then
    dry "firewall-cmd --permanent --new-zone=$BILLING_ZONE"
else
    if ! firewall-cmd --permanent --get-zones | grep -qw "$BILLING_ZONE"; then
        firewall-cmd --permanent --new-zone="$BILLING_ZONE"
        ok "Zone created: $BILLING_ZONE"
    else
        warn "Zone '$BILLING_ZONE' already exists — reconfiguring"
    fi
fi

# ── Public Zone ───────────────────────────────────────────────────────────────
run firewall-cmd --permanent --zone=public --remove-service=ssh
run firewall-cmd --permanent --zone=public --set-target=DROP
ok "Public zone: target=DROP, SSH removed"

# ── Billing Zone ──────────────────────────────────────────────────────────────
run firewall-cmd --permanent --zone="$BILLING_ZONE" --add-service=https
run firewall-cmd --permanent --zone="$BILLING_ZONE" --add-service=http

run firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' source address='${TRUSTED_ADMIN_CIDR}' port port='${SSH_PORT}' protocol='tcp' accept"
ok "Rich rule: SSH port $SSH_PORT allowed from $TRUSTED_ADMIN_CIDR"

run firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' source address='${BILLING_CLIENT_CIDR}' service name='https' accept"
ok "Rich rule: HTTPS allowed from billing LAN $BILLING_CLIENT_CIDR"

run firewall-cmd --permanent --zone="$BILLING_ZONE" \
    --add-rich-rule="rule family='ipv4' service name='http' limit value='100/m' accept"
ok "Rich rule: HTTP rate-limited to 100 connections/min"

run firewall-cmd --permanent --zone="$BILLING_ZONE" --set-target=REJECT
run firewall-cmd --reload
ok "firewalld reloaded — all rules applied"

# ── Assign Network Interface ──────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would detect primary NIC and assign to zone: $BILLING_ZONE"
else
    PRIMARY_IF=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
    if [[ -n "$PRIMARY_IF" ]]; then
        firewall-cmd --permanent --zone="$BILLING_ZONE" --add-interface="$PRIMARY_IF" 2>/dev/null || \
            firewall-cmd --permanent --zone="$BILLING_ZONE" --change-interface="$PRIMARY_IF"
        firewall-cmd --reload
        ok "Interface $PRIMARY_IF assigned to zone: $BILLING_ZONE"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — SELINUX
# ══════════════════════════════════════════════════════════════════════════════
log "Configuring SELinux policies for port billing..."

# ── Custom SSH Port Context ───────────────────────────────────────────────────
if $DRY_RUN; then
    dry "semanage port --add --type ssh_port_t --proto tcp $SSH_PORT"
    ok "SELinux port context: $SSH_PORT/tcp → ssh_port_t  [dry]"
elif semanage port --list | grep -q "^ssh_port_t.*${SSH_PORT}"; then
    warn "SELinux: SSH port $SSH_PORT already labelled ssh_port_t"
else
    semanage port --add --type ssh_port_t --proto tcp "$SSH_PORT"
    ok "SELinux port context: $SSH_PORT/tcp → ssh_port_t"
fi

# ── File Contexts ─────────────────────────────────────────────────────────────
declare -A FCONTEXTS=(
    ["/srv/portbill/data(/.*)?"]="httpd_sys_content_t"
    ["/srv/portbill/logs(/.*)?"]="httpd_log_t"
    ["/srv/portbill/backup(/.*)?"]="var_t"
    ["/etc/nginx/conf.d(/.*)?"]="httpd_config_t"
)

for fpath in "${!FCONTEXTS[@]}"; do
    ftype="${FCONTEXTS[$fpath]}"
    if $DRY_RUN; then
        dry "semanage fcontext: $fpath → $ftype"
    else
        semanage fcontext --add --type "$ftype" "$fpath" 2>/dev/null || \
            semanage fcontext --modify --type "$ftype" "$fpath"
    fi
    ok "SELinux fcontext: $fpath → $ftype"
done

if $DRY_RUN; then
    dry "restorecon -Rv /srv/portbill/ /etc/nginx/"
else
    restorecon -Rv /srv/portbill/ /etc/nginx/ 2>/dev/null || true
fi
ok "restorecon applied to /srv/portbill/ and /etc/nginx/"

# ── SELinux Booleans ──────────────────────────────────────────────────────────
declare -A BOOLEANS=(
    [httpd_can_network_connect]="on"
    [httpd_read_user_content]="off"
    [httpd_enable_homedirs]="off"
    [httpd_use_nfs]="off"
)

for bool_name in "${!BOOLEANS[@]}"; do
    bool_val="${BOOLEANS[$bool_name]}"
    run setsebool -P "$bool_name" "$bool_val"
    ok "SELinux boolean: $bool_name=$bool_val (persistent)"
done

# ── Verification ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── Firewall Status ─────────────────────────${RESET}"
if $DRY_RUN; then
    dry "firewall-cmd --zone=$BILLING_ZONE --list-all"
    dry "sestatus | head -5"
    echo -e "  ${MAGENTA}No system changes were made.${RESET}"
else
    firewall-cmd --zone="$BILLING_ZONE" --list-all
    echo -e "\n${BOLD}${CYAN}── SELinux Status ──────────────────────────${RESET}"
    sestatus | head -5
    semanage port --list | grep -E "ssh_port_t.*${SSH_PORT}|^ssh_port_t"
fi
echo ""
ok "Firewall & SELinux hardening complete."
