#!/usr/bin/env bash
# Smart Port Billing Infrastructure — Log Monitoring & Alerting
# RHCSA Skills: journalctl, rsyslog, logrotate, Systemd Journal Filtering
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
APP_NAME="portbill"
ALERT_EMAIL="portadmin@portbill.local"
LOG_DIR="/srv/portbill/logs"
APP_LOG="${LOG_DIR}/app.log"
AUDIT_LOG="${LOG_DIR}/billing-audit.log"
MONITOR_SCRIPT="/usr/local/bin/portbill-logmonitor"
LOGROTATE_CONF="/etc/logrotate.d/${APP_NAME}"
RSYSLOG_CONF="/etc/rsyslog.d/10-${APP_NAME}.conf"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]    && ! $DRY_RUN && die "Must be run as root."
[[ -d "$LOG_DIR" ]]  || $DRY_RUN   || die "Log directory missing — run 02_storage_lvm.sh first"
$DRY_RUN && dry "Would verify: $LOG_DIR exists"

# ════════════════════════════════════════════════════════════════════════════════
# PART 1 — RSYSLOG
# ════════════════════════════════════════════════════════════════════════════════
log "Configuring rsyslog for $APP_NAME..."

if $DRY_RUN; then
    dry "Would write: $RSYSLOG_CONF"
    dry "  Route: programname=='$APP_NAME'  → $APP_LOG  + $AUDIT_LOG"
    dry "  Route: programname=='nginx' && portbill → $APP_LOG"
    dry "  Route: audit AVC denials → /var/log/portbill-avc.log"
    dry "Would run: rsyslogd -N1 -f $RSYSLOG_CONF  (validate)"
    dry "Would run: systemctl restart rsyslog"
else
    cat > "$RSYSLOG_CONF" <<EOF
# Port Billing — rsyslog routing rules
\$template PortbillFormat,"%TIMESTAMP% %HOSTNAME% %syslogseverity-text% %msg%\\n"

if \$programname == '${APP_NAME}' then {
    action(type="omfile" file="${APP_LOG}"    template="PortbillFormat")
    action(type="omfile" file="${AUDIT_LOG}"  template="PortbillFormat"
           filterConditions="if \$msg contains 'BILLING' or \$msg contains 'PAYMENT' or \$msg contains 'INVOICE'")
    stop
}

if \$programname == 'nginx' and \$msg contains 'portbill' then {
    action(type="omfile" file="${APP_LOG}" template="PortbillFormat")
    stop
}

if \$programname == 'audit' and \$msg contains 'avc' then {
    action(type="omfile" file="/var/log/portbill-avc.log" template="PortbillFormat")
}
EOF
    chmod 0644 "$RSYSLOG_CONF"
    rsyslogd -N1 -f "$RSYSLOG_CONF" 2>&1 | grep -v "^$" || warn "rsyslog validation warnings above"
    systemctl restart rsyslog
fi
ok "rsyslog configured: $RSYSLOG_CONF"

# ════════════════════════════════════════════════════════════════════════════════
# PART 2 — LOGROTATE
# ════════════════════════════════════════════════════════════════════════════════
log "Configuring logrotate for $APP_NAME..."

if $DRY_RUN; then
    dry "Would write: $LOGROTATE_CONF"
    dry "  ${LOG_DIR}/*.log: daily rotate=90 size=100M compress delaycompress"
    dry "  /var/log/nginx/portbill.*.log: daily rotate=30 compress"
    dry "Would run: logrotate --debug $LOGROTATE_CONF  (validate)"
else
    cat > "$LOGROTATE_CONF" <<EOF
# Port Billing — logrotate configuration
${LOG_DIR}/*.log {
    daily
    rotate 90
    size 100M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
    create 0640 root billing-ops
    sharedscripts
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
        /usr/bin/systemctl reload ${APP_NAME} > /dev/null 2>&1 || true
    endscript
}

/var/log/nginx/portbill.*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        /usr/bin/systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
EOF
    chmod 0644 "$LOGROTATE_CONF"
    logrotate --debug "$LOGROTATE_CONF" 2>&1 | tail -10
fi
ok "logrotate configured: $LOGROTATE_CONF"

# ════════════════════════════════════════════════════════════════════════════════
# PART 3 — LOG MONITOR SCRIPT
# ════════════════════════════════════════════════════════════════════════════════
log "Creating log monitor: $MONITOR_SCRIPT"

if $DRY_RUN; then
    dry "Would write: $MONITOR_SCRIPT"
    dry "  Modes: watch (real-time tail) | summary (daily report) | check (health CI)"
    dry "  Alert patterns: CRITICAL, ERROR, FATAL, OOM, AUDIT events"
    dry "  Alert destinations: $ALERT_EMAIL + journalctl + /var/log/portbill-alerts.log"
else
    cat > "$MONITOR_SCRIPT" <<'MONITOR_EOF'
#!/usr/bin/env bash
# portbill-logmonitor — Real-time billing log monitor with alerting
set -euo pipefail

APP_NAME="portbill"
LOG_FILE="/srv/portbill/logs/app.log"
AUDIT_LOG="/srv/portbill/logs/billing-audit.log"
ALERT_EMAIL="${ALERT_EMAIL:-portadmin@portbill.local}"
ALERT_LOG="/var/log/portbill-alerts.log"
SUMMARY_LOG="/var/log/portbill-daily-summary.log"

declare -A ALERT_PATTERNS=(
    ["CRITICAL:database connection"]="CRIT: Database connectivity failure"
    ["ERROR:payment processing"]="ERR: Payment processor error"
    ["ERROR:authentication"]="ERR: Authentication system failure"
    ["WARN:disk"]="WARN: Disk space warning from app"
    ["FATAL"]="CRIT: Application fatal error"
    ["OOM"]="CRIT: Out-of-memory condition"
    ["AUDIT:unauthorized"]="SEC: Unauthorized billing access attempt"
    ["AUDIT:privilege_escalation"]="SEC: Privilege escalation detected"
)

send_alert() {
    local severity="$1" message="$2"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$severity] $message" >> "$ALERT_LOG"
    if command -v mail &>/dev/null; then
        echo "$message" | mail -s "[PORTBILL $severity] Alert - $(hostname)" "$ALERT_EMAIL" 2>/dev/null || true
    fi
    case "$severity" in
        CRIT) logger -p user.crit    -t portbill-monitor "$message" ;;
        ERR)  logger -p user.err     -t portbill-monitor "$message" ;;
        SEC)  logger -p authpriv.crit -t portbill-monitor "$message" ;;
        WARN) logger -p user.warning  -t portbill-monitor "$message" ;;
    esac
}

generate_daily_summary() {
    local date_str; date_str=$(date '+%Y-%m-%d')
    local summary_file="${SUMMARY_LOG%.log}_${date_str}.log"
    {
        echo "=== Port Billing Daily Log Summary: $date_str ==="
        echo ""
        echo "--- Service Status ---"
        systemctl --no-pager status portbill nginx 2>/dev/null | grep -E "Active:|Main PID:" || true
        echo ""
        echo "--- Journal Error Count (last 24h) ---"
        journalctl -u portbill --since "24 hours ago" --no-pager -p err 2>/dev/null | wc -l
        echo ""
        echo "--- Billing Audit Events ---"
        grep "$(date '+%Y-%m-%d')" "$AUDIT_LOG" 2>/dev/null | wc -l
        echo ""
        echo "--- Login Events ---"
        journalctl --since "24 hours ago" --no-pager -t sshd 2>/dev/null | grep -c "Accepted" || echo "0"
        echo ""
        echo "--- Disk Usage ---"
        df -h /srv/portbill/data /srv/portbill/logs /srv/portbill/backup 2>/dev/null
        echo ""
        echo "=== End of Summary ==="
    } > "$summary_file"
    cat "$summary_file"
}

case "${1:-watch}" in
    watch)
        echo "[$(date)] Starting real-time log monitor for ${APP_NAME}..."
        journalctl -u "$APP_NAME" -f --no-pager --output=short-iso 2>/dev/null | \
        while IFS= read -r line; do
            for pattern in "${!ALERT_PATTERNS[@]}"; do
                IFS=':' read -r severity keyword <<< "$pattern"
                if echo "$line" | grep -qi "$keyword"; then
                    send_alert "$severity" "${ALERT_PATTERNS[$pattern]}: $line"
                fi
            done
        done
        ;;
    summary)
        generate_daily_summary
        ;;
    check)
        error_count=$(journalctl -u "$APP_NAME" --since "1 hour ago" \
            --no-pager -p err 2>/dev/null | grep -c "ERROR\|FATAL\|CRIT" || true)
        echo "Errors in last 1h: $error_count"
        [[ $error_count -lt 10 ]] || { echo "CRITICAL: High error rate"; exit 1; }
        ;;
    *)
        echo "Usage: $0 [watch|summary|check]"
        exit 1
        ;;
esac
MONITOR_EOF
    chmod 0750 "$MONITOR_SCRIPT"
    chown root:billing-admin "$MONITOR_SCRIPT"
fi
ok "Log monitor: $MONITOR_SCRIPT"

# ── Systemd Units ─────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would write: /etc/systemd/system/portbill-logmonitor.service"
    dry "  BindsTo=portbill.service — monitor stops when app stops"
    dry "Would write: /etc/systemd/system/portbill-summary.{service,timer}"
    dry "  OnCalendar=*-*-* 07:00:00 — daily summary at 07:00"
    dry "Would run: systemctl daemon-reload"
    dry "Would run: systemctl enable --now portbill-logmonitor portbill-summary.timer"
else
    cat > "/etc/systemd/system/portbill-logmonitor.service" <<EOF
[Unit]
Description=Port Billing Log Monitor
After=portbill.service rsyslog.service
BindsTo=portbill.service

[Service]
Type=simple
ExecStart=${MONITOR_SCRIPT} watch
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=portbill-monitor

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/portbill-summary.timer" <<EOF
[Unit]
Description=Port Billing Daily Log Summary

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > "/etc/systemd/system/portbill-summary.service" <<EOF
[Unit]
Description=Port Billing Daily Log Summary

[Service]
Type=oneshot
ExecStart=${MONITOR_SCRIPT} summary
StandardOutput=journal
EOF

    systemctl daemon-reload
    systemctl enable --now portbill-logmonitor
    systemctl enable --now portbill-summary.timer
fi
ok "Log monitor service and daily summary timer enabled."

# ── Journal Persistence ───────────────────────────────────────────────────────
run mkdir -p /var/log/journal
if $DRY_RUN; then
    dry "systemd-tmpfiles --create --prefix /var/log/journal"
    dry "journalctl --verify"
else
    systemd-tmpfiles --create --prefix /var/log/journal
    journalctl --verify 2>/dev/null || warn "Journal verify returned warnings — may be normal"
fi
ok "Systemd journal set to persistent storage"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── Log Monitoring Summary ──────────────────${RESET}"
echo -e "  rsyslog config   : $RSYSLOG_CONF"
echo -e "  logrotate config : $LOGROTATE_CONF"
echo -e "  Monitor script   : $MONITOR_SCRIPT"
echo -e "  Alert log        : /var/log/portbill-alerts.log"
echo -e "  AVC log          : /var/log/portbill-avc.log"
echo -e "  Daily summary    : /var/log/portbill-daily-summary_*.log"
echo -e "  Log retention    : 90 days (100MB rotate threshold)"
echo -e "  Alert email      : $ALERT_EMAIL"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  journalctl -u portbill -f                    # Follow app logs"
echo -e "  journalctl -u portbill -p err --since today  # Today's errors"
echo -e "  $MONITOR_SCRIPT summary                      # Daily report"
echo -e "  $MONITOR_SCRIPT check                        # Health check (CI/cron)"
$DRY_RUN && echo -e "\n  ${MAGENTA}No system changes were made.${RESET}"
echo ""
ok "Log monitoring setup complete."
