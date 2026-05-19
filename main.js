/* Smart Port Billing Infrastructure — main.js
   Script explorer with line numbers · Copy · Download · Toast
   Terminal animation · Scroll reveals · Skills · Counters
   ─────────────────────────────────────────────────────────── */
'use strict';

// ════════════════════════════════════════════════════════════════════════
// SCRIPT REGISTRY  (file · description · RHCSA tags)
// ════════════════════════════════════════════════════════════════════════
const SCRIPTS = [
  {
    file: '01_user_group_setup.sh',
    desc: 'Creates 4 department groups, 5 named users with forced password change, 90-day chage policy, sudo rules in sudoers.d, and 0750 home directories. Idempotent — safe to re-run.',
    tags: ['useradd', 'groupadd', 'chage', 'visudo', 'sudoers.d', 'RHCSA EX200'],
  },
  {
    file: '02_storage_lvm.sh',
    desc: 'Provisions a Physical Volume on a block device, creates the portbill-vg Volume Group, carves 3 Logical Volumes (data 10G, logs 5G, backup 15G), formats XFS, writes UUID-based fstab entries, mounts, and applies SELinux file contexts.',
    tags: ['pvcreate', 'vgcreate', 'lvcreate', 'mkfs.xfs', 'blkid', 'fstab', 'LVM', 'XFS'],
  },
  {
    file: '03_firewall_selinux.sh',
    desc: 'Creates a dedicated portbilling firewall zone with rich rules (SSH restricted to admin /24, HTTPS to billing LAN, HTTP rate-limited). Enforces SELinux, sets custom fcontext for all billing paths, and configures httpd booleans — persistent across reboots.',
    tags: ['firewall-cmd', 'rich rules', 'semanage', 'setsebool', 'restorecon', 'enforcing'],
  },
  {
    file: '04_ssh_hardening.sh',
    desc: 'Backs up sshd_config, writes a hardened config (port 2222, key-only auth, AllowGroups billing-admin, FIPS-grade ciphers, all forwarding disabled), validates syntax with sshd -t before restarting, writes legal banner, and labels the custom port with SELinux.',
    tags: ['sshd_config', 'PubkeyAuthentication', 'AllowGroups', 'MaxAuthTries', 'CIS', 'NIST'],
  },
  {
    file: '05_service_deploy.sh',
    desc: 'Pulls the portbill Podman image, writes a hardened systemd unit (NoNewPrivileges, PrivateTmp, ProtectSystem), generates a self-signed TLS cert, configures Nginx as a TLS 1.3 reverse proxy with security headers, and polls the /health endpoint to confirm the container is live.',
    tags: ['podman run', 'systemd unit', 'nginx', 'TLS 1.3', 'health check', 'ExecStart'],
  },
  {
    file: '06_acl_backup.sh',
    desc: 'Sets granular POSIX ACLs with default inheritance on all 3 billing volumes (billing-admin:rwx, billing-ops:rwx, port-ops:r-x, readonly:r-x), writes a backup script with SHA-256 integrity checking, and enables a systemd timer for nightly 02:00 backups with 30-day retention.',
    tags: ['setfacl', 'getfacl', 'default ACL', 'sha256sum', 'systemd timer', 'tar --acls'],
  },
  {
    file: '07_log_monitor.sh',
    desc: 'Configures rsyslog to route portbill service messages and billing audit events to dedicated log files, sets up logrotate with 90-day retention and postrotate hooks, deploys a real-time monitoring service that alerts on critical patterns, and enables a daily summary timer.',
    tags: ['journalctl', 'rsyslog', 'logrotate', 'alerting', 'logger', 'persistent journal'],
  },
];

// ════════════════════════════════════════════════════════════════════════
// HERO TERMINAL ANIMATION
// ════════════════════════════════════════════════════════════════════════
const TERMINAL_SEQUENCES = [
  {
    cmd: 'sudo bash scripts/01_user_group_setup.sh',
    lines: [
      { cls: 'term-line-info', text: '[08:42:15] INFO  Starting Port Billing user provisioning...' },
      { cls: 'term-line-ok',   text: '[08:42:16]  OK   Created group: billing-admin' },
      { cls: 'term-line-ok',   text: '[08:42:16]  OK   Created user: portadmin → billing-admin' },
      { cls: 'term-line-ok',   text: '[08:42:17]  OK   Sudo rules written: /etc/sudoers.d/portbill' },
    ],
  },
  {
    cmd: 'sudo bash scripts/03_firewall_selinux.sh',
    lines: [
      { cls: 'term-line-info', text: '[08:44:01] INFO  Configuring firewalld zones...' },
      { cls: 'term-line-ok',   text: '[08:44:02]  OK   Zone created: portbilling (target=REJECT)' },
      { cls: 'term-line-ok',   text: '[08:44:03]  OK   Rich rule: SSH :2222 ← 192.168.10.0/24' },
      { cls: 'term-line-ok',   text: '[08:44:04]  OK   SELinux set to enforcing (persistent)' },
    ],
  },
  {
    cmd: 'sudo bash scripts/04_ssh_hardening.sh',
    lines: [
      { cls: 'term-line-info', text: '[08:45:10] INFO  Writing hardened SSH configuration...' },
      { cls: 'term-line-ok',   text: '[08:45:11]  OK   Port 2222 · PasswordAuthentication no' },
      { cls: 'term-line-ok',   text: '[08:45:12]  OK   Configuration syntax valid' },
      { cls: 'term-line-ok',   text: '[08:45:13]  OK   sshd restarted and enabled' },
    ],
  },
  {
    cmd: 'sudo bash scripts/05_service_deploy.sh',
    lines: [
      { cls: 'term-line-info', text: '[08:46:00] INFO  Pulling container image...' },
      { cls: 'term-line-ok',   text: '[08:46:18]  OK   Container image ready: portbill:latest' },
      { cls: 'term-line-ok',   text: '[08:46:20]  OK   Nginx configuration syntax valid' },
      { cls: 'term-line-ok',   text: '[08:46:22]  OK   Health check passed — portbill running' },
    ],
  },
];

// DOM refs for hero terminal
const termCmd   = document.getElementById('term-cmd');
const termLines = document.getElementById('term-lines');

let seqIdx = 0;

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function typeText(el, text, speed = 36) {
  el.textContent = '';
  for (const ch of text) {
    el.textContent += ch;
    await sleep(speed + Math.random() * 18);
  }
}

async function runTermSequence() {
  if (!termCmd || !termLines) return;
  while (true) {
    const seq = TERMINAL_SEQUENCES[seqIdx % TERMINAL_SEQUENCES.length];
    seqIdx++;

    termLines.innerHTML = '';
    await typeText(termCmd, seq.cmd, 32);
    await sleep(280);

    for (const ld of seq.lines) {
      const d = document.createElement('div');
      d.className = ld.cls;
      termLines.appendChild(d);
      await typeText(d, ld.text, 11);
      await sleep(130);
    }

    await sleep(3400);
    termLines.style.transition = 'opacity 0.5s';
    termLines.style.opacity = '0';
    await sleep(550);
    termCmd.textContent = '';
    termLines.innerHTML = '';
    termLines.style.opacity = '1';
    await sleep(400);
  }
}
runTermSequence();

// ════════════════════════════════════════════════════════════════════════
// TOAST NOTIFICATION
// ════════════════════════════════════════════════════════════════════════
function showToast(message, type = 'success') {
  document.querySelectorAll('.toast').forEach(t => t.remove());

  const icons = { success: '✓', error: '✗', info: 'ℹ' };
  const t = document.createElement('div');
  t.className = `toast toast-${type}`;
  t.setAttribute('role', 'status');
  t.setAttribute('aria-live', 'polite');
  t.innerHTML =
    `<span class="toast-icon" aria-hidden="true">${icons[type] ?? icons.info}</span>` +
    `<span class="toast-msg">${message}</span>`;
  document.body.appendChild(t);

  requestAnimationFrame(() => t.classList.add('toast-show'));
  setTimeout(() => {
    t.classList.remove('toast-show');
    setTimeout(() => t.remove(), 320);
  }, 2600);
}

// ════════════════════════════════════════════════════════════════════════
// SCRIPT EXPLORER — with line numbers, copy & download
// ════════════════════════════════════════════════════════════════════════
let currentRaw = '';
const scriptCache = new Map();

async function loadScript(filename) {
  if (scriptCache.has(filename)) return scriptCache.get(filename);

  // Embedded content first (works file://)
  if (typeof SCRIPT_CONTENT !== 'undefined' && SCRIPT_CONTENT[filename]) {
    scriptCache.set(filename, SCRIPT_CONTENT[filename]);
    return SCRIPT_CONTENT[filename];
  }
  // Fallback: network
  try {
    const res = await fetch(`./scripts/${filename}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    scriptCache.set(filename, text);
    return text;
  } catch {
    return `#!/usr/bin/env bash\n# ${filename}\n# Script content unavailable — open via GitHub Pages or Vercel.`;
  }
}

function highlightBash(raw) {
  if (typeof hljs !== 'undefined') {
    return hljs.highlight(raw, { language: 'bash', ignoreIllegals: true }).value;
  }
  return raw.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function buildCodeHtml(raw) {
  const highlighted = highlightBash(raw);
  const lines = highlighted.split('\n');
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
  return lines.map((line, i) =>
    `<div class="code-row">\
<span class="ln" aria-hidden="true">${i + 1}</span>\
<span class="lc">${line || '​'}</span></div>`
  ).join('');
}

async function showScript(filename, idx) {
  const meta    = SCRIPTS[idx];
  const wrapEl  = document.getElementById('viewer-code-wrap');
  const fileEl  = document.getElementById('viewer-filename');
  const lcEl    = document.getElementById('viewer-linecount');
  const descEl  = document.getElementById('viewer-desc');
  const tagsEl  = document.getElementById('viewer-tags');
  if (!wrapEl) return;

  fileEl.textContent = filename;
  wrapEl.innerHTML = '<div class="viewer-loading"><span class="loading-dot"></span><span class="loading-dot"></span><span class="loading-dot"></span></div>';

  const raw = await loadScript(filename);
  currentRaw = raw;

  const lineCount = raw.split('\n').length;
  const kbSize    = (new TextEncoder().encode(raw).length / 1024).toFixed(1);
  lcEl.textContent = `${lineCount} lines · ${kbSize} KB`;

  wrapEl.innerHTML = buildCodeHtml(raw);

  if (descEl) descEl.textContent = meta.desc || '';
  if (tagsEl) tagsEl.innerHTML = meta.tags.map(t => `<span class="stag">${t}</span>`).join('');
}

// Tab switching
document.querySelectorAll('.script-tab').forEach((tab, _) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.script-tab').forEach(t => {
      t.classList.remove('active');
      t.setAttribute('aria-selected', 'false');
    });
    tab.classList.add('active');
    tab.setAttribute('aria-selected', 'true');
    showScript(tab.dataset.script, parseInt(tab.dataset.idx, 10));
  });
});

// Keyboard navigation (↑/↓ arrows in script list)
document.querySelectorAll('.script-tab').forEach((tab, i, all) => {
  tab.setAttribute('tabindex', i === 0 ? '0' : '-1');
  tab.addEventListener('keydown', e => {
    let next = -1;
    if (e.key === 'ArrowDown') next = Math.min(i + 1, all.length - 1);
    if (e.key === 'ArrowUp')   next = Math.max(i - 1, 0);
    if (next >= 0) {
      all.forEach((t, j) => t.setAttribute('tabindex', j === next ? '0' : '-1'));
      all[next].focus();
      all[next].click();
      e.preventDefault();
    }
  });
});

// Copy button
document.getElementById('viewer-copy')?.addEventListener('click', async () => {
  const filename = document.getElementById('viewer-filename')?.textContent;
  const raw = (typeof SCRIPT_CONTENT !== 'undefined' && SCRIPT_CONTENT[filename])
    ? SCRIPT_CONTENT[filename] : currentRaw;
  try {
    await navigator.clipboard.writeText(raw);
    showToast(`Copied ${filename}`, 'success');
  } catch {
    showToast('Copy failed — select all and Ctrl+C', 'error');
  }
});

// Download button
document.getElementById('viewer-download')?.addEventListener('click', () => {
  const filename = document.getElementById('viewer-filename')?.textContent;
  const raw = (typeof SCRIPT_CONTENT !== 'undefined' && SCRIPT_CONTENT[filename])
    ? SCRIPT_CONTENT[filename] : currentRaw;
  const blob = new Blob([raw], { type: 'text/x-sh; charset=utf-8' });
  const url  = URL.createObjectURL(blob);
  const a    = Object.assign(document.createElement('a'), { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  showToast(`Downloaded ${filename}`, 'success');
});

// Load first script on init
showScript(SCRIPTS[0].file, 0);

// ════════════════════════════════════════════════════════════════════════
// SECURITY TABS
// ════════════════════════════════════════════════════════════════════════
document.querySelectorAll('.sec-tab').forEach(tab => {
  tab.addEventListener('click', () => {
    const target = tab.dataset.sec;
    document.querySelectorAll('.sec-tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');
    document.querySelectorAll('.sec-panel').forEach(p => p.classList.remove('active'));
    const panel = document.getElementById(`sec-${target}`);
    if (!panel) return;
    panel.classList.add('active');
    if (typeof hljs !== 'undefined') {
      panel.querySelectorAll('code:not([data-highlighted])').forEach(c => hljs.highlightElement(c));
    }
  });
});

// ════════════════════════════════════════════════════════════════════════
// SCROLL REVEAL
// ════════════════════════════════════════════════════════════════════════
const revealObs = new IntersectionObserver(entries => {
  entries.forEach((e, i) => {
    if (e.isIntersecting) {
      setTimeout(() => e.target.classList.add('visible'), i * 75);
      revealObs.unobserve(e.target);
    }
  });
}, { threshold: 0.1 });
document.querySelectorAll('.reveal').forEach(el => revealObs.observe(el));

// ════════════════════════════════════════════════════════════════════════
// SKILL BARS
// ════════════════════════════════════════════════════════════════════════
const barObs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      const w = e.target.dataset.width ?? 0;
      setTimeout(() => { e.target.style.width = `${w}%`; }, 180);
      barObs.unobserve(e.target);
    }
  });
}, { threshold: 0.3 });
document.querySelectorAll('.skill-bar').forEach(b => barObs.observe(b));

// ════════════════════════════════════════════════════════════════════════
// COUNTER ANIMATION
// ════════════════════════════════════════════════════════════════════════
function animateCounter(el, target, duration = 1200) {
  const start = performance.now();
  const tick = now => {
    const p = Math.min((now - start) / duration, 1);
    el.textContent = Math.round((1 - Math.pow(1 - p, 3)) * target);
    if (p < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
const ctrObs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      const n = parseInt(e.target.dataset.count, 10);
      if (!isNaN(n)) animateCounter(e.target, n);
      ctrObs.unobserve(e.target);
    }
  });
}, { threshold: 0.5 });
document.querySelectorAll('[data-count]').forEach(el => ctrObs.observe(el));

// ════════════════════════════════════════════════════════════════════════
// HEADER — active nav link on scroll + scrolled shadow
// ════════════════════════════════════════════════════════════════════════
const navLinks = document.querySelectorAll('.nav-link');
const header   = document.getElementById('site-header');

const secObs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      navLinks.forEach(l => l.classList.toggle('active', l.getAttribute('href') === `#${e.target.id}`));
    }
  });
}, { rootMargin: '-60px 0px -50% 0px' });
document.querySelectorAll('section[id]').forEach(s => secObs.observe(s));

window.addEventListener('scroll', () => {
  header?.classList.toggle('scrolled', window.scrollY > 20);
}, { passive: true });

// ════════════════════════════════════════════════════════════════════════
// ARCHITECTURE SVG — native title tooltips
// ════════════════════════════════════════════════════════════════════════
document.querySelectorAll('.arch-node[data-tip]').forEach(node => {
  const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
  title.textContent = node.dataset.tip;
  node.prepend(title);
});

// ════════════════════════════════════════════════════════════════════════
// HIGHLIGHT.JS — security section static code blocks
// Scripts are at end of <body>, so DOM is ready — no DOMContentLoaded needed
// ════════════════════════════════════════════════════════════════════════
if (typeof hljs !== 'undefined') {
  document.querySelectorAll('.sec-code-wrap code').forEach(b => hljs.highlightElement(b));
}
