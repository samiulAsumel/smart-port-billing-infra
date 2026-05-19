#!/usr/bin/env bash
# Smart Port Billing Infrastructure — ACL Configuration & Automated Backup
# RHCSA Skills: POSIX ACLs, setfacl/getfacl, Cron/Systemd Timer, Backup Integrity
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
DATA_DIR="/srv/portbill/data"
LOGS_DIR="/srv/portbill/logs"
BACKUP_DIR="/srv/portbill/backup"
BACKUP_SCRIPT="/usr/local/bin/portbill-backup"
BACKUP_RETENTION_DAYS=30
SYSTEMD_TIMER_DIR="/etc/systemd/system"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root."
command -v setfacl &>/dev/null || die "acl tools not found: dnf install -y acl"
for d in "$DATA_DIR" "$LOGS_DIR" "$BACKUP_DIR"; do
    [[ -d "$d" ]] || die "Directory missing: $d — run 02_storage_lvm.sh first"
done

# ── Verify ACL Support on Filesystem ─────────────────────────────────────────
if ! tune2fs -l "$(findmnt -n -o SOURCE "$DATA_DIR")" 2>/dev/null | grep -q "acl" &&
   ! findmnt -n -o OPTIONS "$DATA_DIR" | grep -qE "acl|xfs"; then
    warn "Confirm XFS filesystem supports ACLs (XFS enables ACLs by default)"
fi

# ════════════════════════════════════════════════════════════════════════════════
# PART 1 — ACL CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════
log "Configuring POSIX ACLs for billing data directories..."

# ── /srv/portbill/data — Billing Transaction Records ─────────────────────────
# billing-admin: full control
# billing-ops:   read + write (no execute on files)
# port-ops:      read-only
# billing-readonly: read-only
# auditor users: read-only + no delete

setfacl --recursive --modify \
    "g:billing-admin:rwx,g:billing-ops:rwx,g:port-ops:r-x,g:billing-readonly:r-x" \
    "$DATA_DIR"

# Default ACLs — inherited by new files and subdirectories
setfacl --recursive --modify "d:g:billing-admin:rwx" "$DATA_DIR"
setfacl --recursive --modify "d:g:billing-ops:rw-"  "$DATA_DIR"
setfacl --recursive --modify "d:g:port-ops:r--"     "$DATA_DIR"
setfacl --recursive --modify "d:g:billing-readonly:r--" "$DATA_DIR"
setfacl --recursive --modify "d:o::---"              "$DATA_DIR"
ok "ACLs set on: $DATA_DIR"

# ── /srv/portbill/logs — Application & Audit Logs ────────────────────────────
setfacl --recursive --modify \
    "g:billing-admin:rwx,g:billing-ops:r-x,g:billing-readonly:r-x" \
    "$LOGS_DIR"
setfacl --recursive --modify "d:g:billing-admin:rwx" "$LOGS_DIR"
setfacl --recursive --modify "d:g:billing-ops:r--"   "$LOGS_DIR"
setfacl --recursive --modify "d:g:billing-readonly:r--" "$LOGS_DIR"
setfacl --recursive --modify "d:o::---"               "$LOGS_DIR"
ok "ACLs set on: $LOGS_DIR"

# ── /srv/portbill/backup — Backup Target ─────────────────────────────────────
setfacl --recursive --modify "g:billing-admin:rwx" "$BACKUP_DIR"
setfacl --recursive --modify "d:g:billing-admin:rwx" "$BACKUP_DIR"
setfacl --recursive --modify "d:o::---" "$BACKUP_DIR"
ok "ACLs set on: $BACKUP_DIR"

# ── Report Applied ACLs ───────────────────────────────────────────────────────
echo -e "\n${BOLD}ACL Report — ${DATA_DIR}${RESET}"
getfacl --skip-base "$DATA_DIR" 2>/dev/null | head -20

# ════════════════════════════════════════════════════════════════════════════════
# PART 2 — AUTOMATED BACKUP SCRIPT
# ════════════════════════════════════════════════════════════════════════════════
log "Creating backup script: $BACKUP_SCRIPT"
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

# Create compressed archive with ACL preservation
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

# SHA-256 integrity checksum
sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_FILE"
echo "Checksum: $(cat "$CHECKSUM_FILE")"

# Verify archive integrity
tar --list --gzip --file="$ARCHIVE_PATH" > /dev/null
echo "Archive verified: $ARCHIVE_PATH"
echo "Size: $(du -sh "$ARCHIVE_PATH" | cut -f1)"

# Retention: remove backups older than RETENTION_DAYS
find "$BACKUP_DIR" -name "portbill_backup_*.tar.gz" \
    -mtime +"$RETENTION_DAYS" -delete -print | \
    while read -r old; do
        echo "Purged old backup: $old"
        rm -f "${old}.sha256"
    done

# Log backup inventory
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "portbill_backup_*.tar.gz" | wc -l)
BACKUP_TOTAL=$(du -sh "$BACKUP_DIR" | cut -f1)
echo "Backup count: $BACKUP_COUNT | Total size: $BACKUP_TOTAL"
echo "=== Backup complete: $(date) ==="
BACKUP_SCRIPT_EOF

chmod 0750 "$BACKUP_SCRIPT"
chown root:billing-admin "$BACKUP_SCRIPT"
ok "Backup script created: $BACKUP_SCRIPT"

# ── Systemd Timer (preferred over cron for RHEL 9) ───────────────────────────
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
ok "Systemd timer enabled: portbill-backup.timer (daily at 02:00)"

# ── Test Backup (dry run) ─────────────────────────────────────────────────────
log "Running test backup..."
TEST_ARCHIVE="${BACKUP_DIR}/portbill_backup_TEST.tar.gz"
tar --create --gzip --file="$TEST_ARCHIVE" \
    --acls --selinux --one-file-system \
    "$DATA_DIR" 2>/dev/null && \
    rm -f "$TEST_ARCHIVE" && ok "Test backup successful." || \
    warn "Test backup failed — check permissions and storage"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── ACL & Backup Summary ────────────────────${RESET}"
echo -e "  Data ACLs        : billing-admin(rwx) billing-ops(rwx) port-ops(r-x) readonly(r-x)"
echo -e "  Log ACLs         : billing-admin(rwx) billing-ops(r-x) readonly(r-x)"
echo -e "  Backup script    : ${BACKUP_SCRIPT}"
echo -e "  Backup schedule  : Daily 02:00 (± 5min jitter)"
echo -e "  Retention        : ${BACKUP_RETENTION_DAYS} days"
echo -e "  Backup target    : ${BACKUP_DIR}"
echo ""
systemctl --no-pager status portbill-backup.timer
ok "ACL & backup configuration complete."
