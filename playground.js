/* Smart Port Billing Infrastructure — Interactive Simulation Engine
   Simulates full RHEL 9 deployment of all 7 scripts in the browser.
   No backend. Realistic output, live state panel, configurable inputs.
   ─────────────────────────────────────────────────────────────────── */
'use strict';

// ════════════════════════════════════════════════════════════════════════
// CONFIGURATION — bound to form inputs
// ════════════════════════════════════════════════════════════════════════
let CFG = {
  device:      '/dev/sdb',
  adminCIDR:   '192.168.10.0/24',
  billingCIDR: '10.10.0.0/16',
  sshPort:     2222,
  appPort:     3000,
  speed:       1,
};

// ════════════════════════════════════════════════════════════════════════
// LIVE SYSTEM STATE — mutated as scripts run
// ════════════════════════════════════════════════════════════════════════
let SYS = {};

function resetSYS() {
  SYS = {
    groups:     [],
    users:      [],
    sudoRules:  [],
    lvmPV:      null,
    lvmVG:      null,
    lvmLVs:     [],
    mounts:     [],
    fwZone:     null,
    fwRules:    [],
    selinux:    'permissive',
    sctxs:      [],
    sshPort:    22,
    sshConfig:  {},
    services:   [],
    timers:     [],
    acls:       [],
    logConfigs: [],
    backupScript: false,
    scriptsDone: [],
  };
}
resetSYS();

// ════════════════════════════════════════════════════════════════════════
// TERMINAL RENDERER
// ════════════════════════════════════════════════════════════════════════
const term = document.getElementById('pg-terminal');

// Line types → CSS classes  (t values used in step data)
const LINE_CLASS = {
  comment: 'tl-comment',
  cmd:     'tl-cmd',
  info:    'tl-info',
  ok:      'tl-ok',
  warn:    'tl-warn',
  err:     'tl-err',
  blank:   'tl-blank',
  section: 'tl-section',
  plain:   'tl-plain',
  sub:     'tl-sub',
  output:  'tl-output',
};

function termClear() {
  term.innerHTML = '';
  cursorEl = null;
}

let cursorEl = null;
function ensureCursor() {
  if (cursorEl) cursorEl.remove();
  cursorEl = document.createElement('span');
  cursorEl.className = 'tl-cursor';
  term.appendChild(cursorEl);
}

function printPrompt(cmd) {
  const d = document.createElement('div');
  d.className = 'tl-prompt';
  d.innerHTML =
    `<span class="tp-host">portadmin@rhel9</span>` +
    `<span class="tp-sep">:</span>` +
    `<span class="tp-path">~</span>` +
    `<span class="tp-dollar"> $ </span>` +
    `<span class="tp-cmd">${escHtml(cmd)}</span>`;
  term.appendChild(d);
  term.scrollTop = term.scrollHeight;
}

function printLine(type, text) {
  if (type === 'blank') {
    const d = document.createElement('div');
    d.className = 'tl-blank';
    d.innerHTML = '&nbsp;';
    term.appendChild(d);
    return;
  }
  const d = document.createElement('div');
  d.className = LINE_CLASS[type] || 'tl-plain';
  d.textContent = text;
  term.appendChild(d);
  term.scrollTop = term.scrollHeight;
}

function escHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function printHeader(scriptNum, title) {
  printLine('blank','');
  printLine('section', `╔${'═'.repeat(56)}╗`);
  printLine('section', `║  [${scriptNum}] ${title.padEnd(52)}║`);
  printLine('section', `╚${'═'.repeat(56)}╝`);
  printLine('blank','');
}

function printSummary(lines) {
  printLine('blank','');
  printLine('section', '─'.repeat(50));
  lines.forEach(l => printLine('sub', '  ' + l));
  printLine('section', '─'.repeat(50));
  printLine('blank','');
}

// ════════════════════════════════════════════════════════════════════════
// STATE PANEL RENDERER
// ════════════════════════════════════════════════════════════════════════
const stateBody = document.getElementById('pg-state-body');

function renderState() {
  if (!stateBody) return;
  stateBody.innerHTML = '';

  // ── SELinux ───────────────────────────────────────────────────────────
  addStateSection('SELinux', [
    { label: 'Mode', value: SYS.selinux, cls: SYS.selinux === 'enforcing' ? 'sv-green' : 'sv-amber' },
    ...SYS.sctxs.slice(-3).map(c => ({ label: 'fcontext', value: c, cls: 'sv-purple' })),
  ]);

  // ── Firewall ──────────────────────────────────────────────────────────
  const fwItems = SYS.fwZone
    ? [{ label: 'Zone', value: SYS.fwZone, cls: 'sv-orange' }, ...SYS.fwRules.slice(-3).map(r => ({ label: 'rule', value: r, cls: 'sv-dim' }))]
    : [{ label: 'Status', value: 'not configured', cls: 'sv-dim' }];
  addStateSection('firewalld', fwItems);

  // ── SSH ───────────────────────────────────────────────────────────────
  addStateSection('SSH', [
    { label: 'Port', value: String(SYS.sshPort), cls: SYS.sshPort !== 22 ? 'sv-cyan' : 'sv-dim' },
    { label: 'Auth', value: SYS.sshConfig.auth || 'password', cls: SYS.sshConfig.auth === 'key-only' ? 'sv-green' : 'sv-amber' },
    { label: 'Groups', value: SYS.sshConfig.groups || 'all', cls: 'sv-dim' },
  ]);

  // ── Services ──────────────────────────────────────────────────────────
  addStateSection('Services', SYS.services.length
    ? SYS.services.map(s => ({ label: s.name, value: s.state, cls: s.state === 'active' ? 'sv-green' : 'sv-amber' }))
    : [{ label: 'Status', value: 'none running', cls: 'sv-dim' }]
  );

  // ── LVM Storage ───────────────────────────────────────────────────────
  const lvmItems = SYS.lvmLVs.length
    ? SYS.lvmLVs.map(lv => ({ label: lv.name, value: `${lv.size} XFS`, cls: 'sv-cyan' }))
    : [{ label: 'Status', value: 'not provisioned', cls: 'sv-dim' }];
  if (SYS.lvmVG) lvmItems.unshift({ label: 'VG', value: SYS.lvmVG, cls: 'sv-orange' });
  addStateSection('Storage', lvmItems);

  // ── Users ─────────────────────────────────────────────────────────────
  addStateSection('Users', SYS.users.length
    ? SYS.users.map(u => ({ label: u.name, value: u.group, cls: 'sv-cyan' }))
    : [{ label: 'Status', value: 'none created', cls: 'sv-dim' }]
  );

  // ── Groups ────────────────────────────────────────────────────────────
  addStateSection('Groups', SYS.groups.length
    ? SYS.groups.map(g => ({ label: g, value: '●', cls: 'sv-green' }))
    : [{ label: 'Status', value: 'none created', cls: 'sv-dim' }]
  );

  // ── Timers ────────────────────────────────────────────────────────────
  if (SYS.timers.length) {
    addStateSection('Timers', SYS.timers.map(t => ({ label: t.name, value: t.schedule, cls: 'sv-amber' })));
  }

  // ── ACLs ──────────────────────────────────────────────────────────────
  if (SYS.acls.length) {
    addStateSection('ACLs', SYS.acls.map(a => ({ label: a.path.split('/').pop(), value: a.perms, cls: 'sv-purple' })));
  }

  updateProgress();
}

function updateProgress() {
  const done    = SYS.scriptsDone.length;
  const total   = 7;
  const pct     = Math.round((done / total) * 100);
  const bar     = document.getElementById('pg-progress-bar');
  const track   = document.getElementById('pg-progress-track');
  const label   = document.getElementById('pg-progress-label');
  const counter = document.getElementById('pg-progress-pct');
  if (bar)     bar.style.width = `${pct}%`;
  if (track)   track.setAttribute('aria-valuenow', done);
  if (counter) counter.textContent = `${done} / ${total}`;
  if (label) {
    if (done === 0)     label.textContent = 'Ready — configure inputs and click Run';
    else if (done < total) label.textContent = `Deploying… script ${done} of ${total} complete`;
    else                label.textContent  = 'Deployment complete — all 7 scripts executed';
  }
  document.querySelectorAll('.pg-step').forEach(el => {
    const id = el.dataset.step;
    el.classList.remove('pg-step-done', 'pg-step-active');
    if (SYS.scriptsDone.includes(id)) {
      el.classList.add('pg-step-done');
    } else if (running && id === String(done + 1).padStart(2, '0')) {
      el.classList.add('pg-step-active');
    }
  });
}

function addStateSection(title, items) {
  const sec = document.createElement('div');
  sec.className = 'sv-section';
  sec.innerHTML = `<div class="sv-title">${escHtml(title)}</div>`;
  items.forEach(item => {
    const row = document.createElement('div');
    row.className = 'sv-row';
    row.innerHTML =
      `<span class="sv-label">${escHtml(item.label)}</span>` +
      `<span class="sv-value ${item.cls || ''}">${escHtml(item.value)}</span>`;
    sec.appendChild(row);
  });
  stateBody.appendChild(sec);
}

// ════════════════════════════════════════════════════════════════════════
// SIMULATION RUNNER
// ════════════════════════════════════════════════════════════════════════
let running    = false;
let paused     = false;
let cancelFlag = false;

async function delay(ms) {
  const adjusted = Math.max(10, ms / CFG.speed);
  const chunkMs  = 50;
  let elapsed    = 0;
  while (elapsed < adjusted && !cancelFlag) {
    await new Promise(r => setTimeout(r, Math.min(chunkMs, adjusted - elapsed)));
    elapsed += chunkMs;
    while (paused && !cancelFlag) {
      await new Promise(r => setTimeout(r, 100));
    }
  }
}

// Run a single simulation (array of steps)
async function runSim(steps) {
  for (const step of steps) {
    if (cancelFlag) break;

    if (step.cmd !== undefined) {
      printPrompt(step.cmd);
      await delay(80);
    }

    if (step.lines) {
      for (const line of step.lines) {
        if (cancelFlag) break;
        printLine(line.t, line.s);
        await delay(step.lineDelay ?? 60);
      }
    }

    if (step.state) {
      step.state(SYS, CFG);
      renderState();
    }

    await delay(step.delay ?? 200);
  }
}

// ════════════════════════════════════════════════════════════════════════
// SCRIPT SIMULATIONS  (7 scripts)
// ════════════════════════════════════════════════════════════════════════

// Helper: generate ISO-ish timestamp for output lines
function TS(base = 0) {
  const h = String(8 + Math.floor(base / 3600)).padStart(2,'0');
  const m = String(Math.floor((base % 3600) / 60)).padStart(2,'0');
  const s = String(base % 60).padStart(2,'0');
  return `[${h}:${m}:${s}]`;
}

function makeOK(t, msg)   { return { t:'ok',   s:`${TS(t)}  OK   ${msg}` }; }
function makeINFO(t, msg) { return { t:'info', s:`${TS(t)} INFO  ${msg}` }; }
function makeWARN(t, msg) { return { t:'warn', s:`${TS(t)} WARN  ${msg}` }; }

// ── SCRIPT 01: User & Group Setup ────────────────────────────────────────────
function buildSim01() {
  return [
    { delay: 0, lines: [], cmd: 'sudo bash scripts/01_user_group_setup.sh' },
    { delay: 300, lines: [makeINFO(0, 'Starting Port Billing user provisioning...')] },
    {
      cmd: 'groupadd --system billing-admin',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(1, 'Created group: billing-admin (Port Billing Administrators)'),
        makeOK(2, 'Created group: billing-ops (Billing Operations Team)'),
        makeOK(3, 'Created group: port-ops (Port Operations Team)'),
        makeOK(4, 'Created group: billing-readonly (Billing Read-Only Auditors)'),
      ],
      state: (s) => { s.groups = ['billing-admin','billing-ops','port-ops','billing-readonly']; },
    },
    {
      cmd: 'useradd --gid billing-admin --create-home portadmin',
      delay: 500, lineDelay: 120,
      lines: [
        makeOK(5, 'Created user: portadmin → group: billing-admin'),
        makeOK(6, 'Created user: billmgr → group: billing-ops'),
        makeOK(7, 'Created user: portclerk → group: billing-ops'),
        makeOK(8, 'Created user: opswatch → group: port-ops'),
        makeOK(9, 'Created user: auditor → group: billing-readonly'),
      ],
      state: (s) => {
        s.users = [
          { name:'portadmin',  group:'billing-admin' },
          { name:'billmgr',    group:'billing-ops' },
          { name:'portclerk',  group:'billing-ops' },
          { name:'opswatch',   group:'port-ops' },
          { name:'auditor',    group:'billing-readonly' },
        ];
      },
    },
    {
      cmd: 'chage --maxdays 90 --mindays 7 --warndays 14 portadmin',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(12, 'Password policy applied: portadmin  (max:90d warn:14d inactive:30d)'),
        makeOK(13, 'Password policy applied: billmgr    (max:90d warn:14d inactive:30d)'),
        makeOK(14, 'Password policy applied: portclerk  (max:90d warn:14d inactive:30d)'),
        makeOK(15, 'Password policy applied: opswatch   (max:90d warn:14d inactive:30d)'),
        makeOK(16, 'Password policy applied: auditor    (max:90d warn:14d inactive:30d)'),
      ],
    },
    {
      cmd: 'visudo -c -f /etc/sudoers.d/portbill-billing-admin',
      delay: 300, lineDelay: 60,
      lines: [
        makeOK(18, 'Sudo rules written: /etc/sudoers.d/portbill-billing-admin'),
        makeOK(19, 'Sudo config syntax valid — visudo check passed'),
      ],
      state: (s) => { s.sudoRules.push('/etc/sudoers.d/portbill-billing-admin'); },
    },
    {
      delay: 200, lineDelay: 80,
      lines: [
        makeOK(21, 'Secured home: /home/portadmin (0750)'),
        makeOK(22, 'Secured home: /home/billmgr   (0750)'),
        makeOK(23, 'Secured home: /home/portclerk (0750)'),
        makeOK(24, 'Secured home: /home/opswatch  (0750)'),
        makeOK(25, 'Secured home: /home/auditor   (0750)'),
        { t:'blank', s:'' },
        { t:'section', s:'╔══════════════════════════════════════════╗' },
        { t:'section', s:'║   User Provisioning Complete              ║' },
        { t:'section', s:'╚══════════════════════════════════════════╝' },
        { t:'sub', s:'  Groups created  : 4' },
        { t:'sub', s:'  Users created   : 5' },
        { t:'sub', s:'  Sudo config     : /etc/sudoers.d/portbill-billing-admin' },
        { t:'sub', s:'  Default password: ChangeMe@2024! (forced change on login)' },
        { t:'blank', s:'' },
      ],
      state: (s) => { s.scriptsDone.push('01'); },
    },
  ];
}

// ── SCRIPT 02: LVM Storage ───────────────────────────────────────────────────
function buildSim02() {
  return [
    { delay: 0, cmd: `sudo bash scripts/02_storage_lvm.sh ${CFG.device}` },
    {
      delay: 300, lineDelay: 60,
      lines: [
        makeINFO(0, `Target device: ${CFG.device}`),
        { t:'output', s:`NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS` },
        { t:'output', s:`${CFG.device.replace('/dev/','')}    8:16   0   30G  0 disk ` },
      ],
    },
    {
      cmd: `pvcreate --force ${CFG.device}`,
      delay: 600, lineDelay: 80,
      lines: [
        { t:'output', s:`  Physical volume "${CFG.device}" successfully created.` },
        makeOK(2, `Physical Volume created: ${CFG.device}`),
      ],
      state: (s, c) => { s.lvmPV = c.device; },
    },
    {
      cmd: 'vgcreate portbill-vg /dev/sdb',
      delay: 400, lineDelay: 80,
      lines: [
        { t:'output', s:'  Volume group "portbill-vg" successfully created.' },
        makeOK(4, 'Volume Group created: portbill-vg'),
      ],
      state: (s) => { s.lvmVG = 'portbill-vg'; },
    },
    {
      cmd: 'lvcreate --name billing-data --size 10G portbill-vg',
      delay: 500, lineDelay: 120,
      lines: [
        { t:'output', s:'  Logical volume "billing-data" created.' },
        makeOK(6, 'Logical Volume created: billing-data (10G)'),
        makeOK(7, 'XFS filesystem created: /dev/portbill-vg/billing-data'),
        { t:'output', s:'  Logical volume "billing-logs" created.' },
        makeOK(8, 'Logical Volume created: billing-logs (5G)'),
        makeOK(9, 'XFS filesystem created: /dev/portbill-vg/billing-logs'),
        { t:'output', s:'  Logical volume "billing-backup" created.' },
        makeOK(10, 'Logical Volume created: billing-backup (15G)'),
        makeOK(11, 'XFS filesystem created: /dev/portbill-vg/billing-backup'),
      ],
      state: (s) => {
        s.lvmLVs = [
          { name:'billing-data',   size:'10G', mount:'/srv/portbill/data' },
          { name:'billing-logs',   size:'5G',  mount:'/srv/portbill/logs' },
          { name:'billing-backup', size:'15G', mount:'/srv/portbill/backup' },
        ];
      },
    },
    {
      cmd: 'mount /srv/portbill/data',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(14, 'fstab entry added: /srv/portbill/data (UUID-based, noatime)'),
        makeOK(15, 'fstab entry added: /srv/portbill/logs'),
        makeOK(16, 'fstab entry added: /srv/portbill/backup'),
        makeOK(17, 'Mounted: /srv/portbill/data'),
        makeOK(18, 'Mounted: /srv/portbill/logs'),
        makeOK(19, 'Mounted: /srv/portbill/backup'),
        makeOK(21, 'SELinux contexts applied to /srv/portbill/'),
      ],
      state: (s) => {
        s.mounts = ['/srv/portbill/data','/srv/portbill/logs','/srv/portbill/backup'];
        s.sctxs.push('httpd_sys_content_t → /data', 'httpd_log_t → /logs');
      },
    },
    {
      delay: 200, lineDelay: 60,
      lines: [
        { t:'blank', s:'' },
        { t:'section', s:'── LVM Storage Layout ──────────────────────' },
        { t:'output', s:'  PV             VG           PSize  PFree' },
        { t:'output', s:`  ${CFG.device}  portbill-vg  30.00g  0.00g` },
        { t:'blank', s:'' },
        { t:'output', s:'  Filesystem                        Size  Used  Avail' },
        { t:'output', s:'  /dev/portbill-vg/billing-data     10G   175M  9.9G' },
        { t:'output', s:'  /dev/portbill-vg/billing-logs      5G    90M  4.9G' },
        { t:'output', s:'  /dev/portbill-vg/billing-backup   15G   125M  14.9G' },
        { t:'blank', s:'' },
        makeOK(30, 'Storage provisioning complete.'),
      ],
      state: (s) => { s.scriptsDone.push('02'); },
    },
  ];
}

// ── SCRIPT 03: Firewall + SELinux ────────────────────────────────────────────
function buildSim03() {
  return [
    { delay: 0, cmd: 'sudo bash scripts/03_firewall_selinux.sh' },
    {
      delay: 300, lineDelay: 60,
      lines: [
        makeINFO(0, 'SELinux: enabling enforcing mode...'),
        { t:'output', s:'setenforce: SELinux is already enabled' },
        makeOK(1, 'SELinux set to enforcing (persistent in /etc/selinux/config)'),
        makeOK(2, 'firewalld is running'),
      ],
      state: (s) => { s.selinux = 'enforcing'; },
    },
    {
      cmd: 'firewall-cmd --permanent --new-zone=portbilling',
      delay: 400, lineDelay: 80,
      lines: [
        { t:'output', s:'success' },
        makeOK(4, 'Zone created: portbilling'),
        makeOK(5, 'Public zone: target=DROP, SSH removed'),
      ],
      state: (s) => { s.fwZone = 'portbilling'; },
    },
    {
      cmd: `firewall-cmd --permanent --zone=portbilling --add-rich-rule="rule family='ipv4' source address='${CFG.adminCIDR}' port port='${CFG.sshPort}' protocol='tcp' accept"`,
      delay: 500, lineDelay: 100,
      lines: [
        { t:'output', s:'success' },
        makeOK(7, `Rich rule: SSH port ${CFG.sshPort} allowed from ${CFG.adminCIDR}`),
        { t:'output', s:'success' },
        makeOK(9, `Rich rule: HTTPS allowed from billing LAN ${CFG.billingCIDR}`),
        { t:'output', s:'success' },
        makeOK(11, 'Rich rule: HTTP rate-limited to 100 connections/min'),
        makeOK(12, 'Zone target set to REJECT (graceful refusal)'),
      ],
      state: (s, c) => {
        s.fwRules = [
          `SSH :${c.sshPort} ← ${c.adminCIDR}`,
          `HTTPS ← ${c.billingCIDR}`,
          'HTTP rate=100/min',
        ];
      },
    },
    {
      cmd: 'firewall-cmd --reload',
      delay: 400, lineDelay: 60,
      lines: [
        { t:'output', s:'success' },
        makeOK(14, 'firewalld reloaded — all rules applied'),
      ],
    },
    {
      cmd: `semanage port --add --type ssh_port_t --proto tcp ${CFG.sshPort}`,
      delay: 500, lineDelay: 80,
      lines: [
        makeOK(16, `SELinux port context: ${CFG.sshPort}/tcp → ssh_port_t`),
        makeOK(17, 'SELinux fcontext: /srv/portbill/data → httpd_sys_content_t'),
        makeOK(18, 'SELinux fcontext: /srv/portbill/logs → httpd_log_t'),
        makeOK(19, 'SELinux fcontext: /etc/nginx/conf.d → httpd_config_t'),
        makeOK(21, 'restorecon applied to /srv/portbill/ and /etc/nginx/'),
      ],
      state: (s, c) => {
        s.sctxs = [
          `ssh_port_t :${c.sshPort}/tcp`,
          'httpd_sys_content_t /data',
          'httpd_log_t /logs',
          'httpd_config_t /nginx',
        ];
      },
    },
    {
      cmd: 'setsebool -P httpd_can_network_connect on',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(24, 'SELinux boolean: httpd_can_network_connect=on (persistent)'),
        makeOK(25, 'SELinux boolean: httpd_read_user_content=off (persistent)'),
        makeOK(26, 'SELinux boolean: httpd_enable_homedirs=off (persistent)'),
        { t:'blank', s:'' },
        { t:'section', s:'── Firewall Status ─────────────────────────' },
        { t:'output', s:'  portbilling (active)' },
        { t:'output', s:`  target: REJECT` },
        { t:'output', s:`  services: http https` },
        { t:'output', s:`  rich rules: 3 applied` },
        { t:'blank', s:'' },
        { t:'section', s:'── SELinux Status ──────────────────────────' },
        { t:'output', s:'  SELinux status:     enabled' },
        { t:'output', s:'  SELinuxfs mount:    /sys/fs/selinux' },
        { t:'output', s:'  SELinux mode:       enforcing' },
        { t:'output', s:'  Policy type:        targeted' },
        { t:'blank', s:'' },
        makeOK(35, 'Firewall & SELinux hardening complete.'),
      ],
      state: (s) => { s.scriptsDone.push('03'); },
    },
  ];
}

// ── SCRIPT 04: SSH Hardening ─────────────────────────────────────────────────
function buildSim04() {
  return [
    { delay: 0, cmd: 'sudo bash scripts/04_ssh_hardening.sh' },
    {
      delay: 300, lineDelay: 60,
      lines: [
        makeOK(0, 'Backup created: /etc/ssh/sshd_config.pre-hardening.20240115084200'),
        makeOK(1, 'Legal banner created: /etc/ssh/billing-banner'),
        makeINFO(2, 'Writing hardened SSH configuration...'),
      ],
    },
    {
      cmd: 'sed -i -E "s|^#?Port.*|Port 2222|" /etc/ssh/sshd_config',
      delay: 600, lineDelay: 40,
      lines: [
        { t:'info', s:'    Port → 2222' },
        { t:'info', s:'    AddressFamily → inet' },
        { t:'info', s:'    PermitRootLogin → no' },
        { t:'info', s:'    PubkeyAuthentication → yes' },
        { t:'info', s:'    PasswordAuthentication → no' },
        { t:'info', s:'    PermitEmptyPasswords → no' },
        { t:'info', s:'    AllowGroups → billing-admin' },
        { t:'info', s:'    LoginGraceTime → 30' },
        { t:'info', s:'    MaxAuthTries → 3' },
        { t:'info', s:'    MaxSessions → 5' },
        { t:'info', s:'    ClientAliveInterval → 300' },
        { t:'info', s:'    X11Forwarding → no' },
        { t:'info', s:'    AllowTcpForwarding → no' },
        { t:'info', s:'    LogLevel → VERBOSE' },
        { t:'info', s:'    KexAlgorithms → curve25519-sha256,...' },
        { t:'info', s:'    Ciphers → chacha20-poly1305@openssh.com,...' },
        makeOK(18, 'Hardened configuration written.'),
      ],
    },
    {
      cmd: 'sshd -t -f /etc/ssh/sshd_config',
      delay: 400, lineDelay: 80,
      lines: [
        makeINFO(20, 'Validating sshd_config syntax...'),
        makeOK(21, 'Configuration syntax valid.'),
        makeOK(22, 'authorized_keys created: /home/portadmin/.ssh/authorized_keys'),
        makeWARN(23, 'authorized_keys is EMPTY — add your public key before connecting!'),
      ],
    },
    {
      cmd: 'systemctl restart sshd && systemctl enable sshd',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(25, 'sshd restarted and enabled.'),
        makeOK(26, `SELinux: port ${CFG.sshPort} correctly labelled ssh_port_t`),
        { t:'blank', s:'' },
        { t:'section', s:'── SSH Hardening Summary ───────────────────' },
        { t:'sub', s:`  Listening port     : ${CFG.sshPort}/tcp` },
        { t:'sub', s:'  Root login         : DISABLED' },
        { t:'sub', s:'  Password auth      : DISABLED (keys only)' },
        { t:'sub', s:'  Allowed groups     : billing-admin' },
        { t:'sub', s:'  Max auth tries     : 3' },
        { t:'sub', s:'  Session timeout    : 300s idle (2 misses)' },
        { t:'blank', s:'' },
        { t:'output', s:`  LISTEN 0 128 0.0.0.0:${CFG.sshPort} 0.0.0.0:* users:(("sshd",...))` },
        { t:'blank', s:'' },
        makeOK(35, 'SSH hardening complete.'),
      ],
      state: (s, c) => {
        s.sshPort   = c.sshPort;
        s.sshConfig = { auth:'key-only', groups:'billing-admin', port:c.sshPort };
        s.services.push({ name:'sshd', state:'active' });
        s.scriptsDone.push('04');
      },
    },
  ];
}

// ── SCRIPT 05: Service Deploy ─────────────────────────────────────────────────
function buildSim05() {
  return [
    { delay: 0, cmd: 'sudo bash scripts/05_service_deploy.sh' },
    {
      cmd: `podman pull ghcr.io/samiulAsumel/portbill:latest`,
      delay: 800, lineDelay: 80,
      lines: [
        makeINFO(0, 'Pulling container image: ghcr.io/samiulAsumel/portbill:latest'),
        { t:'output', s:'Trying to pull ghcr.io/samiulAsumel/portbill:latest...' },
        { t:'output', s:'Getting image source signatures' },
        { t:'output', s:'Copying blob sha256:a3d4... done' },
        { t:'output', s:'Copying blob sha256:f7c2... done' },
        { t:'output', s:'Copying blob sha256:9b1e... done' },
        { t:'output', s:'Writing manifest to image destination' },
        makeOK(6, 'Container image ready: ghcr.io/samiulAsumel/portbill:latest'),
      ],
    },
    {
      cmd: 'cat > /etc/systemd/system/portbill.service',
      delay: 400, lineDelay: 60,
      lines: [
        makeOK(8, 'Systemd unit written: /etc/systemd/system/portbill.service'),
      ],
    },
    {
      cmd: 'openssl req -x509 -nodes -days 365 -newkey rsa:4096 -out /etc/nginx/ssl/portbill/server.crt',
      delay: 900, lineDelay: 60,
      lines: [
        makeINFO(10, 'Generating RSA 4096 key (this takes a moment)...'),
        { t:'output', s:'Generating a RSA private key' },
        { t:'output', s:'....................................++' },
        { t:'output', s:'writing new private key to /etc/nginx/ssl/portbill/server.key' },
        makeOK(13, 'Self-signed TLS certificate generated: /etc/nginx/ssl/portbill/'),
        makeWARN(14, 'PRODUCTION: Replace with a CA-signed cert (Let\'s Encrypt recommended)'),
        makeOK(15, 'Nginx configuration written: /etc/nginx/conf.d/portbill.conf'),
      ],
    },
    {
      cmd: 'nginx -t',
      delay: 400, lineDelay: 60,
      lines: [
        { t:'output', s:'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok' },
        { t:'output', s:'nginx: configuration file /etc/nginx/nginx.conf test is successful' },
        makeOK(18, 'Nginx configuration syntax valid.'),
      ],
    },
    {
      cmd: 'systemctl daemon-reload && systemctl enable --now nginx portbill',
      delay: 600, lineDelay: 80,
      lines: [
        makeOK(20, 'Nginx enabled and started.'),
        makeOK(21, 'portbill service enabled and started.'),
        makeINFO(22, 'Waiting for application health check (max 60s)...'),
        { t:'output', s:'  Attempt 1... waiting' },
        { t:'output', s:'  Attempt 2... waiting' },
        { t:'output', s:'  Attempt 3... OK' },
        makeOK(25, 'Health check passed on attempt 3'),
        { t:'blank', s:'' },
        { t:'section', s:'── Deployment Summary ──────────────────────' },
        { t:'output', s:'  portbill.service  Active: active (running)' },
        { t:'output', s:'  nginx.service     Active: active (running)' },
        { t:'blank', s:'' },
        { t:'sub', s:`  App container    : portbill → 127.0.0.1:${CFG.appPort}` },
        { t:'sub', s:`  Nginx proxy      : :80 → :443 (TLS 1.3)` },
        { t:'sub', s:'  Data volume      : /srv/portbill/data' },
        { t:'sub', s:'  Systemd unit     : /etc/systemd/system/portbill.service' },
        { t:'blank', s:'' },
        makeOK(35, 'Deployment complete.'),
      ],
      state: (s) => {
        s.services.push({ name:'portbill', state:'active' }, { name:'nginx', state:'active' });
        s.scriptsDone.push('05');
      },
    },
  ];
}

// ── SCRIPT 06: ACL + Backup ──────────────────────────────────────────────────
function buildSim06() {
  return [
    { delay: 0, cmd: 'sudo bash scripts/06_acl_backup.sh' },
    {
      cmd: 'setfacl --recursive --modify "g:billing-admin:rwx,g:billing-ops:rwx" /srv/portbill/data',
      delay: 500, lineDelay: 80,
      lines: [
        makeINFO(0, 'Configuring POSIX ACLs for billing data directories...'),
        makeOK(1, 'ACLs set on: /srv/portbill/data'),
        makeOK(2, 'ACLs set on: /srv/portbill/logs'),
        makeOK(3, 'ACLs set on: /srv/portbill/backup'),
        { t:'blank', s:'' },
        { t:'section', s:'ACL Report — /srv/portbill/data' },
        { t:'output', s:'  # file: srv/portbill/data' },
        { t:'output', s:'  # owner: root' },
        { t:'output', s:'  # group: billing-ops' },
        { t:'output', s:'  user::rwx' },
        { t:'output', s:'  group::rwx' },
        { t:'output', s:'  group:billing-admin:rwx' },
        { t:'output', s:'  group:billing-ops:rwx' },
        { t:'output', s:'  group:port-ops:r-x' },
        { t:'output', s:'  group:billing-readonly:r-x' },
        { t:'output', s:'  other::---' },
        { t:'output', s:'  default:group:billing-admin:rwx' },
        { t:'output', s:'  default:group:billing-ops:rw-' },
        { t:'output', s:'  default:other::---' },
      ],
      state: (s) => {
        s.acls = [
          { path:'/srv/portbill/data',   perms:'admin:rwx ops:rwx ops-ro:r-x' },
          { path:'/srv/portbill/logs',   perms:'admin:rwx ops:r-x ro:r-x' },
          { path:'/srv/portbill/backup', perms:'admin:rwx' },
        ];
      },
    },
    {
      cmd: 'cat > /usr/local/bin/portbill-backup',
      delay: 300, lineDelay: 60,
      lines: [ makeOK(18, 'Backup script created: /usr/local/bin/portbill-backup') ],
    },
    {
      cmd: 'systemctl enable --now portbill-backup.timer',
      delay: 400, lineDelay: 80,
      lines: [
        makeOK(20, 'Systemd timer enabled: portbill-backup.timer (daily at 02:00)'),
        makeINFO(21, 'Running test backup...'),
        { t:'output', s:'  tar: /srv/portbill/data: directory is empty (OK)' },
        makeOK(23, 'Test backup successful.'),
        { t:'blank', s:'' },
        { t:'section', s:'── ACL & Backup Summary ────────────────────' },
        { t:'sub', s:'  Data ACLs        : billing-admin(rwx) billing-ops(rwx) port-ops(r-x)' },
        { t:'sub', s:'  Backup script    : /usr/local/bin/portbill-backup' },
        { t:'sub', s:'  Backup schedule  : Daily 02:00 (± 5min jitter)' },
        { t:'sub', s:'  Retention        : 30 days' },
        { t:'blank', s:'' },
        { t:'output', s:'  portbill-backup.timer active; next trigger: Tue 2024-01-16 02:00' },
        { t:'blank', s:'' },
        makeOK(30, 'ACL & backup configuration complete.'),
      ],
      state: (s) => {
        s.timers.push({ name:'portbill-backup', schedule:'daily 02:00' });
        s.backupScript = true;
        s.scriptsDone.push('06');
      },
    },
  ];
}

// ── SCRIPT 07: Log Monitor ───────────────────────────────────────────────────
function buildSim07() {
  return [
    { delay: 0, cmd: 'sudo bash scripts/07_log_monitor.sh' },
    {
      cmd: 'cat > /etc/rsyslog.d/10-portbill.conf',
      delay: 400, lineDelay: 80,
      lines: [
        makeINFO(0, 'Configuring rsyslog for portbill...'),
        makeOK(2, 'rsyslog configured: /etc/rsyslog.d/10-portbill.conf'),
        { t:'output', s:'  rsyslogd -N1: valid, no issues found.' },
        makeOK(4, 'rsyslog restarted successfully.'),
      ],
    },
    {
      cmd: 'cat > /etc/logrotate.d/portbill',
      delay: 400, lineDelay: 60,
      lines: [
        makeOK(6, 'logrotate configured: /etc/logrotate.d/portbill'),
        { t:'output', s:'  considering log /srv/portbill/logs/*.log' },
        { t:'output', s:'  log does not need rotating (log is empty)' },
      ],
    },
    {
      cmd: 'cat > /usr/local/bin/portbill-logmonitor',
      delay: 300, lineDelay: 60,
      lines: [ makeOK(9, 'Log monitor script: /usr/local/bin/portbill-logmonitor') ],
    },
    {
      cmd: 'systemctl enable --now portbill-logmonitor portbill-summary.timer',
      delay: 500, lineDelay: 80,
      lines: [
        makeOK(11, 'Log monitor service and daily summary timer enabled.'),
        makeOK(12, 'Systemd journal set to persistent storage'),
        { t:'blank', s:'' },
        { t:'section', s:'── Log Monitoring Summary ──────────────────' },
        { t:'sub', s:'  rsyslog config   : /etc/rsyslog.d/10-portbill.conf' },
        { t:'sub', s:'  logrotate config : /etc/logrotate.d/portbill' },
        { t:'sub', s:'  Monitor script   : /usr/local/bin/portbill-logmonitor' },
        { t:'sub', s:'  Alert log        : /var/log/portbill-alerts.log' },
        { t:'sub', s:'  Log retention    : 90 days (100MB rotate threshold)' },
        { t:'blank', s:'' },
        { t:'sub', s:'  journalctl -u portbill -f              # Follow app logs' },
        { t:'sub', s:'  journalctl -u portbill -p err          # Errors only' },
        { t:'sub', s:'  portbill-logmonitor summary            # Daily report' },
        { t:'blank', s:'' },
        makeOK(25, 'Log monitoring setup complete.'),
        { t:'blank', s:'' },
        { t:'section', s:'═'.repeat(56) },
        { t:'ok',     s:'  ✓ FULL DEPLOYMENT COMPLETE — All 7 scripts executed' },
        { t:'section', s:'═'.repeat(56) },
        { t:'blank', s:'' },
        { t:'sub', s:'  01 User & Group Setup    ✓' },
        { t:'sub', s:'  02 LVM Storage           ✓' },
        { t:'sub', s:'  03 Firewall + SELinux    ✓' },
        { t:'sub', s:'  04 SSH Hardening         ✓' },
        { t:'sub', s:'  05 Service Deploy        ✓' },
        { t:'sub', s:'  06 ACL + Backup          ✓' },
        { t:'sub', s:'  07 Log Monitor           ✓' },
        { t:'blank', s:'' },
      ],
      state: (s) => {
        s.services.push({ name:'portbill-logmonitor', state:'active' });
        s.timers.push({ name:'portbill-summary', schedule:'daily 07:00' });
        s.logConfigs = ['rsyslog', 'logrotate', 'journal'];
        s.scriptsDone.push('07');
      },
    },
  ];
}

// ════════════════════════════════════════════════════════════════════════
// SCRIPT REGISTRY
// ════════════════════════════════════════════════════════════════════════
const SCRIPTS_META = [
  { id:'01', title:'User & Group Setup',    file:'01_user_group_setup.sh',    build: buildSim01 },
  { id:'02', title:'LVM Storage',           file:'02_storage_lvm.sh',         build: buildSim02 },
  { id:'03', title:'Firewall + SELinux',    file:'03_firewall_selinux.sh',    build: buildSim03 },
  { id:'04', title:'SSH Hardening',         file:'04_ssh_hardening.sh',       build: buildSim04 },
  { id:'05', title:'Service Deploy',        file:'05_service_deploy.sh',      build: buildSim05 },
  { id:'06', title:'ACL + Backup',          file:'06_acl_backup.sh',          build: buildSim06 },
  { id:'07', title:'Log Monitor',           file:'07_log_monitor.sh',         build: buildSim07 },
];

// ════════════════════════════════════════════════════════════════════════
// UI CONSTRUCTION
// ════════════════════════════════════════════════════════════════════════
const scriptsList = document.getElementById('pg-scripts-list');

function buildScriptList() {
  if (!scriptsList) return;
  scriptsList.innerHTML = '';
  SCRIPTS_META.forEach((s, i) => {
    const btn = document.createElement('button');
    btn.className = 'pg-script-btn';
    btn.dataset.id = s.id;
    btn.dataset.idx = i;
    btn.innerHTML =
      `<span class="pgb-num">${s.id}</span>` +
      `<span class="pgb-info">` +
        `<span class="pgb-title">${escHtml(s.title)}</span>` +
        `<span class="pgb-file">${escHtml(s.file)}</span>` +
      `</span>` +
      `<span class="pgb-status" id="pgb-status-${s.id}">–</span>`;
    btn.addEventListener('click', () => runSingleScript(i));
    scriptsList.appendChild(btn);
  });
}

function setScriptStatus(id, status) {
  const el = document.getElementById(`pgb-status-${id}`);
  if (!el) return;
  const states = {
    running: { cls:'pgs-running', text:'▶ Running' },
    done:    { cls:'pgs-done',    text:'✓ Done' },
    pending: { cls:'pgs-pending', text:'–' },
    error:   { cls:'pgs-error',   text:'✗ Error' },
  };
  const st = states[status] || states.pending;
  el.className = `pgb-status ${st.cls}`;
  el.textContent = st.text;
}

function highlightScriptBtn(idx) {
  document.querySelectorAll('.pg-script-btn').forEach((b, i) => {
    b.classList.toggle('pg-script-active', i === idx);
  });
}

// ════════════════════════════════════════════════════════════════════════
// RUN CONTROL
// ════════════════════════════════════════════════════════════════════════
function refreshCFG() {
  CFG.device      = document.getElementById('pg-device')?.value       || '/dev/sdb';
  CFG.adminCIDR   = document.getElementById('pg-admin-cidr')?.value   || '192.168.10.0/24';
  CFG.billingCIDR = document.getElementById('pg-billing-cidr')?.value || '10.10.0.0/16';
  CFG.sshPort     = parseInt(document.getElementById('pg-ssh-port')?.value) || 2222;
  CFG.speed       = parseFloat(document.getElementById('pg-speed')?.value) || 1;
}

async function runSingleScript(idx) {
  if (running) { cancelFlag = true; await new Promise(r => setTimeout(r, 200)); }
  refreshCFG();
  cancelFlag = false;
  running    = true;
  paused     = false;

  const meta = SCRIPTS_META[idx];
  highlightScriptBtn(idx);
  setScriptStatus(meta.id, 'running');
  updateRunBtn(true);
  updatePauseBtn();

  printHeader(meta.id, meta.title.toUpperCase());
  const steps = meta.build();
  await runSim(steps);

  setScriptStatus(meta.id, cancelFlag ? 'pending' : 'done');
  running = false;
  updateRunBtn(false);
  ensureCursor();
  renderState();
}

async function runAllScripts() {
  if (running) { cancelFlag = true; await new Promise(r => setTimeout(r, 200)); }
  refreshCFG();
  termClear();
  resetSYS();
  renderState();
  SCRIPTS_META.forEach(s => setScriptStatus(s.id, 'pending'));
  cancelFlag = false;
  running    = true;
  paused     = false;
  updateRunBtn(true);
  updatePauseBtn();

  for (let i = 0; i < SCRIPTS_META.length; i++) {
    if (cancelFlag) break;
    await runSingleScript(i);
    await delay(400);
  }

  running = false;
  updateRunBtn(false);
}

function updateRunBtn(isRunning) {
  const btn = document.getElementById('pg-run-all');
  if (!btn) return;
  btn.textContent = isRunning ? '⬛ Stop' : '▶ Run Full Deployment';
  btn.classList.toggle('pg-btn-running', isRunning);
}

function updatePauseBtn() {
  const btn = document.getElementById('pg-pause');
  if (!btn) return;
  btn.textContent  = paused ? '▶ Resume' : '⏸ Pause';
  btn.disabled     = !running;
}

// ════════════════════════════════════════════════════════════════════════
// EVENT LISTENERS
// ════════════════════════════════════════════════════════════════════════
document.getElementById('pg-run-all')?.addEventListener('click', () => {
  if (running) {
    cancelFlag = true;
    running    = false;
    updateRunBtn(false);
  } else {
    runAllScripts();
  }
});

document.getElementById('pg-reset')?.addEventListener('click', () => {
  cancelFlag = true;
  running    = false;
  paused     = false;
  termClear();
  resetSYS();
  renderState();
  SCRIPTS_META.forEach(s => setScriptStatus(s.id, 'pending'));
  updateRunBtn(false);
  term.innerHTML = '<div class="pg-terminal-placeholder">Simulation reset. Select a script or click <strong>Run Full Deployment</strong>.</div>';
});

document.getElementById('pg-pause')?.addEventListener('click', () => {
  paused = !paused;
  updatePauseBtn();
});

document.getElementById('pg-clear')?.addEventListener('click', () => {
  termClear();
  term.innerHTML = '<div class="pg-terminal-placeholder">Terminal cleared.</div>';
});

// ════════════════════════════════════════════════════════════════════════
// INIT
// ════════════════════════════════════════════════════════════════════════
buildScriptList();
renderState();
updatePauseBtn(); // initialise disabled state
