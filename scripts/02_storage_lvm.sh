#!/usr/bin/env bash
# Smart Port Billing Infrastructure — LVM Storage Provisioning
# RHCSA Skills: LVM (PV/VG/LV), XFS Filesystem, Persistent fstab Mounts
# Run as root on RHEL 9 — Requires unformatted block device (default: /dev/sdb)
set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO${RESET}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]  OK  ${RESET}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${RESET}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] FAIL${RESET}  $*" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
BLOCK_DEVICE="${1:-/dev/sdb}"          # Override: ./02_storage_lvm.sh /dev/sdc
VG_NAME="portbill-vg"
declare -A LV_CONFIG=(
    [billing-data]="10G:/srv/portbill/data:Billing transaction records"
    [billing-logs]="5G:/srv/portbill/logs:Application and audit logs"
    [billing-backup]="15G:/srv/portbill/backup:Automated backup target"
)

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]            && die "Must be run as root."
command -v pvcreate &>/dev/null || die "lvm2 not installed: dnf install -y lvm2"
[[ -b "$BLOCK_DEVICE" ]]     || die "Block device not found: $BLOCK_DEVICE"

log "Target device: $BLOCK_DEVICE"
lsblk "$BLOCK_DEVICE"

# Safety check — refuse to wipe a mounted or used device
if grep -q "$BLOCK_DEVICE" /proc/mounts 2>/dev/null; then
    die "$BLOCK_DEVICE is currently mounted. Aborting to prevent data loss."
fi
if pvs "$BLOCK_DEVICE" &>/dev/null; then
    warn "$BLOCK_DEVICE already a PV — skipping pvcreate"
else
    read -rp "WARNING: This will wipe $BLOCK_DEVICE. Continue? [yes/N] " confirm
    [[ "$confirm" == "yes" ]] || die "Aborted by user."
    pvcreate --force "$BLOCK_DEVICE"
    ok "Physical Volume created: $BLOCK_DEVICE"
fi

# ── Volume Group ──────────────────────────────────────────────────────────────
if vgs "$VG_NAME" &>/dev/null; then
    warn "VG '$VG_NAME' already exists — skipping vgcreate"
else
    vgcreate "$VG_NAME" "$BLOCK_DEVICE"
    ok "Volume Group created: $VG_NAME"
fi

# ── Logical Volumes, XFS, fstab ──────────────────────────────────────────────
for lv_name in "${!LV_CONFIG[@]}"; do
    IFS=':' read -r lv_size mount_point lv_desc <<< "${LV_CONFIG[$lv_name]}"
    lv_path="/dev/$VG_NAME/$lv_name"

    if lvs "$lv_path" &>/dev/null; then
        warn "LV '$lv_name' already exists — skipping"
    else
        lvcreate --name "$lv_name" --size "$lv_size" "$VG_NAME"
        ok "Logical Volume created: $lv_name ($lv_size)"
        mkfs.xfs -L "$lv_name" "$lv_path"
        ok "XFS filesystem created: $lv_path"
    fi

    # Create mount point
    mkdir -p "$mount_point"
    chown root:billing-ops "$mount_point"
    chmod 2775 "$mount_point"

    # Idempotent fstab entry (keyed on mount point)
    lv_uuid=$(blkid -s UUID -o value "$lv_path")
    fstab_entry="UUID=$lv_uuid  $mount_point  xfs  defaults,noatime,_netdev  0 2"
    if grep -q "UUID=$lv_uuid" /etc/fstab; then
        warn "fstab entry for $lv_name already exists — skipping"
    else
        echo "$fstab_entry" >> /etc/fstab
        ok "fstab entry added: $mount_point"
    fi

    # Mount if not already mounted
    if mountpoint -q "$mount_point"; then
        warn "$mount_point already mounted — skipping"
    else
        mount "$mount_point"
        ok "Mounted: $mount_point"
    fi
    log "  $lv_name → $mount_point ($lv_desc)"
done

# ── SELinux Contexts ──────────────────────────────────────────────────────────
semanage fcontext --add --type httpd_sys_content_t "/srv/portbill/data(/.*)?" 2>/dev/null || \
    warn "SELinux fcontext may already exist for data dir"
semanage fcontext --add --type var_log_t "/srv/portbill/logs(/.*)?" 2>/dev/null || \
    warn "SELinux fcontext may already exist for logs dir"
restorecon -Rv /srv/portbill/
ok "SELinux contexts applied to /srv/portbill/"

# ── Verification ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── LVM Storage Layout ──────────────────────${RESET}"
pvs  --noheadings -o pv_name,vg_name,pv_size,pv_free "$BLOCK_DEVICE"
vgs  --noheadings -o vg_name,lv_count,vg_size,vg_free "$VG_NAME"
lvs  --noheadings -o lv_name,lv_size,lv_path "$VG_NAME"
echo ""
df -hT /srv/portbill/data /srv/portbill/logs /srv/portbill/backup
echo ""
ok "Storage provisioning complete."
