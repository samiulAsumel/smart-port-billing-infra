#!/usr/bin/env bash
# Smart Port Billing Infrastructure — Application Deployment
# RHCSA Skills: Podman Container Management, Systemd Unit Files, Nginx Reverse Proxy
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
APP_IMAGE="ghcr.io/samiulAsumel/portbill:latest"
APP_PORT=3000
NGINX_PORT=443
NGINX_HTTP_PORT=80
APP_DATA_DIR="/srv/portbill/data"
APP_LOGS_DIR="/srv/portbill/logs"
SYSTEMD_UNIT="/etc/systemd/system/${APP_NAME}.service"
NGINX_CONF="/etc/nginx/conf.d/${APP_NAME}.conf"
SSL_DIR="/etc/nginx/ssl/portbill"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && ! $DRY_RUN && die "Must be run as root."
if ! $DRY_RUN; then
    command -v podman &>/dev/null  || die "Podman not found: dnf install -y podman"
    command -v nginx  &>/dev/null  || die "Nginx not found: dnf install -y nginx"
    [[ -d "$APP_DATA_DIR" ]]       || die "Data dir missing — run 02_storage_lvm.sh first"
fi

# ── Pull Container Image ──────────────────────────────────────────────────────
log "Container image: $APP_IMAGE"
if $DRY_RUN; then
    dry "Would run: podman pull $APP_IMAGE"
else
    podman pull "$APP_IMAGE" || {
        warn "Image pull failed — using local image if available"
        podman image exists "$APP_IMAGE" || die "No local image found for $APP_IMAGE"
    }
fi
ok "Container image ready: $APP_IMAGE"

# ── Systemd Unit ──────────────────────────────────────────────────────────────
log "Creating systemd unit: $SYSTEMD_UNIT"
if $DRY_RUN; then
    dry "Would write: $SYSTEMD_UNIT"
    dry "  [Unit] After=network-online.target"
    dry "  [Service] podman run --name $APP_NAME -p 127.0.0.1:${APP_PORT}:${APP_PORT}"
    dry "  NoNewPrivileges=yes PrivateTmp=yes ProtectSystem=strict"
else
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Smart Port Billing Application (Podman)
Documentation=https://github.com/samiulAsumel/portbill
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/srv/portbill

[Service]
Type=simple
Restart=on-failure
RestartSec=10s
TimeoutStartSec=60s
TimeoutStopSec=30s

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/srv/portbill/data /srv/portbill/logs

# Container run
ExecStartPre=/usr/bin/podman stop --ignore ${APP_NAME} 2>/dev/null || true
ExecStartPre=/usr/bin/podman rm   --ignore ${APP_NAME} 2>/dev/null || true
ExecStart=/usr/bin/podman run \\
    --name ${APP_NAME} \\
    --publish 127.0.0.1:${APP_PORT}:${APP_PORT} \\
    --volume ${APP_DATA_DIR}:/app/data:Z \\
    --volume ${APP_LOGS_DIR}:/app/logs:Z \\
    --env NODE_ENV=production \\
    --env PORT=${APP_PORT} \\
    --env LOG_DIR=/app/logs \\
    --read-only \\
    --security-opt no-new-privileges \\
    --health-cmd='curl -f http://localhost:${APP_PORT}/health || exit 1' \\
    --health-interval=30s \\
    --health-retries=3 \\
    ${APP_IMAGE}

ExecStop=/usr/bin/podman stop ${APP_NAME}
ExecStopPost=/usr/bin/podman rm --ignore ${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SYSTEMD_UNIT"
fi
ok "Systemd unit: $SYSTEMD_UNIT"

# ── TLS Certificate ───────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would create: $SSL_DIR/server.{key,crt}  (self-signed, RSA-4096, 365 days)"
    warn "PRODUCTION: Replace with a CA-signed cert (Let's Encrypt recommended)"
else
    mkdir -p "$SSL_DIR"
    if [[ ! -f "$SSL_DIR/server.crt" ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
            -keyout "$SSL_DIR/server.key" \
            -out    "$SSL_DIR/server.crt" \
            -subj "/C=BD/ST=Chittagong/O=Port Authority/CN=portbill.local" \
            -quiet
        chmod 0600 "$SSL_DIR/server.key"
        ok "Self-signed TLS certificate generated: $SSL_DIR/"
        warn "PRODUCTION: Replace with a CA-signed cert (Let's Encrypt recommended)"
    fi
fi

# ── Nginx Configuration ───────────────────────────────────────────────────────
log "Writing Nginx configuration: $NGINX_CONF"
if $DRY_RUN; then
    dry "Would write: $NGINX_CONF"
    dry "  server :${NGINX_HTTP_PORT} → 301 HTTPS redirect"
    dry "  server :${NGINX_PORT} ssl http2 → proxy_pass http://127.0.0.1:${APP_PORT}"
    dry "  HSTS, X-Frame-Options, X-Content-Type-Options, CSP headers"
else
    cat > "$NGINX_CONF" <<EOF
# Port Billing — Nginx TLS Reverse Proxy
upstream portbill_backend {
    server 127.0.0.1:${APP_PORT};
    keepalive 32;
}

server {
    listen ${NGINX_HTTP_PORT};
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_PORT} ssl http2;
    server_name portbill.local;

    ssl_certificate     ${SSL_DIR}/server.crt;
    ssl_certificate_key ${SSL_DIR}/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options            "DENY"           always;
    add_header X-Content-Type-Options     "nosniff"        always;
    add_header X-XSS-Protection           "1; mode=block"  always;
    add_header Referrer-Policy            "strict-origin"  always;

    access_log /var/log/nginx/portbill.access.log combined;
    error_log  /var/log/nginx/portbill.error.log  warn;

    location /health {
        proxy_pass http://portbill_backend;
        access_log off;
    }

    location / {
        proxy_pass         http://portbill_backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        client_max_body_size 10M;
    }
}
EOF
fi
ok "Nginx configuration: $NGINX_CONF"

# ── SELinux Port Context ──────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "semanage port --add --type http_port_t --proto tcp $APP_PORT"
elif command -v semanage &>/dev/null; then
    semanage port --add --type http_port_t --proto tcp "$APP_PORT" 2>/dev/null || \
        warn "SELinux: port $APP_PORT may already be labelled http_port_t"
fi
ok "SELinux: port $APP_PORT → http_port_t"

# ── Start Services ────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "nginx -t  (validate config syntax)"
    dry "systemctl daemon-reload"
    dry "systemctl enable --now nginx"
    dry "systemctl enable --now $APP_NAME"
else
    nginx -t || die "Nginx config syntax error — fix $NGINX_CONF before starting"
    ok "Nginx configuration syntax valid."
    systemctl daemon-reload
    systemctl enable --now nginx
    ok "Nginx enabled and started."
    systemctl enable --now "$APP_NAME"
    ok "portbill service enabled and started."
fi

# ── Health Check ──────────────────────────────────────────────────────────────
if $DRY_RUN; then
    dry "Would poll http://127.0.0.1:${APP_PORT}/health (max 60s, 12 attempts)"
else
    log "Waiting for application health check (max 60s)..."
    for i in $(seq 1 12); do
        if curl -sf --max-time 5 "http://127.0.0.1:${APP_PORT}/health" &>/dev/null; then
            ok "Health check passed on attempt $i"
            break
        fi
        sleep 5
        [[ $i -eq 12 ]] && warn "Health check did not pass — check: journalctl -u ${APP_NAME}"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}── Deployment Summary ──────────────────────${RESET}"
if ! $DRY_RUN; then
    systemctl --no-pager status "$APP_NAME" nginx | grep -E "Active:|Loaded:" || true
fi
echo -e "  App container    : ${APP_NAME} → 127.0.0.1:${APP_PORT}"
echo -e "  Nginx proxy      : :${NGINX_HTTP_PORT} → :${NGINX_PORT} (TLS)"
echo -e "  Data volume      : ${APP_DATA_DIR}"
echo -e "  Logs             : ${APP_LOGS_DIR}"
echo -e "  Systemd unit     : ${SYSTEMD_UNIT}"
$DRY_RUN && echo -e "  ${MAGENTA}No system changes were made.${RESET}"
echo ""
ok "Deployment complete."
