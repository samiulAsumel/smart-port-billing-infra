#!/usr/bin/env bash
# Smart Port Billing Infrastructure — ACL Configuration & Automated Backup
# RHCSA Skills: POSIX ACLs, setfacl/getfacl, Cron/Systemd Timer, Backup Integrity
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
DATA_DIR="/srv/portbill/data"
LOGS_DIR="/srv/portbill/logs"
BACKUP_DIR="/srv/portbill/backup"
BACKUP_SCRIPT="/usr/local/bin/portbill-backup"
BACKUP_RETENTION_DAYS=30
SYSTEMD_TIMER_DIR="/etc/systemd/system"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && ! $DRY_RUN && die "Must be run as root."
if ! $DRY_RUN; then
    command -v setfacl &>/dev/null || die "acl tools not found: dnf install -y acl"
    for d in "$DATA_DIR" "$LOGS_DIR" "$BACKUP_DIR"; do
        [[ -d "$d" ]] || die "Directory missing: $d — run 02_storage_lvm.sh first"
    done
else
    dry "Would verify: setfacl installed, $DATA_DIR $LOGS_DIR $BACKUP_DIR exist"
fi

# ════════════════════════════════════════════════════════════════════════════════
# PART 1 — ACL CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════
log "Configuring POSIX ACLs for billing data directories..."

# ── /srv/portbill/data ────────────────────────────────────────────────────────
run setfacl --recursive --modify \
    "g:billing-admin:rwx,g:billing-ops:rwx,g:port-ops:r-x,g:billing-readonly:r-x" \
    "$DATA_DIR"
run setfacl --recursive --modify "d:g:billing-admin:rwx" "$DATA_DIR"
run setfacl --recursive --modify "d:g:billing-ops:rw-"  "$DATA_DIR"
run setfacl --recursive --modify "d:g:port-ops:r--"     "$DATA_DIR"
run setfacl --recursive --modify "d:g:billing-readonly:r--" "$DATA_DIR"
run setfacl --recursive --modify "d:o::---"              "$DATA_DIR"
ok "ACLs set on: $DATA_DIR"

# ── /srv/portbill/logs ────────────────────────────────────────────────────────
run setfacl --recursive --modify \
    "g:billing-admin:rwx,g:billing-ops:r-x,g:billing-readonly:r-x" \
    "$LOGS_DIR"
run setfacl --recursive --modify "d:g:billing-admin:rwx" "$LOGS_DIR"
run setfacl --recursive --modify "d:g:billing-ops:r--"   "$LOGS_DIR"
run setfacl --recursive --modify "d:g:billing-readonly:r--" "$LOGS_DIR"
run setfacl --recursive --modify "d:o::---"               "$LOGS_DIR"
ok "ACLs set on: $LOGS_DIR"

# ── /srv/portbill/backup ──────────────────────────────────────────────────────
run setfacl --recursive --modify "g:billing-admin:rwx" "$BACKUP_DIR"
run setfacl --recursive --modify "d:g:billing-admin:rwx" "$BACKUP_DIR"
run setfacl --recursive --modify "d:o::---" "$BACKUP_DIR"
ok "ACLs set on: $BACKUP_DIR"

# ── ACL Report ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}ACL Report — ${DATA_DIR}${RESET}"
if $DRY_RUN; then
    dry "getfacl --skip-base $DATA_DIR"
    echo -e "  # file: ${DATA_DIR}"
    echo -e "  ${MAGENTA}group:billing-admin:rwx${RESET}"
    echo -e "  ${MAGENTA}group:billing-ops:rwx${RESET}"
    echo -e "  ${MAGENTA}group:port-ops:r-x${RESET}"
    echo -e "  ${MAGENTA}group:billing-readonly:r-x${RESET}"
else
    getfacl --skip-base "$DATA_DIR" 2>/dev/null | head -20
fi

# ════════════════════════════════════════════════════════════════════════════════
# PART 2 — AUTOMATED BACKUP SCRIPT
# ════════════════════════════════════════════════════════════════════════════════
log "Creating backup script: $BACKUP_SCRIPT"
if $DRY_RUN; then
    dry "Would write: $BACKUP_SCRIPT  (tar --create --gzip --acls --selinux)"
    dry "  Checksum: sha256sum per archive"
    dry "  Retention: purge backups older than ${BACKUP_RETENTION_DAYS} days"
else
    cat > "$BACKUP_SCRIPT" <<'BACKUP_SCRIPT_EOF'
#!/usr/bin/env bash
# portbill-backup — Automated backup for Port Billing Infrastructure
set -euo pipefail
trap 'echo "[BACKUP ERROR] Line ${LINENO}: ${BASH_COMMAND}" >> /var/log/portbill-backup.log' ERR

LOG_FILE="/var/log/portbill-backup.log"
DATA_DIR="/srv/portbill/data"
LOGS_DIR="/srv/portbill/logs"
BACKUP_DIR="/srv/portbill/backup"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
ARCHIVE_NAME="portbill_backup_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
CHECKSUM_FILE="${ARCHIVE_PATH}.sha256"
RETENTION_DAYS=30

exec >> "$LOG_FILE" 2>&1
echo "=== Backup started: $(date) ==="

tar \
    --create \
    --gzip \
    --file="$ARCHIVE_PATH" \
    --acls \
    --selinux \
    --preserve-permissions \
    --one-file-system \
    --exclude="*.tmp" \
    --exclude="*.lock" \
    "$DATA_DIR" "$LOGS_DIR"

sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_FILE"
echo "Checksum: $(cat "$CHECKSUM_FILE")"

tar --list --gzip --file="$ARCHIVE_PATH" > /dev/null
echo "Archive verified: $ARCHIVE_PATH"
echo "Size: $(du -sh "$ARCHIVE_PATH" | cut -f1)"

find "$BACKUP_DIR" -name "portbill_backup_*.tar.gz" \
    -mtime +"$RETENTION_DAYS" -delete -print | \
    while read -r old; do
        echo "Purged old backup: $old"
        rm -f "${old}.sha256"
    done

BACKUP_COUNT=$(find "$BACKUP_DIR" -name "portbill_backup_*.tar.gz" | wc -l)
BACKUP_TOTAL=$(du -sh "$BACKUP_DIR" | cut -f1)
echo "Backup count: $BACKUP_COUNT | Total size: $BACKUP_TOTAL"
echo "=== Backup complete: $(date) ==="
BACKUP_SCRIPT_EOF
    chmod 0750 "$BACKUP_SCRIPT"
    chown root:billing-admin "$BACKUP_SCRIPT"
fi
ok "Backup script: $BACKUP_SCRIPT"

# ── Systemd Timer ─────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would write: ${SYSTEMD_TIMER_DIR}/portbill-backup.service"
    dry "Would write: ${SYSTEMD_TIMER_DIR}/portbill-backup.timer  (OnCalendar=*-*-* 02:00:00)"
    dry "Would run: systemctl daemon-reload && systemctl enable --now portbill-backup.timer"
else
    cat > "${SYSTEMD_TIMER_DIR}/portbill-backup.service" <<EOF
[Unit]
Description=Port Billing Automated Backup
After=portbill.service

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
User=root
StandardOutput=journal
StandardError=journal
EOF

    cat > "${SYSTEMD_TIMER_DIR}/portbill-backup.timer" <<EOF
[Unit]
Description=Port Billing Backup Timer — Daily at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now portbill-backup.timer
fi
ok "Systemd timer: portbill-backup.timer (daily 02:00)"

# ── Test Backup ───────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would run test backup: tar --list --dry-run on $DATA_DIR"
    ok "Test backup: skipped in dry-run mode"
else
    log "Running test backup..."
    TEST_ARCHIVE="${BACKUP_DIR}/portbill_backup_TEST.tar.gz"
    tar --create --gzip --file="$TEST_ARCHIVE" \
        --acls --selinux --one-file-system \
        "$DATA_DIR" 2>/dev/null && \
        rm -f "$TEST_ARCHIVE" && ok "Test backup successful." || \
        warn "Test backup failed — check permissions and storage"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── ACL & Backup Summary ────────────────────${RESET}"
echo -e "  Data ACLs    : billing-admin(rwx) billing-ops(rwx) port-ops(r-x) readonly(r-x)"
echo -e "  Log ACLs     : billing-admin(rwx) billing-ops(r-x) readonly(r-x)"
echo -e "  Backup script: ${BACKUP_SCRIPT}"
echo -e "  Schedule     : Daily 02:00 (± 5min jitter)"
echo -e "  Retention    : ${BACKUP_RETENTION_DAYS} days"
echo -e "  Target       : ${BACKUP_DIR}"
if $DRY_RUN; then
    echo -e "  ${MAGENTA}No system changes were made.${RESET}"
else
    echo ""
    systemctl --no-pager status portbill-backup.timer || true
fi
echo ""
ok "ACL & backup configuration complete."
