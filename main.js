/* Smart Port Billing Infrastructure — Main JS
   Terminal animation · Script explorer · Scroll reveals · Skills bars
   ─────────────────────────────────────────────────────────────────── */

'use strict';

// ── Script metadata & RHCSA tags ─────────────────────────────────────────────
const SCRIPTS = [
  {
    file: '01_user_group_setup.sh',
    tags: ['useradd', 'groupadd', 'chage', 'visudo', 'sudoers.d', 'RHCSA'],
  },
  {
    file: '02_storage_lvm.sh',
    tags: ['pvcreate', 'vgcreate', 'lvcreate', 'mkfs.xfs', 'blkid', 'fstab', 'LVM', 'XFS'],
  },
  {
    file: '03_firewall_selinux.sh',
    tags: ['firewall-cmd', 'rich rules', 'semanage', 'setsebool', 'restorecon', 'SELinux'],
  },
  {
    file: '04_ssh_hardening.sh',
    tags: ['sshd_config', 'PubkeyAuthentication', 'AllowGroups', 'MaxAuthTries', 'CIS'],
  },
  {
    file: '05_service_deploy.sh',
    tags: ['podman run', 'systemd unit', 'nginx', 'TLS', 'health check', 'ExecStart'],
  },
  {
    file: '06_acl_backup.sh',
    tags: ['setfacl', 'getfacl', 'default ACL', 'sha256sum', 'systemd timer', 'tar'],
  },
  {
    file: '07_log_monitor.sh',
    tags: ['journalctl', 'rsyslog', 'logrotate', 'alerting', 'logger', 'logmonitor'],
  },
];

// ── Terminal sequences ────────────────────────────────────────────────────────
const TERMINAL_SEQUENCES = [
  {
    cmd: 'sudo ./scripts/01_user_group_setup.sh',
    lines: [
      { cls: 'term-line-info',  text: '[08:42:15] INFO  Starting user provisioning...' },
      { cls: 'term-line-ok',    text: '[08:42:16]  OK   Created group: billing-admin' },
      { cls: 'term-line-ok',    text: '[08:42:16]  OK   Created user: portadmin → billing-admin' },
      { cls: 'term-line-ok',    text: '[08:42:17]  OK   Sudo rules written: /etc/sudoers.d/portbill' },
    ],
  },
  {
    cmd: 'sudo ./scripts/03_firewall_selinux.sh',
    lines: [
      { cls: 'term-line-info',  text: '[08:44:01] INFO  Configuring firewalld zones...' },
      { cls: 'term-line-ok',    text: '[08:44:02]  OK   Zone created: portbilling' },
      { cls: 'term-line-ok',    text: '[08:44:03]  OK   Rich rule: SSH port 2222 → admin subnet' },
      { cls: 'term-line-ok',    text: '[08:44:04]  OK   SELinux set to enforcing (persistent)' },
    ],
  },
  {
    cmd: 'sudo ./scripts/05_service_deploy.sh',
    lines: [
      { cls: 'term-line-info',  text: '[08:45:10] INFO  Pulling container image...' },
      { cls: 'term-line-ok',    text: '[08:45:28]  OK   Container image ready: portbill:latest' },
      { cls: 'term-line-ok',    text: '[08:45:29]  OK   Nginx configuration syntax valid' },
      { cls: 'term-line-ok',    text: '[08:45:31]  OK   Health check passed — portbill running' },
    ],
  },
];

// ── DOM references ────────────────────────────────────────────────────────────
const termCmd    = document.getElementById('term-cmd');
const termLines  = document.getElementById('term-lines');
const viewerCode = document.getElementById('viewer-code');
const viewerFile = document.getElementById('viewer-filename');
const viewerLc   = document.getElementById('viewer-linecount');
const viewerTags = document.getElementById('viewer-tags');

// ══════════════════════════════════════════════════════════════════════════════
// TERMINAL ANIMATION
// ══════════════════════════════════════════════════════════════════════════════
let seqIdx = 0;
let termRunning = false;

async function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function typeText(el, text, speed = 38) {
  el.textContent = '';
  for (const ch of text) {
    el.textContent += ch;
    await sleep(speed + Math.random() * 20);
  }
}

async function runTermSequence() {
  if (termRunning) return;
  termRunning = true;

  while (true) {
    const seq = TERMINAL_SEQUENCES[seqIdx % TERMINAL_SEQUENCES.length];
    seqIdx++;

    termLines.innerHTML = '';
    await typeText(termCmd, seq.cmd, 35);
    await sleep(300);

    for (const lineData of seq.lines) {
      const div = document.createElement('div');
      div.className = lineData.cls;
      termLines.appendChild(div);
      await typeText(div, lineData.text, 12);
      await sleep(150);
    }

    await sleep(3200);

    // Fade out
    termLines.style.transition = 'opacity 0.5s';
    termLines.style.opacity = '0';
    await sleep(600);
    termCmd.textContent = '';
    termLines.innerHTML = '';
    termLines.style.opacity = '1';
    await sleep(500);
  }
}

// Start terminal animation on page load
runTermSequence();

// ══════════════════════════════════════════════════════════════════════════════
// SCRIPT EXPLORER
// ══════════════════════════════════════════════════════════════════════════════

// Use embedded content from scripts-data.js (works without a web server).
// Falls back to fetch() if SCRIPT_CONTENT is not available (e.g. GitHub Pages CDN).
const scriptCache = new Map();

async function loadScript(filename) {
  if (scriptCache.has(filename)) return scriptCache.get(filename);

  // Prefer embedded content — instant, no network, works file://
  if (typeof SCRIPT_CONTENT !== 'undefined' && SCRIPT_CONTENT[filename]) {
    scriptCache.set(filename, SCRIPT_CONTENT[filename]);
    return SCRIPT_CONTENT[filename];
  }

  // Fallback: try fetch (works on GitHub Pages / Vercel)
  try {
    const res = await fetch(`./scripts/${filename}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    scriptCache.set(filename, text);
    return text;
  } catch {
    return `# ${filename}\n# (Could not load — open via GitHub Pages or a local web server)`;
  }
}

async function showScript(filename, idx) {
  const meta = SCRIPTS[idx];

  viewerFile.textContent = filename;
  viewerCode.textContent = 'Loading...';

  const code = await loadScript(filename);
  viewerCode.className = 'language-bash hljs';
  viewerCode.textContent = code;

  if (typeof hljs !== 'undefined') {
    hljs.highlightElement(viewerCode);
  }

  const lines = code.split('\n').length;
  viewerLc.textContent = `${lines} lines`;

  viewerTags.innerHTML = meta.tags
    .map(t => `<span class="stag">${t}</span>`)
    .join('');
}

document.querySelectorAll('.script-tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.script-tab').forEach(t => {
      t.classList.remove('active');
      t.setAttribute('aria-selected', 'false');
    });
    tab.classList.add('active');
    tab.setAttribute('aria-selected', 'true');

    const filename = tab.dataset.script;
    const idx      = parseInt(tab.dataset.idx, 10);
    showScript(filename, idx);
  });
});

// Load first script on init
showScript(SCRIPTS[0].file, 0);

// ══════════════════════════════════════════════════════════════════════════════
// SECURITY TABS
// ══════════════════════════════════════════════════════════════════════════════
document.querySelectorAll('.sec-tab').forEach(tab => {
  tab.addEventListener('click', () => {
    const target = tab.dataset.sec;

    document.querySelectorAll('.sec-tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');

    document.querySelectorAll('.sec-panel').forEach(p => p.classList.remove('active'));
    const panel = document.getElementById(`sec-${target}`);
    if (panel) panel.classList.add('active');

    // Re-highlight any code in the newly visible panel
    if (typeof hljs !== 'undefined') {
      panel.querySelectorAll('code').forEach(c => {
        if (!c.dataset.highlighted) hljs.highlightElement(c);
      });
    }
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// SCROLL REVEAL
// ══════════════════════════════════════════════════════════════════════════════
const revealObserver = new IntersectionObserver(
  entries => {
    entries.forEach((entry, i) => {
      if (entry.isIntersecting) {
        setTimeout(() => {
          entry.target.classList.add('visible');
        }, i * 80);
        revealObserver.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.12 }
);
document.querySelectorAll('.reveal').forEach(el => revealObserver.observe(el));

// ══════════════════════════════════════════════════════════════════════════════
// SKILLS BARS — animate on scroll into view
// ══════════════════════════════════════════════════════════════════════════════
const barObserver = new IntersectionObserver(
  entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const bar = entry.target;
        const width = bar.dataset.width || 0;
        setTimeout(() => { bar.style.width = `${width}%`; }, 200);
        barObserver.unobserve(bar);
      }
    });
  },
  { threshold: 0.3 }
);
document.querySelectorAll('.skill-bar').forEach(bar => barObserver.observe(bar));

// ══════════════════════════════════════════════════════════════════════════════
// COUNTER ANIMATION
// ══════════════════════════════════════════════════════════════════════════════
function animateCounter(el, target, duration = 1200) {
  const start = performance.now();
  function update(now) {
    const elapsed = now - start;
    const progress = Math.min(elapsed / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    el.textContent = Math.round(eased * target);
    if (progress < 1) requestAnimationFrame(update);
  }
  requestAnimationFrame(update);
}

const counterObserver = new IntersectionObserver(
  entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const target = parseInt(entry.target.dataset.count, 10);
        if (!isNaN(target)) animateCounter(entry.target, target);
        counterObserver.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.5 }
);
document.querySelectorAll('[data-count]').forEach(el => counterObserver.observe(el));

// ══════════════════════════════════════════════════════════════════════════════
// HEADER: active nav + scroll styling
// ══════════════════════════════════════════════════════════════════════════════
const sections = document.querySelectorAll('section[id], div[id="stats-bar"]');
const navLinks  = document.querySelectorAll('.nav-link');
const header    = document.getElementById('site-header');

const navObserver = new IntersectionObserver(
  entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        navLinks.forEach(link => {
          link.classList.toggle('active', link.getAttribute('href') === `#${entry.target.id}`);
        });
      }
    });
  },
  { rootMargin: `-${60}px 0px -50% 0px` }
);
sections.forEach(s => navObserver.observe(s));

window.addEventListener('scroll', () => {
  header.classList.toggle('scrolled', window.scrollY > 20);
}, { passive: true });

// ══════════════════════════════════════════════════════════════════════════════
// HIGHLIGHT.JS — init after page load
// ══════════════════════════════════════════════════════════════════════════════
document.addEventListener('DOMContentLoaded', () => {
  if (typeof hljs !== 'undefined') {
    // Only highlight static blocks (sec-code-wrap), not the viewer (handled separately)
    document.querySelectorAll('.sec-code-wrap code').forEach(block => {
      hljs.highlightElement(block);
    });
  }
});

// ══════════════════════════════════════════════════════════════════════════════
// STATS BAR — duplicate for seamless marquee
// ══════════════════════════════════════════════════════════════════════════════
const statsInner = document.querySelector('.stats-inner');
if (statsInner) {
  const clone = statsInner.cloneNode(true);
  statsInner.parentNode.appendChild(clone);
}

// ══════════════════════════════════════════════════════════════════════════════
// ARCHITECTURE SVG tooltips (simple title-based)
// ══════════════════════════════════════════════════════════════════════════════
document.querySelectorAll('.arch-node[data-tip]').forEach(node => {
  const tip = node.dataset.tip;
  const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
  title.textContent = tip;
  node.prepend(title);
});
