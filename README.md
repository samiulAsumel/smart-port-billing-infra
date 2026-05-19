# Smart Port Billing Infrastructure on RHEL 9

> RHCSA-based enterprise Linux deployment for maritime port billing operations — 7 hardened Bash scripts covering the full RHCSA EX200 skill set.

---

## Overview

This project deploys and manages a secure port billing application on a Red Hat Enterprise Linux 9 server. It demonstrates production-grade sysadmin skills across user management, storage, networking, security, containerisation, and observability.

**Real-world problem:** Port billing applications require stable, secure, and continuously available infrastructure with strict access controls for multiple operational departments.

**Solution:** A fully automated RHEL 9 deployment pipeline using RHCSA-aligned Bash scripts — run in order, idempotent, ShellCheck-clean.

---

## Project Structure

```
smart-port-billing-infra/
├── scripts/
│   ├── 01_user_group_setup.sh    # User & Group Management
│   ├── 02_storage_lvm.sh         # LVM + XFS Storage Provisioning
│   ├── 03_firewall_selinux.sh    # firewalld + SELinux Hardening
│   ├── 04_ssh_hardening.sh       # SSH Security Configuration
│   ├── 05_service_deploy.sh      # Podman + Nginx Deployment
│   ├── 06_acl_backup.sh          # ACLs + Automated Backup Timer
│   └── 07_log_monitor.sh         # Log Routing, Rotation & Alerting
├── config/
│   ├── nginx.conf                # Nginx production configuration
│   ├── portbill.service          # Systemd unit file reference
│   └── sshd_config.hardened      # Hardened SSH config reference
├── index.html                    # Portfolio showcase website
├── style.css
├── main.js
└── README.md
```

---

## Deployment Order

Run scripts as root on a freshly installed RHEL 9 server:

```bash
# 1. Create users and groups
sudo bash scripts/01_user_group_setup.sh

# 2. Provision LVM storage (pass your block device)
sudo bash scripts/02_storage_lvm.sh /dev/sdb

# 3. Harden firewall and SELinux
sudo bash scripts/03_firewall_selinux.sh

# 4. Harden SSH (add your public key first!)
echo "ssh-ed25519 AAAA... you@host" >> /home/portadmin/.ssh/authorized_keys
sudo bash scripts/04_ssh_hardening.sh

# 5. Deploy application (Podman + Nginx)
sudo bash scripts/05_service_deploy.sh

# 6. Set ACLs and enable backup timer
sudo bash scripts/06_acl_backup.sh

# 7. Set up log monitoring
sudo bash scripts/07_log_monitor.sh
```

---

## RHCSA Skills Demonstrated

| Script | RHCSA Objective |
|--------|----------------|
| `01_user_group_setup.sh` | User & Group Management, Password Policy, sudo |
| `02_storage_lvm.sh` | LVM (PV/VG/LV), XFS filesystem, persistent fstab |
| `03_firewall_selinux.sh` | firewalld zones, rich rules, SELinux fcontext & booleans |
| `04_ssh_hardening.sh` | SSH service configuration, key-based auth |
| `05_service_deploy.sh` | Systemd unit files, service management, boot persistence |
| `06_acl_backup.sh` | POSIX ACLs (setfacl/getfacl), systemd timers |
| `07_log_monitor.sh` | journalctl, rsyslog routing, logrotate |

---

## Security Highlights

- **SELinux enforcing** — custom fcontext rules for all billing directories and ports
- **firewalld** — dedicated `portbilling` zone, admin SSH restricted to `/24` subnet, HTTP rate-limited
- **SSH** — port 2222, key-only auth, `billing-admin` group restriction, FIPS-compatible ciphers
- **Podman** — read-only container filesystem, `--security-opt no-new-privileges`, `:Z` volume labels
- **Nginx** — TLS 1.2/1.3 only, HSTS, security headers, upstream health checks
- **Backup** — daily tar.gz with SHA-256 checksums, 30-day retention via systemd timer

---

## Technologies

RHEL 9 · Nginx · Podman · Bash · SELinux · LVM · XFS · firewalld · systemd · rsyslog · logrotate · Firebase · Vercel

---

## Author

**Samiul A. Sumel** — Junior DevOps Engineer · RHCSA EX200 Candidate  
GitHub: [samiulAsumel](https://github.com/samiulAsumel)
