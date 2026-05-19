#!/usr/bin/env bash
# Smart Port Billing Infrastructure — User & Group Provisioning
# RHCSA Skills: User/Group Management, Password Policy, Sudo Configuration
# Run as root on RHEL 9 | Pass --dry-run to preview without making changes
set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# ── Colours ──────────────────────────────────────────────────────────────────
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

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && ! $DRY_RUN && die "Must be run as root."
log "Starting Port Billing user provisioning..."

# ── Department Groups ─────────────────────────────────────────────────────────
declare -A DEPT_GROUPS=(
    [billing-admin]="Port Billing Administrators"
    [billing-ops]="Billing Operations Team"
    [port-ops]="Port Operations Team"
    [billing-readonly]="Billing Read-Only Auditors"
)

for grp in "${!DEPT_GROUPS[@]}"; do
    if ! $DRY_RUN && getent group "$grp" &>/dev/null; then
        warn "Group '$grp' already exists — skipping"
    else
        run groupadd --system "$grp"
        ok "Created group: $grp (${DEPT_GROUPS[$grp]})"
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
    if ! $DRY_RUN && id "$uname" &>/dev/null; then
        warn "User '$uname' already exists — skipping"
        continue
    fi
    run useradd \
        --gid "$ugroup" \
        --groups "$ugroup" \
        --comment "$ucomment" \
        --create-home \
        --shell /bin/bash \
        --password "$(openssl passwd -6 'ChangeMe@2024!')" \
        "$uname"
    run chage --lastday 0 "$uname"
    ok "Created user: $uname → group: $ugroup"
done

# ── Password Policy ───────────────────────────────────────────────────────────
for entry in "${USERS[@]}"; do
    uname="${entry%%:*}"
    run chage \
        --maxdays   90 \
        --mindays    7 \
        --warndays  14 \
        --inactive  30 \
        "$uname"
    ok "Password policy applied: $uname"
done

# ── Sudo Configuration ────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/portbill-billing-admin"
if $DRY_RUN; then
    dry "Would write sudoers file: $SUDOERS_FILE"
    dry "  %billing-admin: systemctl start/stop/restart/status portbill"
    dry "  %billing-admin: useradd, usermod, userdel"
    dry "  %billing-readonly: journalctl -u portbill (NOPASSWD)"
else
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
fi
ok "Sudo rules written: $SUDOERS_FILE"

# ── Home Directory Permissions ────────────────────────────────────────────────
for entry in "${USERS[@]}"; do
    uname="${entry%%:*}"
    home="/home/$uname"
    if ! $DRY_RUN && [[ ! -d "$home" ]]; then continue; fi
    run chmod 0750 "$home"
    ok "Secured home: $home (0750)"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
$DRY_RUN && \
echo -e "${BOLD}${CYAN}║   User Provisioning — DRY RUN Complete    ║${RESET}" || \
echo -e "${BOLD}${CYAN}║   User Provisioning Complete              ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo -e "  Groups : ${#DEPT_GROUPS[@]}   Users : ${#USERS[@]}"
echo -e "  Sudo config     : $SUDOERS_FILE"
echo -e "  Default password: ChangeMe@2024! (forced change on login)"
$DRY_RUN && echo -e "  ${MAGENTA}No system changes were made.${RESET}"
echo ""
