#!/usr/bin/env bash
# Smart Port Billing Infrastructure — User & Group Provisioning
# RHCSA Skills: User/Group Management, Password Policy, Sudo Configuration
# Run as root on RHEL 9
set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO${RESET}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]  OK  ${RESET}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${RESET}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${RESET}  $*" >&2; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root."
log "Starting Port Billing user provisioning..."

# ── Department Groups ─────────────────────────────────────────────────────────
declare -A GROUPS=(
    [billing-admin]="Port Billing Administrators"
    [billing-ops]="Billing Operations Team"
    [port-ops]="Port Operations Team"
    [billing-readonly]="Billing Read-Only Auditors"
)

for grp in "${!GROUPS[@]}"; do
    if getent group "$grp" &>/dev/null; then
        warn "Group '$grp' already exists — skipping"
    else
        groupadd --system "$grp"
        ok "Created group: $grp (${GROUPS[$grp]})"
    fi
done

# ── Department Users ──────────────────────────────────────────────────────────
# Format: username:group:comment
declare -a USERS=(
    "portadmin:billing-admin:Port Billing System Administrator"
    "billmgr:billing-ops:Billing Operations Manager"
    "portclerk:billing-ops:Port Billing Clerk"
    "opswatch:port-ops:Port Operations Watch Officer"
    "auditor:billing-readonly:Billing Compliance Auditor"
)

for entry in "${USERS[@]}"; do
    IFS=':' read -r uname ugroup ucomment <<< "$entry"
    if id "$uname" &>/dev/null; then
        warn "User '$uname' already exists — skipping"
        continue
    fi
    useradd \
        --gid "$ugroup" \
        --groups "$ugroup" \
        --comment "$ucomment" \
        --create-home \
        --shell /bin/bash \
        --password "$(openssl passwd -6 'ChangeMe@2024!')" \
        "$uname"
    # Force password change on first login
    chage --lastday 0 "$uname"
    ok "Created user: $uname → group: $ugroup"
done

# ── Password Policy ───────────────────────────────────────────────────────────
# Apply to all billing department users
for entry in "${USERS[@]}"; do
    uname="${entry%%:*}"
    chage \
        --maxdays   90 \
        --mindays    7 \
        --warndays  14 \
        --inactive  30 \
        "$uname"
    ok "Password policy applied: $uname"
done

# ── Sudo Configuration ────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/portbill-billing-admin"
cat > "$SUDOERS_FILE" <<'EOF'
# Port Billing — billing-admin sudo rules
# Allow billing admins to manage portbill service and billing directories
%billing-admin ALL=(ALL) /usr/bin/systemctl start portbill
%billing-admin ALL=(ALL) /usr/bin/systemctl stop portbill
%billing-admin ALL=(ALL) /usr/bin/systemctl restart portbill
%billing-admin ALL=(ALL) /usr/bin/systemctl status portbill
%billing-admin ALL=(ALL) /usr/sbin/useradd, /usr/sbin/usermod, /usr/sbin/userdel
%billing-admin ALL=(ALL) /usr/bin/journalctl -u portbill
%billing-readonly ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u portbill --no-pager
EOF
chmod 0440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE" || die "sudoers syntax error — aborting"
ok "Sudo rules written: $SUDOERS_FILE"

# ── Home Directory Permissions ────────────────────────────────────────────────
for entry in "${USERS[@]}"; do
    uname="${entry%%:*}"
    home="/home/$uname"
    [[ -d "$home" ]] || continue
    chmod 0750 "$home"
    ok "Secured home: $home (0750)"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   User Provisioning Complete              ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo -e "  Groups created  : ${#GROUPS[@]}"
echo -e "  Users created   : ${#USERS[@]}"
echo -e "  Sudo config     : $SUDOERS_FILE"
echo -e "  Default password: ChangeMe@2024! (forced change on login)"
echo ""
