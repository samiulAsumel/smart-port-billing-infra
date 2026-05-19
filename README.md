# Smart Port Billing Infrastructure on RHEL 9

> A production-grade Linux infrastructure automation project demonstrating the full RHCSA EX200 skill set through 7 hardened Bash scripts and an interactive web showcase.

[![RHEL 9](https://img.shields.io/badge/RHEL-9-EE0000?logo=redhat&logoColor=white)](https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Scripts](https://img.shields.io/badge/Scripts-7%20%7C%201%2C457%20lines-blue)](./scripts/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What This Project Is

**Smart Port Billing Infrastructure** is a complete, automated RHEL 9 server deployment pipeline for a maritime port operations environment. It provisions and hardens an entire Linux server from bare metal — user management, dedicated storage volumes, firewall rules, SSH lockdown, containerised application deployment, fine-grained file access controls, automated backups, and centralised log monitoring.

Every script targets a real RHCSA EX200 exam objective while producing a result you would actually apply in a production environment. The "billing" framing gives every technical decision a concrete operational context: who can read transaction records, which firewall ports are open, how long logs are retained, and who gets paged when disk fills up.

---

## What This Project Is NOT

This project contains **no billing user interface, no payment processing logic, and no financial application code**. There is no frontend dashboard for invoicing ships, no database of port fees, and no REST API for billing transactions.

The name refers to the *server infrastructure that would host* such an application — the OS-level plumbing: storage, security, networking, access control, observability, and service management. Think of it as the platform team's deliverable before the application team ships their code.

---

## Why Port Billing as the Context?

A maritime port billing system is an ideal real-world anchor for RHCSA skills because it demands:

- **Multi-department access** — billing operators, port managers, auditors, IT admins all need different permissions on different directories
- **Data separation** — transaction records, audit logs, and backup archives must live on dedicated, independently-sized volumes
- **High availability** — billing downtime means ships queue up; the service must survive reboots and restart automatically
- **Strict access controls** — financial data requires both POSIX ACLs and SELinux mandatory access controls
- **Compliance-grade logging** — port authorities face regulatory audit requirements; logs must be routed, retained, and monitored

Every script decision maps back to one of these constraints.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     RHEL 9 Server (bare metal / VM)                 │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  LVM Storage Stack          /dev/sdb → portbill-vg           │   │
│  │  ├── billing-data   10G  →  /srv/portbill/data  (xfs)        │   │
│  │  ├── billing-logs    5G  →  /srv/portbill/logs  (xfs)        │   │
│  │  └── billing-backup 15G  →  /srv/portbill/backup (xfs)       │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────┐    ┌───────────────────────────────────┐  │
│  │  Users & Groups      │    │  Network Security                 │  │
│  │  ├── portadmin       │    │  ├── firewalld zone: portbilling   │  │
│  │  ├── billing-ops (3) │    │  ├── HTTP/HTTPS open (rate-ltd)   │  │
│  │  ├── port-managers   │    │  ├── SSH :2222 → /24 subnet only  │  │
│  │  ├── auditors        │    │  └── SELinux: enforcing           │  │
│  │  └── it-admin        │    └───────────────────────────────────┘  │
│  └──────────────────────┘                                           │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Service Stack                                               │   │
│  │  Nginx (TLS 1.3, HSTS) → 127.0.0.1:3000 → Podman container  │   │
│  │  systemd unit: portbill.service  (Restart=on-failure)        │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────┐    ┌───────────────────────────────────┐  │
│  │  ACLs & Backup       │    │  Observability                    │  │
│  │  ├── setfacl rules   │    │  ├── rsyslog custom routing       │  │
│  │  ├── default ACLs    │    │  ├── logrotate (30-day retention) │  │
│  │  └── systemd timer   │    │  ├── disk-alert monitor script    │  │
│  │    daily tar.gz +    │    │  └── journald persistent storage  │  │
│  │    SHA-256 checksum  │    └───────────────────────────────────┘  │
│  └──────────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
smart-port-billing-infra/
│
├── scripts/                         # 7 Bash automation scripts (1,457 lines total)
│   ├── 01_user_group_setup.sh       # 136 lines — Users, groups, password policy, sudo
│   ├── 02_storage_lvm.sh            # 157 lines — LVM PV/VG/LV, XFS, fstab, SELinux
│   ├── 03_firewall_selinux.sh       # 177 lines — firewalld zones, rich rules, SELinux
│   ├── 04_ssh_hardening.sh          # 180 lines — SSH port, key-only auth, ciphers
│   ├── 05_service_deploy.sh         # 256 lines — Podman container, Nginx, systemd
│   ├── 06_acl_backup.sh             # 224 lines — POSIX ACLs, backup timer, retention
│   └── 07_log_monitor.sh            # 327 lines — rsyslog, logrotate, disk-alert daemon
│
├── config/                          # Reference configuration files
│   ├── nginx.conf                   #  42 lines — Nginx production config
│   ├── portbill.service             #  51 lines — Systemd unit with hardening directives
│   └── sshd_config.hardened         #  50 lines — Annotated OpenSSH hardened config
│
├── index.html                       # Interactive portfolio/showcase website
├── style.css                        # Custom design system (~1,600 lines)
├── main.js                          # Page interactions, syntax highlighting
├── playground.js                    # Simulated deployment playground UI
├── scripts-data.js                  # Auto-generated script content for the playground
├── favicon.svg                      # SVG favicon
└── README.md                        # This file
```

---

## Dry-Run Mode

Every script supports `--dry-run`. No root privileges required. No changes made. All commands are printed so you can verify exactly what would happen before committing:

```bash
bash scripts/01_user_group_setup.sh --dry-run
bash scripts/02_storage_lvm.sh --dry-run /dev/sdc   # device arg also works in dry mode
bash scripts/03_firewall_selinux.sh --dry-run
bash scripts/04_ssh_hardening.sh --dry-run
bash scripts/05_service_deploy.sh --dry-run
bash scripts/06_acl_backup.sh --dry-run
bash scripts/07_log_monitor.sh --dry-run
```

Dry-run is implemented via a `run()` wrapper function present in every script:

```bash
DRY_RUN=false
for _a in "$@"; do [[ "$_a" == "--dry-run" ]] && DRY_RUN=true; done

run() { if $DRY_RUN; then echo "[DRY-RUN] Would run: $*"; else "$@"; fi; }
```

Complex multi-line blocks (heredocs, interactive prompts, filesystem operations) use explicit `if $DRY_RUN; then dry "..."; else ...; fi` guards. The root check is bypassed in dry mode so any user can preview safely.

---

## Deployment Guide

### Prerequisites

- RHEL 9 server (bare metal or VM) — minimal install
- A second block device (e.g. `/dev/sdb`, 30 GB+) for LVM
- Root or sudo access
- An SSH ed25519 or RSA public key ready

### Step 1 — Users and Groups

```bash
sudo bash scripts/01_user_group_setup.sh
```

Creates the department group structure, user accounts with proper shells and password aging, sudo policy, and `/home` directory permissions.

### Step 2 — LVM Storage

```bash
sudo bash scripts/02_storage_lvm.sh /dev/sdb
```

Replace `/dev/sdb` with your actual block device. The script will prompt for confirmation before wiping the device. Idempotent — safe to re-run if volumes already exist.

### Step 3 — Firewall and SELinux

```bash
sudo bash scripts/03_firewall_selinux.sh
```

Sets SELinux to enforcing, applies custom file context rules, configures a dedicated `portbilling` firewalld zone.

### Step 4 — SSH Hardening

```bash
# Add your public key BEFORE running this script — you will be locked out otherwise
echo "ssh-ed25519 AAAA...your-key... you@host" >> /home/portadmin/.ssh/authorized_keys

sudo bash scripts/04_ssh_hardening.sh
```

After this runs, SSH is on port 2222 and password authentication is disabled.

### Step 5 — Application Deployment

```bash
sudo bash scripts/05_service_deploy.sh
```

Pulls the container image, generates a self-signed TLS certificate, writes the Nginx config and systemd unit, enables the service, and performs a health check.

### Step 6 — ACLs and Backup

```bash
sudo bash scripts/06_acl_backup.sh
```

Applies department ACLs to billing directories and installs a systemd timer for daily automated backups.

### Step 7 — Log Monitoring

```bash
sudo bash scripts/07_log_monitor.sh
```

Configures rsyslog routing, logrotate policies, journald persistence, and installs a disk-alert monitor script with its own systemd timer.

---

## Script Reference

### `01_user_group_setup.sh` — User & Group Management

**What it does:**

Creates a complete multi-department identity structure on the RHEL 9 server. Every operational department that interacts with the billing system gets its own Unix group with tailored permissions.

**Groups created:**

| Group | GID | Purpose |
|-------|-----|---------|
| `billing-ops` | 1001 | Billing operators — full read/write on transaction data |
| `port-managers` | 1002 | Management — read-only access to data, read/write reports |
| `auditors` | 1003 | Compliance — read-only on all billing directories |
| `billing-admin` | 1004 | SSH-capable admin group — system administration |
| `it-admin` | 1005 | IT infrastructure — sudo for system management |

**Users created:**

| User | Shell | Groups | Purpose |
|------|-------|--------|---------|
| `portadmin` | `/bin/bash` | `billing-admin`, `it-admin` | Primary admin account |
| `billing01–03` | `/bin/bash` | `billing-ops` | Billing operators |
| `manager01` | `/bin/bash` | `port-managers` | Port manager |
| `auditor01` | `/bin/bash` | `auditors` | Compliance auditor |

**Password policy (applied via `chage`):**

- Maximum age: 90 days
- Minimum age: 7 days
- Warning period: 14 days before expiry
- Account inactive after: 30 days post-expiry

**Sudo policy:** `billing-admin` group members get `NOPASSWD` sudo for systemctl and journalctl commands only — not unrestricted root. Delivered via a validated drop-in under `/etc/sudoers.d/`.

**RHCSA skills:** `useradd`, `groupadd`, `usermod`, `chage`, `visudo`, `/etc/sudoers.d/`, home directory permissions.

---

### `02_storage_lvm.sh` — LVM Storage Provisioning

**What it does:**

Builds a complete LVM stack on a specified block device and mounts three dedicated XFS filesystems for the billing application's data separation requirements.

**Storage layout:**

| Logical Volume | Size | Mount Point | SELinux Context | Purpose |
|----------------|------|-------------|-----------------|---------|
| `billing-data` | 10 GB | `/srv/portbill/data` | `httpd_sys_content_t` | Live transaction records |
| `billing-logs` | 5 GB | `/srv/portbill/logs` | `var_log_t` | Application and audit logs |
| `billing-backup` | 15 GB | `/srv/portbill/backup` | (default) | Daily backup archives |

**LVM stack built:**

```
/dev/sdb
  └── PV: pvcreate /dev/sdb
        └── VG: portbill-vg
              ├── LV: billing-data   (10G) → mkfs.xfs -L billing-data
              ├── LV: billing-logs    (5G) → mkfs.xfs -L billing-logs
              └── LV: billing-backup (15G) → mkfs.xfs -L billing-backup
```

**fstab entries** use UUID (not device path) for persistence across reboots:

```
UUID=<generated>  /srv/portbill/data    xfs  defaults,noatime,_netdev  0 2
UUID=<generated>  /srv/portbill/logs    xfs  defaults,noatime,_netdev  0 2
UUID=<generated>  /srv/portbill/backup  xfs  defaults,noatime,_netdev  0 2
```

`noatime` eliminates unnecessary write I/O on read operations. `_netdev` ensures mount ordering is correct in environments where storage may be network-attached. `0 2` schedules `fsck` after root (priority 1) at boot.

Mount point ownership: `root:billing-ops`, mode `2775` (setgid so new files inherit the group).

**RHCSA skills:** `pvcreate`, `vgcreate`, `lvcreate`, `mkfs.xfs`, `blkid`, `/etc/fstab`, `mount`, `semanage fcontext`, `restorecon`.

---

### `03_firewall_selinux.sh` — Firewall and SELinux Hardening

**What it does:**

Enforces SELinux, applies custom file context and boolean rules for the billing application, and configures firewalld with a dedicated zone that limits exposure to only what the application requires.

**SELinux configuration:**

| Resource | Context Applied | Why |
|----------|-----------------|-----|
| `/srv/portbill/data(/.*)?` | `httpd_sys_content_t` | Nginx/httpd can serve this content |
| `/srv/portbill/logs(/.*)?` | `var_log_t` | Standard log context for log rotation |
| Port 3000/tcp | `http_port_t` | Allows Podman container to bind |
| Port 2222/tcp | `ssh_port_t` | Non-standard SSH port allowance |

SELinux booleans enabled:
- `httpd_can_network_connect` — allows Nginx to proxy to the container
- `httpd_read_user_content` — allows serving content from `/srv`

**firewalld zone: `portbilling`**

The default zone remains `public` — all billing traffic is isolated in a dedicated zone assigned to the server's primary interface:

| Rule | Detail |
|------|--------|
| HTTP (80/tcp) | Open — rate-limited at Nginx layer |
| HTTPS (443/tcp) | Open |
| SSH (2222/tcp) | Rich rule: source restricted to admin `/24` subnet |
| Billing API (8080/tcp) | Open within zone |
| `--remove-service=ssh` | Removes default port 22 from zone |

Rate limiting: `firewalld` rich rule limits connection attempts to SSH; combined with Nginx `limit_req_zone` at application layer.

**RHCSA skills:** `setenforce`, `semanage fcontext`, `semanage port`, `setsebool -P`, `restorecon -Rv`, `firewall-cmd --new-zone`, `firewall-cmd --permanent`, `firewall-cmd --add-rich-rule`.

---

### `04_ssh_hardening.sh` — SSH Security Configuration

**What it does:**

Rewrites `sshd_config` to eliminate password-based authentication, restrict access to the `billing-admin` group, move SSH off port 22, enforce modern cryptography, and reduce the attack surface for brute-force and lateral movement.

**Key configuration changes:**

| Parameter | Value | Reason |
|-----------|-------|--------|
| `Port` | `2222` | Reduces noise from automated scanners targeting 22 |
| `PermitRootLogin` | `no` | No direct root access — use sudo |
| `PasswordAuthentication` | `no` | Key-only authentication |
| `AllowGroups` | `billing-admin` | Only designated admin accounts can SSH |
| `MaxAuthTries` | `3` | Locks out after 3 failed attempts per connection |
| `LoginGraceTime` | `30` | Connection must authenticate within 30 seconds |
| `MaxStartups` | `5:30:10` | Starts dropping unauthenticated connections at 5, drops all at 10 |
| `ClientAliveInterval` | `300` | Sends keepalive every 5 minutes |
| `X11Forwarding` | `no` | No X11 tunnelling |
| `AllowTcpForwarding` | `no` | No port forwarding / SOCKS proxy |
| `LogLevel` | `VERBOSE` | Logs key fingerprints for every connection |

**Cryptography (FIPS-compatible):**

```
KexAlgorithms    curve25519-sha256,diffie-hellman-group14-sha256
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
Ciphers          chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs             hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

Weak legacy algorithms (CBC ciphers, MD5 MACs, DSA host keys, diffie-hellman-group1) are implicitly excluded by this explicit allowlist.

The script uses an `ssh_set()` helper function that modifies `sshd_config` idempotently — setting a key if absent, replacing it if present — then runs `sshd -t` to validate the config before any restart.

**RHCSA skills:** `sshd -t`, `systemctl restart sshd`, `systemctl enable sshd`, `firewall-cmd --add-port`, `semanage port -a`.

---

### `05_service_deploy.sh` — Container and Web Server Deployment

**What it does:**

Deploys the billing application as a rootless Podman container behind an Nginx TLS reverse proxy, managed by a systemd unit with hardening directives. Performs a post-deploy health check loop.

**Container (Podman):**

```bash
podman run \
  --name portbill \
  --publish 127.0.0.1:3000:3000 \   # bind only to loopback — not externally reachable
  --volume /srv/portbill/data:/app/data:Z \   # :Z applies correct SELinux label
  --volume /srv/portbill/logs:/app/logs:Z \
  --env NODE_ENV=production \
  --read-only \                       # container filesystem is immutable
  --security-opt no-new-privileges \  # prevents privilege escalation inside container
  --health-cmd='curl -f http://localhost:3000/health || exit 1' \
  --health-interval=30s \
  ghcr.io/samiulAsumel/portbill:latest
```

The container is bound to `127.0.0.1:3000` — it is never directly exposed to the network. All external traffic goes through Nginx.

**Nginx configuration highlights:**

- TLS 1.2 and 1.3 only (`ssl_protocols TLSv1.2 TLSv1.3`)
- HSTS header: `Strict-Transport-Security: max-age=31536000; includeSubDomains`
- `server_tokens off` — hides Nginx version from error pages and headers
- `limit_req_zone` at 10 requests/second per IP
- Upstream health check to `127.0.0.1:3000`
- Gzip compression for JSON, JS, CSS, plain text
- `epoll` event model + `multi_accept on` for high-concurrency workloads

**Systemd unit (`portbill.service`) hardening directives:**

```ini
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/srv/portbill/data /srv/portbill/logs
```

`ProtectSystem=strict` makes the entire filesystem read-only from the service's perspective except for the explicitly listed `ReadWritePaths`. This means even if the container process escapes, it cannot write to system directories.

**Health check:** After enabling the service, the script runs a `curl` loop (up to 30 attempts, 2-second interval) to verify the application responds before reporting success.

**RHCSA skills:** `podman pull`, `podman run`, `systemctl daemon-reload`, `systemctl enable --now`, `systemctl is-active`, `journalctl -u`.

---

### `06_acl_backup.sh` — POSIX ACLs and Automated Backup

**What it does:**

Applies fine-grained POSIX ACL rules to the billing storage directories so each department gets exactly the access it needs — no more, no less. Then installs a systemd timer that runs a verified backup every day at 02:00.

**ACL matrix:**

| Directory | `billing-ops` | `port-managers` | `auditors` | `it-admin` |
|-----------|--------------|-----------------|------------|------------|
| `/srv/portbill/data` | `rwx` | `r-x` | `r-x` | `rwx` |
| `/srv/portbill/logs` | `r-x` | `r-x` | `r-x` | `rwx` |
| `/srv/portbill/backup` | `---` | `r-x` | `r-x` | `rwx` |

ACLs are applied with `setfacl --recursive --modify` and **default ACLs** are set so new files created inside each directory automatically inherit the correct permissions — without needing to re-run the script.

**Backup design:**

- **Schedule:** `OnCalendar=daily` (02:00) via systemd timer
- **Format:** `portbill-backup-YYYYMMDD-HHMMSS.tar.gz` in `/srv/portbill/backup/`
- **Integrity:** SHA-256 checksum written alongside every archive
- **Retention:** Archives older than 30 days are automatically purged at the end of each backup run
- **Persistent timer:** `Persistent=true` — if the server was off at 02:00, the backup runs immediately at next boot

**Timer/service pair:**

```
portbill-backup.timer  →  triggers  →  portbill-backup.service
                                           └── /usr/local/bin/portbill-backup.sh
```

**RHCSA skills:** `setfacl -R -m`, `setfacl -d -m`, `getfacl`, systemd `timer` unit files, `OnCalendar`, `Persistent=true`.

---

### `07_log_monitor.sh` — Log Routing, Rotation, and Alerting

**What it does:**

The most complex script (327 lines). Configures rsyslog to route billing application logs to dedicated files, sets logrotate policies, configures journald for persistent storage across reboots, and installs a disk-space monitoring daemon with alerting.

**rsyslog routing rules (`/etc/rsyslog.d/portbill.conf`):**

| Log Source | Destination File | Retention |
|------------|-----------------|-----------|
| `portbill` program logs | `/var/log/portbill/app.log` | 30 days, compressed |
| `portbill` error logs | `/var/log/portbill/error.log` | 90 days, compressed |
| Auth/SSH events | `/var/log/portbill/access.log` | 90 days, compressed |
| Nginx access log | piped via `imfile` module | 30 days |

rsyslog config is validated with `rsyslogd -N1` before restarting the service.

**logrotate configuration (`/etc/logrotate.d/portbill`):**

```
/var/log/portbill/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root billing-ops
    postrotate
        systemctl reload rsyslog
    endscript
}
```

`delaycompress` keeps the most recent rotated file uncompressed for 24 hours — useful for incident response when you need to `grep` a log that was just rotated.

**journald persistent storage:**

Sets `Storage=persistent` in `/etc/systemd/journald.conf` and creates `/var/log/journal/` so journal data survives reboots. Without this, RHEL 9 defaults to volatile (in-memory) journal storage that is lost on restart.

**Disk-space monitor (`/usr/local/bin/portbill-disk-alert.sh`):**

- Checks disk usage on all three billing mount points every 15 minutes
- Alerts (writes to syslog and can be extended to send email/webhook) if any mount exceeds the configured threshold (default: 85%)
- Managed by `portbill-disk-monitor.timer` with `OnCalendar=*:0/15`

**RHCSA skills:** `rsyslog` configuration, `logrotate`, `journalctl --disk-usage`, `journalctl --vacuum-time`, systemd timer with calendar expressions, `logger` for syslog injection.

---

## Configuration Reference Files

### `config/nginx.conf`

The main Nginx configuration. Notable settings:

- `worker_processes auto` — scales to available CPU cores
- `use epoll` — Linux-native async I/O, more efficient than `select`/`poll`
- `server_tokens off` — do not expose Nginx version in `Server:` header or error pages
- `limit_req_zone $binary_remote_addr zone=billing_limit:10m rate=10r/s` — rate-limit zone keyed per source IP, stored in a 10 MB shared memory zone

### `config/portbill.service`

The systemd unit for the billing container. Key design decisions:

- `After=network-online.target` and `Wants=network-online.target` — waits for full network stack, not just network interface up
- `RequiresMountsFor=/srv/portbill` — systemd will not start the service until all three LVM mounts are confirmed present
- `ExecStartPre` cleans up any stale container from a previous crash before starting a fresh one
- `Restart=on-failure` with `RestartSec=10s` — automatic recovery, 10-second cooldown between attempts

### `config/sshd_config.hardened`

Annotated reference for the SSH hardening config. Based on:

- NIST SP 800-123 (Guide to General Server Security)
- CIS Red Hat Enterprise Linux 9 Benchmark

---

## Security Design

The project implements **defence in depth**: multiple independent security layers so that compromise of one layer does not give an attacker full access.

```
Internet
   │
   ▼
firewalld (portbilling zone)
   │  — only 80, 443, 2222 reachable from outside
   │  — 2222 further restricted to admin /24 subnet
   ▼
SELinux (enforcing)
   │  — processes confined to their declared context
   │  — httpd/nginx cannot access files outside httpd_sys_content_t
   ▼
Nginx (TLS 1.3, HSTS, rate limiting)
   │  — all plaintext HTTP redirected to HTTPS
   │  — request rate capped per source IP
   ▼
Podman container (read-only FS, no-new-privileges)
   │  — even if app is compromised, cannot write to OS
   │  — cannot escalate to root inside container
   ▼
POSIX ACLs + LVM isolation
   │  — each department can only access its allowed directories
   │  — data, logs, backup on separate volumes (blast radius containment)
   ▼
systemd unit hardening (ProtectSystem=strict, PrivateTmp)
   │  — service process cannot write to /usr, /boot, /etc
   ▼
Journald + rsyslog + disk-alert
   └  — all security events logged, retained, monitored
```

---

## Department Access Model

| Resource | `billing-ops` | `port-managers` | `auditors` | `billing-admin` | `it-admin` |
|----------|:---:|:---:|:---:|:---:|:---:|
| `/srv/portbill/data` | RWX | RX | RX | RWX | RWX |
| `/srv/portbill/logs` | RX | RX | RX | RWX | RWX |
| `/srv/portbill/backup` | — | RX | RX | RWX | RWX |
| SSH access | — | — | — | yes | yes |
| `sudo systemctl` | — | — | — | yes | yes |
| `sudo journalctl` | — | — | — | yes | yes |
| Nginx admin | — | — | — | — | yes |

---

## RHCSA EX200 Skills Coverage

| RHCSA Objective | Script | Techniques Used |
|-----------------|--------|-----------------|
| Manage users and groups | `01` | `useradd -u -g -s -m`, `groupadd -g`, `usermod -aG`, `chage -M -m -W -I` |
| Configure password aging | `01` | `chage`, `/etc/login.defs`, `PASS_MAX_DAYS` |
| Configure sudo access | `01` | `/etc/sudoers.d/`, `visudo -c` validation |
| Create and manage LVM | `02` | `pvcreate`, `vgcreate`, `lvcreate -L -n` |
| Create XFS filesystems | `02` | `mkfs.xfs -L`, `xfs_info` |
| Mount filesystems persistently | `02` | `blkid`, `/etc/fstab`, UUID-based mounts |
| Configure SELinux file contexts | `02`, `03` | `semanage fcontext -a -t`, `restorecon -Rv` |
| Configure SELinux booleans | `03` | `setsebool -P` |
| Configure SELinux port contexts | `03`, `04` | `semanage port -a -t` |
| Configure firewalld | `03` | `firewall-cmd --new-zone`, `--add-service`, `--add-port`, `--add-rich-rule` |
| Configure SSH service | `04` | `sshd_config` editing, `sshd -t`, `systemctl restart sshd` |
| Manage systemd services | `05` | `systemctl enable --now`, `systemctl is-active`, unit files |
| Configure systemd timers | `06`, `07` | `[Timer]` section, `OnCalendar`, `Persistent=true` |
| Configure ACLs | `06` | `setfacl -R -m u::`, `setfacl -d -m`, `getfacl` |
| Configure log forwarding | `07` | `/etc/rsyslog.d/`, `rsyslogd -N1`, `systemctl restart rsyslog` |
| Manage log rotation | `07` | `/etc/logrotate.d/`, `logrotate -d` (dry test) |
| Use journalctl | `07` | `journalctl -u`, `--disk-usage`, `--vacuum-time`, `Storage=persistent` |
| Schedule recurring jobs | `06`, `07` | systemd timers (preferred over cron on RHEL 9) |
| Manage containers with Podman | `05` | `podman pull`, `podman run`, `podman stop`, `podman rm` |

---

## Web Showcase

The project includes an interactive portfolio website (`index.html`) that presents the infrastructure work visually. It is deployed to GitHub Pages / Vercel and is the public face of the project.

**Features:**

- **Hero section** — project title, animated stats bar showing key metrics (7 scripts, 1,457 lines, 23+ RHCSA skills, 5 departments, 3 storage volumes)
- **Architecture section** — visual breakdown of the infrastructure stack with animated cards
- **Scripts section** — interactive script viewer with syntax highlighting (via highlight.js), line numbers, copy-to-clipboard, and download buttons
- **Deployment Playground** — a fully simulated deployment environment where users can set configuration parameters (hostname, admin IP, disk device, container tag) and watch a step-by-step animated "deployment" play out through all 7 scripts with live log output
- **Dark theme** — industrial/terminal aesthetic: deep navy background, cyan/green accents, monospace fonts, scanline texture
- **Deployment progress bar** — tracks progress through all 7 deployment stages with animated step indicators

**Tech stack:**

- Vanilla HTML5, CSS3 (no framework), vanilla JavaScript (no bundler)
- highlight.js for syntax highlighting (CDN, no build step)
- CSS custom properties for the entire design system
- CSS `@keyframes` for all animations (no GSAP dependency)
- `IntersectionObserver` for scroll-triggered reveals
- `navigator.clipboard` API for copy functionality
- Blob URL + anchor for script download

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| OS | RHEL 9 (or compatible: Rocky Linux 9, AlmaLinux 9) |
| Shell | Bash 5.1+ |
| Packages | `lvm2`, `xfsprogs`, `policycoreutils-python-utils`, `firewalld`, `nginx`, `podman`, `rsyslog`, `logrotate` |
| Storage | Second block device ≥ 30 GB for LVM |
| Network | Internet access for `podman pull` |
| SSH key | ed25519 or RSA public key before running script 04 |

Install all required packages at once:

```bash
dnf install -y lvm2 xfsprogs policycoreutils-python-utils \
               firewalld nginx podman rsyslog logrotate
```

---

## Idempotency

All scripts are safe to re-run. Before creating any resource, each script checks whether it already exists:

- `pvs <device>` — skip PV creation if already a PV
- `vgs <vgname>` — skip VG creation if already exists
- `lvs <lvpath>` — skip LV creation if already exists
- `grep UUID /etc/fstab` — skip fstab entry if already present
- `mountpoint -q <path>` — skip mount if already mounted
- `firewall-cmd --query-*` — skip firewall rule if already active
- `grep <key> /etc/ssh/sshd_config` — update existing key rather than duplicate it

This means the scripts can be run in a CI/CD pipeline or re-applied after a partial failure without causing double-provisioning errors.

---

## Author

**Samiul A Sumel**  
Junior DevOps Engineer · RHCSA EX200 Candidate  
Building production-grade Linux infrastructure, one script at a time.

- GitHub: [samiulAsumel](https://github.com/samiulAsumel)
- Email: sa.sumel91@gmail.com

---

*1,457 lines of Bash across 7 scripts. 143 lines of reference config. Built to pass RHCSA EX200 and hold up in production.*
