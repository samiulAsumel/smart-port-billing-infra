#!/usr/bin/env bash
# Smart Port Billing Infrastructure — LVM Storage Provisioning
# RHCSA Skills: LVM (PV/VG/LV), XFS Filesystem, Persistent fstab Mounts
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

# ── Dry-run mode + arg parsing ────────────────────────────────────────────────
DRY_RUN=false
BLOCK_DEVICE="/dev/sdb"
for _a in "$@"; do
    case "$_a" in
        --dry-run) DRY_RUN=true ;;
        /dev/*)    BLOCK_DEVICE="$_a" ;;
    esac
done

run() {
    if $DRY_RUN; then dry "Would run: $*"; else "$@"; fi
}

$DRY_RUN && {
    echo -e "\n${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${MAGENTA}${BOLD}║  DRY-RUN MODE — no changes will be made  ║${RESET}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
}

# ── Configuration ─────────────────────────────────────────────────────────────
# BLOCK_DEVICE set above (default /dev/sdb, override: ./02_storage_lvm.sh /dev/sdc)
VG_NAME="portbill-vg"
declare -A LV_CONFIG=(
    [billing-data]="10G:/srv/portbill/data:Billing transaction records"
    [billing-logs]="5G:/srv/portbill/logs:Application and audit logs"
    [billing-backup]="15G:/srv/portbill/backup:Automated backup target"
)

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]        && ! $DRY_RUN && die "Must be run as root."
if ! $DRY_RUN; then
    command -v pvcreate &>/dev/null || die "lvm2 not installed: dnf install -y lvm2"
    [[ -b "$BLOCK_DEVICE" ]]        || die "Block device not found: $BLOCK_DEVICE"
    grep -q "$BLOCK_DEVICE" /proc/mounts 2>/dev/null && \
        die "$BLOCK_DEVICE is currently mounted. Aborting to prevent data loss."
fi

log "Target device: $BLOCK_DEVICE"
$DRY_RUN || lsblk "$BLOCK_DEVICE"

# ── Physical Volume ───────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would check if $BLOCK_DEVICE is already a PV"
    dry "Would run: pvcreate --force $BLOCK_DEVICE  (after user confirmation)"
    ok "Physical Volume: $BLOCK_DEVICE  [dry]"
elif pvs "$BLOCK_DEVICE" &>/dev/null; then
    warn "$BLOCK_DEVICE already a PV — skipping pvcreate"
else
    read -rp "WARNING: This will wipe $BLOCK_DEVICE. Continue? [yes/N] " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted by user."
    pvcreate --force "$BLOCK_DEVICE"
    ok "Physical Volume created: $BLOCK_DEVICE"
fi

# ── Volume Group ──────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would create VG '$VG_NAME' on $BLOCK_DEVICE"
    ok "Volume Group: $VG_NAME  [dry]"
elif vgs "$VG_NAME" &>/dev/null; then
    warn "VG '$VG_NAME' already exists — skipping vgcreate"
else
    vgcreate "$VG_NAME" "$BLOCK_DEVICE"
    ok "Volume Group created: $VG_NAME"
fi

# ── Logical Volumes, XFS, fstab ──────────────────────────────────────────────
for lv_name in "${!LV_CONFIG[@]}"; do
    IFS=':' read -r lv_size mount_point lv_desc <<< "${LV_CONFIG[$lv_name]}"
    lv_path="/dev/$VG_NAME/$lv_name"

    if $DRY_RUN; then
        dry "Would create LV '$lv_name' (${lv_size}) and format XFS → $mount_point"
        dry "Would add fstab entry: UUID=<generated>  $mount_point  xfs  defaults,noatime,_netdev  0 2"
        dry "Would mount: $mount_point"
        ok "LV $lv_name → $mount_point ($lv_desc)  [dry]"
    else
        if lvs "$lv_path" &>/dev/null; then
            warn "LV '$lv_name' already exists — skipping"
        else
            lvcreate --name "$lv_name" --size "$lv_size" "$VG_NAME"
            ok "Logical Volume created: $lv_name ($lv_size)"
            mkfs.xfs -L "$lv_name" "$lv_path"
            ok "XFS filesystem created: $lv_path"
        fi

        mkdir -p "$mount_point"
        chown root:billing-ops "$mount_point"
        chmod 2775 "$mount_point"

        lv_uuid=$(blkid -s UUID -o value "$lv_path")
        fstab_entry="UUID=$lv_uuid  $mount_point  xfs  defaults,noatime,_netdev  0 2"
        if grep -q "UUID=$lv_uuid" /etc/fstab; then
            warn "fstab entry for $lv_name already exists — skipping"
        else
            echo "$fstab_entry" >> /etc/fstab
            ok "fstab entry added: $mount_point"
        fi

        if mountpoint -q "$mount_point"; then
            warn "$mount_point already mounted — skipping"
        else
            mount "$mount_point"
            ok "Mounted: $mount_point"
        fi
        log "  $lv_name → $mount_point ($lv_desc)"
    fi
done

# ── SELinux Contexts ──────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would set SELinux fcontext: /srv/portbill/data → httpd_sys_content_t"
    dry "Would set SELinux fcontext: /srv/portbill/logs → var_log_t"
    dry "Would run: restorecon -Rv /srv/portbill/"
else
    semanage fcontext --add --type httpd_sys_content_t "/srv/portbill/data(/.*)?" 2>/dev/null || \
        warn "SELinux fcontext may already exist for data dir"
    semanage fcontext --add --type var_log_t "/srv/portbill/logs(/.*)?" 2>/dev/null || \
        warn "SELinux fcontext may already exist for logs dir"
    restorecon -Rv /srv/portbill/
fi
ok "SELinux contexts applied to /srv/portbill/"

# ── Verification ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── LVM Storage Layout ──────────────────────${RESET}"
if $DRY_RUN; then
    dry "pvs  $BLOCK_DEVICE"
    dry "vgs  $VG_NAME"
    dry "lvs  $VG_NAME"
    dry "df -hT /srv/portbill/{data,logs,backup}"
    echo ""
    echo -e "  ${MAGENTA}No system changes were made.${RESET}"
else
    pvs  --noheadings -o pv_name,vg_name,pv_size,pv_free "$BLOCK_DEVICE"
    vgs  --noheadings -o vg_name,lv_count,vg_size,vg_free "$VG_NAME"
    lvs  --noheadings -o lv_name,lv_size,lv_path "$VG_NAME"
    echo ""
    df -hT /srv/portbill/data /srv/portbill/logs /srv/portbill/backup
fi
echo ""
ok "Storage provisioning complete."
